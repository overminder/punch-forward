-- Pipes-based UDP-to-reliable-protocol adapter

module Network.Punch.Peer.Reliable (
  module Network.Punch.Peer.Reliable.Types,
  newRcb,
  gracefullyShutdownRcb,
  sendRcb,
  recvRcb,
  transportsForRcb,
  
  sendMailbox,
  recvMailbox,
  toMailbox,
  fromMailbox
) where

import Control.Arrow (second)
import Control.Concurrent.Async (async)
import Control.Monad.Trans.Either (left, EitherT, runEitherT)
import Control.Monad.IO.Class (liftIO)
import Control.Monad (forM, replicateM, when)
import Control.Applicative ((<$>), (<*>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Concurrent.STM (STM, atomically)
import Data.Time
import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.Serialize as S
import Pipes (each, runEffect, (>->), Consumer, Producer)
import qualified Pipes.Concurrent as P
import qualified Data.ByteString as B
import Text.Printf (printf)

import Network.Punch.Peer.Types
import Network.Punch.Peer.Reliable.Types
import Network.Punch.Util (cutBs, mapPipe)

instance Peer RcbRef where
  sendPeer = sendRcb
  recvPeer = recvRcb
  closePeer = gracefullyShutdownRcb

newRcb :: ConnOption -> IO RcbRef
newRcb opt = do
  rcbRef <- newEmptyMVar
  [fromNic, toNic] <- replicateM 2 $ P.spawn' P.Unbounded
  fromApp <- P.spawn' P.Unbounded
  toApp <- P.spawn' P.Unbounded
  tResend <- async $ runResend rcbRef
  tRecv <- async $ runRecv rcbRef
  tSend <- async $ runSend rcbRef
  
  putMVar rcbRef $ Rcb
    { rcbConnOpt = opt
    , rcbState = RcbOpen
    , rcbFromNic = Mailbox fromNic
    , rcbToNic = Mailbox toNic
    , rcbFromApp = Mailbox fromApp
    , rcbToApp = Mailbox toApp
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

gracefullyShutdownRcb :: RcbRef -> IO ()
gracefullyShutdownRcb rcbRef = modifyMVar_ rcbRef $ \ rcb@(Rcb {..}) -> do
  let
    finPkt = mkFinPkt $ rcbSeqGen + 1
  rcb' <- sendDataOrFinPkt rcb finPkt
  return $ rcb' { rcbState = RcbFinSent }

sendRcb :: RcbRef -> B.ByteString -> IO Bool
sendRcb rcbRef bs = modifyMVar rcbRef $ \ rcb@(Rcb {..}) -> do
  let
    bss = cutBs (optMaxPayloadSize rcbConnOpt) bs
    newSeqGen = rcbSeqGen + length bss
    changedRcb = rcb { rcbSeqGen = newSeqGen }
  ok <- sendsMailbox rcbFromApp $ zip [rcbSeqGen + 1..] bss
  return (changedRcb, ok)

recvRcb :: RcbRef -> IO (Maybe B.ByteString)
recvRcb rcbRef = recvMailbox . rcbToApp =<< readMVar rcbRef

transportsForRcb
  :: RcbRef
  -> (Producer B.ByteString IO (), Consumer B.ByteString IO ())
transportsForRcb rcbRef = (producer, consumer)
 where
  producer = do
    Mailbox (_, toNic, _) <- liftIO (rcbToNic <$> readMVar rcbRef)
    P.fromInput toNic >-> mapPipe (S.runPut . putPacket)

  consumer = do
    Mailbox (fromNic, _, _) <- liftIO (rcbFromNic <$> readMVar rcbRef)
    mapPipe (either reportPktErr id . S.runGet getPacket) >-> P.toOutput fromNic
  
  reportPktErr e = error $ "[rcb.transport] Parse error: " ++ show e

----

mkDataPkt seqNo payload = Packet seqNo [DATA] payload
mkFinAckPkt seqNo = Packet seqNo [FIN, ACK] B.empty
mkFinPkt seqNo = Packet seqNo [FIN] B.empty
mkAckPkt seqNo = Packet seqNo [ACK] B.empty
mkDataAckPkt seqNo = Packet seqNo [DATA, ACK] B.empty
mkRstPkt = Packet (-1) [RST] B.empty

areFlags flags expected = L.sort flags == L.sort expected

runResend :: RcbRef -> IO ()
runResend rcbRef = go
 where
  go = do
    threadDelay (100 * 1000)
    shallContinue <- modifyMVar rcbRef $ \ rcb@(Rcb {..}) -> do
      if rcbState == RcbClosed
        then return (rcb, False)
        else do
          eiRcb <- runEitherT $ resendOnce rcb
          let
            (rcbRes, mbErr) = case eiRcb of
              Left e -> (rcb, Just e)
              Right changedRcb
                | isCloseWaitDone changedRcb ->
                  (changedRcb, Just GracefullyShutdown)
                | otherwise ->
                  (changedRcb, Nothing)
          case mbErr of
            Nothing ->
              return (rcbRes, True)
            Just err -> do
              printCloseReason "runResend" err
              rcbRes2 <- internalResetEverything rcbRes
              return (rcbRes2, False)
        
    when shallContinue go

  isCloseWaitDone :: Rcb -> Bool
  isCloseWaitDone rcb@(Rcb {..}) =
    rcbState == RcbCloseWait &&
    rcbLastDeliverySeq + 1 == rcbFinSeq &&
    -- ^ We have received all DATA packets from the other side.
    M.null rcbOutputQ
    -- ^ And the other side has ACKed all of our DATA packets.

  resendOnce :: Rcb -> EitherT CloseReason IO Rcb
  resendOnce rcb@(Rcb {..}) = do
    now <- liftIO $ getCurrentTime
    let (works, rest) = M.split (now, (-1)) rcbResendQ
    newResends <- forM (M.toList works) $
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
    let
      -- Add back new backoffs
      combine = maybe id (uncurry M.insert)
      changedRcb = rcb { rcbResendQ = foldr combine rest newResends }
    return changedRcb

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
        maybe (go fromNic) selectivePrint =<< modifyMVar rcbRef (onPkt pkt)
      Nothing -> do
        currState <- rcbState <$> readMVar rcbRef
        when (currState /= RcbClosed) $
          -- This mean the connection was closed.
          printCloseReason "runRecv|fromNic->Nothing|Debug" PeerClosed

  selectivePrint err = case err of
    AlreadyClosed -> return ()
    _ -> printCloseReason "runRecv|fromNic->Just" err

  onPkt :: Packet -> Rcb -> IO (Rcb, Maybe CloseReason)
  onPkt pkt rcb@(Rcb {..}) = do
    eiRes <- runEitherT $ onPktState rcbState pkt rcb
    return $ either (second Just) (,Nothing) eiRes

  onPktState :: RcbState -> Packet -> Rcb -> EitherT (Rcb, CloseReason) IO Rcb
  onPktState RcbClosed pkt@(Packet {..}) rcb@(Rcb {..}) =
    left (rcb, AlreadyClosed)

  onPktState _ pkt@(Packet {..}) rcb@(Rcb {..})
    | pktFlags `areFlags` [DATA] = liftIO $ do
      -- Send a DATA-ACK anytime a DATA packet is received.
      let ackPkt = mkDataAckPkt pktSeqNo
      True <- sendMailbox rcbToNic ackPkt

      -- Check if we need to deliver this payload.
      if rcbLastDeliverySeq < pktSeqNo
        then do
          let
            -- And see how many payloads shall we deliver
            insertedDeliveryQ = M.insert pktSeqNo pktPayload rcbDeliveryQ
            (newDeliveryQ, newLastDeliverySeq, sequentialPayloads) =
              mergeExtract insertedDeliveryQ rcbLastDeliverySeq
          True <- any id . (True:)
              <$> mapM (sendMailbox rcbToApp) sequentialPayloads
          return $ rcb
            { rcbDeliveryQ = newDeliveryQ
            , rcbLastDeliverySeq = newLastDeliverySeq
            }
        else
          return rcb

    | pktFlags `areFlags` [DATA, ACK] =
      -- And the resending thread will note this and stop rescheduling
      -- this packet.
      return $ rcb { rcbOutputQ = M.delete pktSeqNo rcbOutputQ }

    | pktFlags `areFlags` [FIN] = liftIO $ do
      -- Always send a reply.
      let ackPkt = mkFinAckPkt pktSeqNo
      True <- sendMailbox rcbToNic ackPkt
      -- Shutdown App -> Nic.
      sealMailbox rcbFromApp
      let
        mbChange = case rcbState of
          RcbOpen -> Just $ \ s -> s
            -- Only change the state and record the seq when we were open.
            { rcbFinSeq = pktSeqNo
            , rcbState = RcbCloseWait
            }
          _ -> Nothing
      return $ maybe rcb ($ rcb) mbChange

    | pktFlags `areFlags` [FIN, ACK] = do
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
      return $ maybe rcb ($ rcb) mbChange

    | pktFlags `areFlags` [RST] = do
      -- This can happen before FIN-ACK is received (if we are initiating
      -- the graceful shutdown)
      let reason = if rcbState == RcbClosed then AlreadyClosed else PeerClosed
      liftIO $ putStrLn $ "RST on " ++ show rcbState
      rcb' <- liftIO $ internalResetEverything rcb
      left (rcb', reason)

internalResetEverything rcb@(Rcb {..}) = do
  -- We send an RST as well
  sendMailbox rcbToNic mkRstPkt

  sealMailbox rcbFromApp
  sealMailbox rcbToApp
  sealMailbox rcbFromNic
  sealMailbox rcbToNic
  -- And the runner threads will stop by themselves.
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
          sendDataOrFinPkt rcb (mkDataPkt seqNo payload)
        -- Loop
        go fromApp


sendDataOrFinPkt :: Rcb -> Packet -> IO Rcb
sendDataOrFinPkt rcb@(Rcb {..}) packet@(Packet {..}) = do
  sendMailbox rcbToNic packet
  now <- getCurrentTime
  let
    -- Add to OutputQ and schedule a resend
    (nextTime, nextBackOff) =
      calcBackOff now (optDefaultBackOff rcbConnOpt)
    newOutputQ = M.insert pktSeqNo packet rcbOutputQ
    newResendQ = M.insert (nextTime, pktSeqNo) (nextBackOff, 0) rcbResendQ
  return $ rcb
    { rcbOutputQ = newOutputQ
    , rcbResendQ = newResendQ
    }

sendMailbox :: Mailbox a -> a -> IO Bool
sendMailbox (Mailbox (output, _, _)) a = atomically $ P.send output a

sendsMailbox :: Mailbox a -> [a] -> IO Bool
sendsMailbox (Mailbox (output, _, _)) xs =
  runEffect $ (each xs >> return True) >-> (P.toOutput output >> return False)

recvMailbox :: Mailbox a -> IO (Maybe a)
recvMailbox (Mailbox (_, input, _)) = atomically $ P.recv input

fromMailbox (Mailbox (_, input, _)) = P.fromInput input
toMailbox (Mailbox (output, _, _)) = P.toOutput output

-- Closes the mailbox but still allow reading 
sealMailbox :: Mailbox a -> IO ()
sealMailbox (Mailbox (_, _, seal)) = atomically seal

calcBackOff :: UTCTime -> Int -> (UTCTime, Int)
calcBackOff now backOff = (nextTime, backOff * 2)
 where
  nextBackOffSec = fromIntegral backOff / 1000000
  nextTime = addUTCTime nextBackOffSec now

mergeExtract :: M.Map Int a -> Int -> (M.Map Int a, Int, [a])
mergeExtract m begin = go m begin []
 where
  go src i dst =
    let i' = i + 1
     in case M.lookup i' src of
          Nothing -> (src, i, reverse dst)
          Just a -> go (M.delete i' src) i' (a:dst)

printCloseReason :: String -> CloseReason -> IO ()
printCloseReason tag err =
  printf "[%s] Connection closed by `%s`.\n" tag (show err)
