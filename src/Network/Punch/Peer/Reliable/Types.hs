module Network.Punch.Peer.Reliable.Types where

import Control.Concurrent.STM (STM, atomically)

-- This should of course be more low-level (like a c-struct).
-- However it seems that the strictness annotations in this type seems to
-- be not affecting the performance..
data Packet
  = Packet {
    pktSeqNo   :: !Int,
    -- ^ DATA packets use it as the sequence No.,
    -- while DATA_ACK packets use it as the acknowledgement No.
    pktFlags   :: ![PacketFlag],
    -- ^ Bit flags
    pktPayload :: !B.ByteString
    -- ^ Currently only valid for DATA packets
  }
  deriving (Show, Typeable, Data)
  -- ^ Invariant: serialized form takes <= 512 bytes.
  -- That is, payload should be <= 480 bytes.

-- | For the strict map
instance NFData Packet

data PacketFlag
  = ACK
  -- ^ Acks a previously received DATA / FIN packet.
  | DATA
  -- ^ Contains a valid payload. Expects a DATA-ACK reply.
  | FIN
  -- ^ Starts shutdown, expects a FIN-ACK reply
  | RST
  -- ^ Hard reset.
  deriving (Show, Eq, Ord, Enum, Bounded, Typeable, Data)

data ConnOption
  = ConnOption {
    optIsInitiator :: Bool,
    -- ^ True for client, False for server
    optDefaultBackOff :: Int,
    -- ^ In micros
    optMaxRetires :: Int,
    optRandGen :: GenIO
  }

data ConnectionError
  = PeerClosed
  | TooManyRetries
  deriving (Show, Eq, Ord, Typeable)

newtype Mailbox a = Mailbox (P.Input a, P.Output a, STM ())

-- XXX: Shall we call some of them `control blocks` instead?
type OutputQueue = M.Map Int Packet
type DeliveryQueue = M.Map Int B.ByteString
type ResendQueue = M.Map (UTCTime, Int) (Int, Int)
-- ^ (resend-time, DATA-seq) => (next-backoff-micros, n-retries)

instance NFData InputEntry
instance NFData InputQueue

data RcbState
  = RcbOpen
  | RcbFinSent
  | RcbCloseWait
  | RcbClosed
  deriving (Show, Eq)

-- | Reliable Control Block
data Rcb = Rcb
  { rcbConnOpt :: ConnOption
  , rcbState :: RcbState
  , rcbFromNic :: Mailbox Packet
  , rcbToNic :: Mailbox Packet
  , rcbFromApp :: Mailbox (Int, B.ByteString)
  -- ^ (SeqNo, Payload)
  -- We link the seqNo early since this makes FIN handling easier.
  , rcbToApp :: Mailbox B.ByteString
  , rcbSeqGen :: Int
  , rcbOutputQ :: OutputQueue
  , rcbDeliveryQ :: DeliveryQueue
  , rcbLastDeliverySeq :: Int
  , rcbResendQ :: ResendQueue
  , rcbResendThread :: Async ()
  , rcbRecvThread :: Async ()
  , rcbSendThread :: Async ()
  }

type RcbRef = MVar Rcb

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
        -- Only change the state when we were open.
        nextState = case rcbState of
          RcbOpen -> RcbCloseWait
          _ -> rcbState
      return $ rcb { rcbState = nextState }

    | isFinAckPkt pkt -> do
      let
        nextState = case rcbState of
          RcbFinSent ->
            -- And set the state to CloseWait if not there yet.
            RcbCloseWait
          _ ->
            rcbState
      return $ rcb
        { rcbState = nextState
          -- Also stop sending the FIN
        , rcbOutputQ = M.delete pktSeqId rcbOutputQ
        }

    | isRstPkt pkt -> internalResetAnything rcb

-- XXX
internalResetAnything rcb@(Rcb {..}) = do
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

shutdown :: RcbRef -> IO ()
shutdown rcbRef = modifyMVar_ rcbRef $ \ rcb@(Rcb {..}) -> do
  let
    finPkt = mkFinPkt $ rcbSeqGen + 1
  rcb' <- sendDataOrFinPkt rcb finPkt
  return $ rcb' { rcbState = RcbFinSent }

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

-- Serialization
putPacket :: Packet -> S.Put
putPacket (Packet {..}) = do
  S.put pktSeqNo
  S.put $ foldFlags pktFlags
  S.put pktPayload

getPacket :: S.Get Packet
getPacket = Packet <$> S.get <*> (unfoldFlags <$> S.get) <*> S.get

foldFlags :: Enum a => [a] -> Int
foldFlags = foldr (flip setFlag) 0

unfoldFlags :: (Bounded a, Enum a) => Int -> [a]
unfoldFlags flag = concatMap check [minBound..maxBound]
 where
  check a = if hasFlag flag a then [a] else []

