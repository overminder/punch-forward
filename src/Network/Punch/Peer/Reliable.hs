-- Pipes-based UDP-to-reliable-protocol adapter

module Network.Punch.Peer.Reliable (
  module Network.Punch.Peer.Reliable.Types
    ( RcbRef
    , ConnOption (..)
    )
  newRcb,
  shutdownRcb,
  sendRcb,
  recvRcb
) where

import Network.Punch.Peer.Reliable.Types

newRcb :: ConnOption -> IO RcbRef
newRcb opt = do
  rcbRef <- newEmptyMVar
  [fromNic, toNic] <- replicateM 2 P.spawn'
  [fromApp, toApp] <- replicateM 2 P.spawn'
  tResend <- async $ runResend rcbRef
  tRecv <- async $ runRecv rcbRef
  tSend <- async $ runSend rcbRef
  
  putMVar rcbRef $ Rcb
    { rcbConnOpt = opt
    , rcbState = RcbOpen
    , rcbFromNic = fromNic
    , rcbToNic = toNic
    , rcbFromApp = fromApp
    , rcbToApp = toApp
    , rcbSeqGen = 0
    , rcbOutputQ = M.empty
    , rcbDeliveryQ = M.empty
    , rcbLastDeliverySeq = 0
    , rcbResendQ = M.empty
    , rcbFinSeq = (-1)
    , rcbResendThread = tResend
    , rcbRecvThread = tRecv
    , rcbSendThread = tSend
    }
  return rcbRef

runResend rcbRef = go
 where
  go = do
    threadDelay (100 * 1000)
    eiResult <- modifyMVar rcbRef resendOnce
    case eiResult of
      Right () -> go
      Left err -> closeState rcbRef err

  checkCloseWait rcb@(Rcb {..}) = do
    if rcbState == RcbCloseWait &&
       rcbLastDeliverySeq + 1 == rcbFinSeq &&
       -- ^ We have received all DATA packets from the other side
       M.null rcbOutputQ
       -- ^ And the other side has ACKed all of our DATA packets
      then do
        sendMailbox rcbToNic mkRstPkt
        internalResetEverything rcb
        -- ^ This kill itself as well
      else
        return rcb

  resendOnce s@(Rcb {..}) = do
    now <- getCurrentTime
    let (works, rest) = M.split (now, (-1)) rcbResendQ
    eiRes <- runEitherT $
      forM (M.toList works) $
        \ ((_, dataSeq), (backOff, numRetries)) -> do
          case M.lookup dataSeq rcbOutputQ of
            Nothing -> do
              -- Received ACK-ECHO for this packet and there is no need
              -- to keep resending this packet. Clear it.
              return Nothing
            Just dataPkt -> if numRetries > optMaxRetries rcbConnOpt
              then left TooManyRetries
              else do
                -- Try to send it
                ok <- liftIO $ sendMailbox rcbToNic dataPkt
                if not ok
                  then
                    -- This mean the connection was closed.
                    left PeerClosed
                  else do
                    -- And set the backoff timeout for this packet
                    let
                      (nextTime, nextBackOff) = calcBackOff now backOff
                    return $ Just ((nextTime, dataSeq),
                                   (nextBackOff, numRetries + 1))
    case eiRes of
      Left err ->
        return (s, Left err)
      Right newResends -> do
        let
          -- Add back new backoffs
          combine = maybe id (uncurry M.insert)
          newResendQ = M.foldr combine rest newResends
          s' = s { rcbResendQ = newResendQ }
        return (s', Right ())

-- We will see many `True <- sendMailbox ...` here since this is expected
-- to succeed -- the mailboxes will only be closed after we set the
-- rcbState to RcbClosed (and kill those threads).
runRecv :: RcbRef -> IO ()
runRecv rcbRef = do
  fromNic <- rcbFromNic <$> readMVar rcbRef
  go fromNic
 where
  go fromNic = do
    mbPkt <- recvMailbox fromNic
    case mbPkt of
      Just pkt ->
        modifyMVar rcbRef (onPkt pkt)
        go fromNic
      Nothing ->
        -- This mean the connection was closed.
        return (Left PeerClosed)

  onPkt :: Packet -> Rcb -> IO Rcb
  onPkt pkt rcb@(Rcb {..}) = onPktState rcbState pkt rcb 

  onPktState _ pkt@(Packet {..}) rcb@(Rcb {..})
    | isDataPkt pkt -> do
      -- Send a DATA-ACK anytime a DATA packet is received.
      ackPkt = mkDataAckPkt pktSeqNo
      True <- sendMailbox rcbToNic ackPkt

      -- Check if we need to deliver this payload.
      if rcbLastDeliverySeq < pktSeqNo
        then do
          let
            -- And see how many payloads shall we deliver
            (newDeliveryQ, newLastDeliverySeq, sequentialPayloads) =
              mergeExtract rcbDeliveryQ rcbLastDeliverySeq
          True <- any id . (True:)
              <$> mapM (sendMailbox rcbToApp) sequentialPayloads
          return $ rcb
            { rcbDeliveryQ = newDeliveryQ
            , rcbLastDeliverySeq = newLastDeliverySeq
            }
        else
          return rcb

    | isDataAckPkt pkt ->
      -- And the resending thread will note this and stop rescheduling
      -- this packet.
      return $ rcb { rcbOutputQ = M.delete pktSeqId rcbOutputQ }

    | isFinPkt pkt -> do
      -- Always send a reply.
      ackPkt = mkFinAckPkt pktSeqNo
      True <- sendMailbox rcbToNic ackPkt
      -- Shutdown App -> Nic.
      sealMailbox rcbFromApp
      let
        mbChange = case rcbState of
          RcbOpen -> Just $ \ s -> s
            -- Only change the state and record the seq when we were open.
            { rcbFinSeq = pktSeqSeq
            , rcbState = RcbCloseWait
            }
          _ -> Nothing
      return $ maybe rcb ($ rcb) mbChange

    | isFinAckPkt pkt -> do
      let
        mbChange = case rcbState of
          RcbFinSent -> Just $ \ s -> s
            -- Set the state to CloseWait if not there yet.
            -- If we changed the state, record the FIN's seqNo as well.
            { rcbFinSeq = pktSeqNo
            , rcbState = RcbCloseWait
            , rcbOutputQ = M.delete pktSeqNo rcbOutputQ
            -- Also stop sending the FIN
            }
          _ -> Nothing

    | isRstPkt pkt -> internalResetEverything rcb

-- XXX
internalResetEverything rcb@(Rcb {..}) = do
  mapM_ cancel [rcbResendThread, rcbSendThread, rcbRecvThread]
  return $ rcb { rcbState = RcbClosed }

runSend :: RcbRef -> IO ()
runSend rcbRef = do
  fromApp <- rcbFromApp <$> readMVar rcbRef
  go fromApp
 where
  go fromApp = do
    mbBs <- recvMailbox fromApp
    case mbBs of
      Nothing ->
        -- Sealed: FIN or closed. This thread is done.
        return ()
      Just (seqNo, payload) -> do
        modifyMVar_ rcbRef $ \ rcb@(Rcb {..}) ->
          sendDataOrFinPkt (mkDataPkt seqNo payload)
        -- Loop
        go fromApp


sendDataOrFinPacket :: Rcb -> Packet -> IO Rcb
sendDataOrFinPacket rcb@(Rcb {..}) packet@(Packet {..}) = do
  sendMailbox rcbToNic packet
  now <- getCurrentTime
  let
    -- Add to OutputQ and schedule a resend
    (nextTime, nextBackOff) =
      calcBackOff now (optDefaultBackOff rcbConnOpt)
    newOutputQ = M.insert pktSeqNo packet rcbOutputQ
    newResendQ = M.insert (nextTime, pktSeqNo) (nextBackOff, 0)
  return $ rcb
    { rcbOutputQ = newOutputQ
    , rcbResendQ = newResendQ
    }

shutdownRcb :: RcbRef -> IO ()
shutdownRcb rcbRef = modifyMVar_ rcbRef $ \ rcb@(Rcb {..}) -> do
  let
    finPkt = mkFinPkt $ rcbSeqGen + 1
  rcb' <- sendDataOrFinPkt rcb finPkt
  return $ rcb' { rcbState = RcbFinSent }

sendRcb :: RcbRef -> B.ByteString -> IO ()

recvRcb :: RcbRef -> IO B.ByteString

sendMailbox :: Mailbox a -> a -> IO Bool
sendMailbox (Mailbox (_, output, _)) a = P.send output a

recvMailbox :: Mailbox a -> IO (Maybe a)
recvMailbox (Mailbox (input, _, _)) = P.recv input

-- Closes the mailbox but still allow reading 
sealMailbox :: Mailbox a -> IO ()
sealMailbox (Mailbox (_, _, seal)) = atomically seal

calcBackOff :: UTCTime -> Int -> (UTCTime, Int)
calcBackOff now backOff = (nextTime, backOff * 2)
 where
  nextBackOffSec = fromIntegral nextBackOff / 1000000
  nextTime = addUTCTime nextBackOffSec now

mergeExtract :: M.Map Int a -> Int -> (M.Map Int a, Int, [a])
mergeExtract m begin = go m begin []
 where
  go src i dst = case M.lookup i src of
    Nothing -> (src, i, reverse dst)
    Just a -> go (M.delete i src) (i + 1) (a:dst)

