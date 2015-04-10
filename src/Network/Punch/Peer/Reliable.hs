-- Pipes-based UDP-to-reliable-protocol adapter

module Network.Punch.Peer.Reliable (
  module Network.Punch.Peer.Reliable.Types,
  newRcb,
  newRcbFromPeer,
  gracefullyShutdownRcb,
  sendRcb,
  recvRcb,
  
  -- XXX: The functions below have unstable signatures
  sendMailbox,
  recvMailbox,
  toMailbox,
  fromMailbox
) where

import Control.Arrow (second)
import Control.Concurrent.Async (async)
import Control.Exception (try, SomeException)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Either (left, EitherT, runEitherT)
import Control.Monad.IO.Class (liftIO)
import Control.Monad (forM, replicateM, when)
import Control.Applicative ((<$>), (<*>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Concurrent.STM
  ( STM
  , atomically
  , newTVarIO
  , readTVar
  , writeTVar
  , modifyTVar'
  , retry
  , orElse
  )
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
  sendPeer peer = atomically . sendRcb peer
  recvPeer = atomically . recvRcb
  closePeer = gracefullyShutdownRcb

newRcb :: ConnOption -> IO RcbRef
newRcb opt@(ConnOption {..}) = do
  stateRef <- newTVarIO RcbOpen
  seqGenRef <- newTVarIO 0
  finSeqRef <- newTVarIO (-1)
  lastDeliverySeqRef <- newTVarIO 0
  outputQRef <- newTVarIO M.empty
  deliveryQRef <- newTVarIO M.empty
  resendQRef <- newTVarIO M.empty
  extraFinalizersRef <- newTVarIO []

  -- Used for circular initialization
  rcbRef <- newEmptyMVar

  -- Bounded buffers for inter-thread communications
  fromApp <- P.spawn' (P.bounded optTxBufferSize)
  -- This is unbounded: NIC's tx is controlled by the unacked packet count
  toNic <- P.spawn' P.unbounded
  fromNic <- P.spawn' (P.bounded optRxBufferSize)
  toApp <- P.spawn' (P.bounded optRxBufferSize)

  tResend <- async $ runResend rcbRef
  tRecv <- async $ runRecv rcbRef
  tSend <- async $ runSend rcbRef
  tKeepAlive <- async $ runKeepAlive rcbRef
  -- ^ Those will kill themselves when the connection is closed
  
  let
    rcb = Rcb
      { rcbConnOpt = opt
      , rcbFromNic = Mailbox fromNic
      , rcbToNic = Mailbox toNic
      , rcbFromApp = Mailbox fromApp
      , rcbToApp = Mailbox toApp
      , rcbState = stateRef
      , rcbSeqGen = seqGenRef
      , rcbFinSeq = finSeqRef
      , rcbLastDeliverySeq = lastDeliverySeqRef
      , rcbOutputQ = outputQRef
      , rcbDeliveryQ = deliveryQRef
      , rcbResendQ = resendQRef
      , rcbExtraFinalizers = extraFinalizersRef
      }
  putMVar rcbRef rcb
  return rcb

newRcbFromPeer :: Peer p => ConnOption -> p -> IO RcbRef
newRcbFromPeer rcbOpt peer = do
  rcb@(Rcb {..}) <- newRcb rcbOpt
  let (bsFromRcb, bsToRcb) = transportsForRcb rcb
  async $ runEffect $ fromPeer peer >-> bsToRcb
  async $ runEffect $ bsFromRcb >-> toPeer peer
  atomically $ modifyTVar' rcbExtraFinalizers (closePeer peer :)
  return rcb

gracefullyShutdownRcb :: RcbRef -> IO ()
gracefullyShutdownRcb rcb@(Rcb {..}) = do
  now <- getCurrentTime
  atomically $ do
    seqGen <- readTVar rcbSeqGen
    let
      finPkt = mkFinPkt $ seqGen + 1
    mut' <- sendDataOrFinPkt rcb finPkt now
    writeTVar rcbState RcbFinSent

sendRcb :: RcbRef -> B.ByteString -> STM Bool
sendRcb rcb@(Rcb {..}) bs = do
  seqGen <- readTVar rcbSeqGen
  let
    bss = cutBs (optMaxPayloadSize rcbConnOpt) bs
    newSeqGen = seqGen + length bss
  writeTVar rcbSeqGen newSeqGen
  -- Blocks when fromApp buffer is full.
  sendsMailbox rcbFromApp $ zip [seqGen + 1..] bss

recvRcb :: RcbRef -> STM (Maybe B.ByteString)
-- Blocks when toApp buffer is empty
recvRcb rcb@(Rcb {..}) = recvMailbox rcbToApp

transportsForRcb
  :: RcbRef
  -> (Producer B.ByteString IO (), Consumer B.ByteString IO ())
transportsForRcb (Rcb {..}) = (producer, consumer)
 where
  producer = do
    let Mailbox (_, toNic, _) = rcbToNic
    P.fromInput toNic >-> mapPipe (S.runPut . putPacket)

  consumer = do
    let Mailbox (fromNic, _, _) = rcbFromNic
    mapPipe (either reportPktErr id . S.runGet getPacket) >->
      P.toOutput fromNic
  
  reportPktErr e = error $ "[rcb.transport] Parse error: " ++ show e

----

mkDataPkt seqNo payload = Packet seqNo [DATA] payload
mkFinAckPkt seqNo = Packet seqNo [FIN, ACK] B.empty
mkFinPkt seqNo = Packet seqNo [FIN] B.empty
mkAckPkt seqNo = Packet seqNo [ACK] B.empty
mkDataAckPkt seqNo = Packet seqNo [DATA, ACK] B.empty
mkRstPkt = Packet (-1) [RST] B.empty

areFlags flags expected = L.sort flags == L.sort expected

runResend :: MVar Rcb -> IO ()
runResend rcbRef = readMVar rcbRef >>= go
 where
  go rcb = do
    threadDelay (100 * 1000)
    now <- getCurrentTime
    (shallContinue, ioAction) <- atomically $ goSTM rcb now
    ioAction
    when shallContinue $ go rcb

  goSTM rcb@(Rcb {..}) now = do
    state <- readTVar rcbState
    if state == RcbClosed
      then return (False, return ())
      else do
        eiErr <- runEitherT $ resendOnce rcb now
        mbErr <- case eiErr of
          Left e -> return $ Just e
          Right () -> do
            cwd <- isCloseWaitDone rcb
            if cwd
              then return $ Just GracefullyShutdown
              else return Nothing
        case mbErr of
          Nothing ->
            return (True, return ())
          Just err -> do
            let action = printCloseReason "runResend" err
            extraFinalizers <- internalResetEverything rcb
            return (False, action >> extraFinalizers)
        

  isCloseWaitDone :: Rcb -> STM Bool
  isCloseWaitDone (Rcb {..}) = do
    state <- readTVar rcbState
    lastDeliverySeq <- readTVar rcbLastDeliverySeq
    finSeq <- readTVar rcbFinSeq 
    outputQ <- readTVar rcbOutputQ
    return $
      state == RcbCloseWait &&
      lastDeliverySeq + 1 == finSeq &&
      -- ^ We have received all DATA packets from the other side.
      M.null outputQ
    -- ^ And the other side has ACKed all of our DATA packets.

  -- Resend packets in the resendQ and update their last-send-time
  -- Invariant: (Left CloseReason) means that the rcb is not changed
  resendOnce :: Rcb -> UTCTime -> EitherT CloseReason STM ()
  resendOnce (Rcb {..}) now = do
    (works, rest) <- M.split (now, (-1)) <$> lift (readTVar rcbResendQ)
    outputQ <- lift $ readTVar rcbOutputQ
    newResends <- forM (M.toList works) $
      \ ((_, dataSeq), (backOff, numRetries)) -> do
        case M.lookup dataSeq outputQ of
          Nothing -> do
            -- Received ACK-ECHO for this packet and there is no need
            -- to keep resending this packet. Clear it.
            return Nothing
          Just dataPkt -> if numRetries > optMaxRetries rcbConnOpt
            then left TooManyRetries
            else do
              -- Try to resend it
              ok <- lift $ sendMailbox rcbToNic dataPkt
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
      newResendQ = foldr combine rest newResends
    lift $ writeTVar rcbResendQ newResendQ

-- We will see many `True <- sendMailbox ...` here since this is expected
-- to succeed -- the mailboxes will only be closed after we set the
-- rcbState to RcbClosed (and kill those threads).
runRecv :: MVar Rcb -> IO ()
runRecv rcbRef = readMVar rcbRef >>= go
 where
  go rcb = do
    mbLast <- atomically $ goSTM rcb
    case mbLast of
      Nothing -> go rcb
      Just action -> action

  goSTM :: Rcb -> STM (Maybe (IO ()))
  goSTM rcb@(Rcb {..}) = do
    mbPkt <- recvMailbox rcbFromNic
    case mbPkt of
      Just pkt -> do
        mbErr <- onPkt pkt rcb
        return $ fmap mergeLogAndAction mbErr
      Nothing -> do
        currState <- readTVar rcbState
        if currState /= RcbClosed
          -- This mean the connection was closed.
          then return $ Just $ 
            printCloseReason "runRecv|fromNic->Nothing|Debug" PeerClosed
          else return $ Just $ return ()

  mergeLogAndAction (err, action) = case err of
    AlreadyClosed -> action
    _ -> printCloseReason "runRecv|fromNic->Just" err >> action

  onPkt :: Packet -> Rcb -> STM (Maybe (CloseReason, IO ()))
  onPkt pkt rcb@(Rcb {..}) = do
    state <- readTVar rcbState
    eiRes <- runEitherT $ onPktState state pkt rcb
    return $ either Just (const $ Nothing) eiRes

  onPktState :: RcbState -> Packet -> Rcb
             -> EitherT (CloseReason, IO ()) STM ()
  onPktState RcbClosed pkt rcb =
    left (AlreadyClosed, return ())

  onPktState state pkt@(Packet {..}) rcb@(Rcb {..})
    | pktFlags `areFlags` [DATA] =
      let
        sendDataToApp = do
          -- Send a DATA-ACK anytime a DATA packet is received.
          let ackPkt = mkDataAckPkt pktSeqNo
          True <- sendMailbox rcbToNic ackPkt

          -- Check if we need to deliver this payload.
          lastDeliverySeq <- readTVar rcbLastDeliverySeq
          when (lastDeliverySeq < pktSeqNo) $ do
            deliveryQ <- readTVar rcbDeliveryQ
            let
              -- And see how many payloads shall we deliver
              insertedDeliveryQ = M.insert pktSeqNo pktPayload deliveryQ
              (newDeliveryQ, newLastDeliverySeq, sequentialPayloads) =
                mergeExtract insertedDeliveryQ lastDeliverySeq
            -- This might block if toApp mailbox is full.
            -- In this case, the other branch (dropThePacket)
            -- will be taken.
            True <- sendsMailbox rcbToApp sequentialPayloads
            writeTVar rcbDeliveryQ newDeliveryQ
            writeTVar rcbLastDeliverySeq newLastDeliverySeq

        -- Drop the packet reply when the toApp queue is full
        dropThePacket = return ()
      in
        lift (sendDataToApp `orElse` dropThePacket)

    | pktFlags `areFlags` [DATA, ACK] =
      -- And the resending thread will note this and stop rescheduling
      -- this packet.
      lift $ modifyTVar' rcbOutputQ $ M.delete pktSeqNo

    | pktFlags `areFlags` [FIN] = lift $ do
      -- Always send a reply.
      let ackPkt = mkFinAckPkt pktSeqNo
      True <- sendMailbox rcbToNic ackPkt
      -- Shutdown App -> Nic.
      sealMailbox rcbFromApp
      when (state == RcbOpen) $ do
        -- Only change the state and record the seq when we were open.
        writeTVar rcbFinSeq pktSeqNo
        writeTVar rcbState RcbCloseWait

    | pktFlags `areFlags` [FIN, ACK] && state == RcbFinSent = lift $ do
      -- Set the state to CloseWait if not there yet.
      -- If we changed the state, record the FIN's seqNo as well.
      writeTVar rcbFinSeq pktSeqNo
      writeTVar rcbState RcbCloseWait
      -- Also stop sending the FIN
      modifyTVar' rcbOutputQ $ M.delete pktSeqNo

    | pktFlags `areFlags` [RST] = do
      -- This can happen before FIN-ACK is received (if we are initiating
      -- the graceful shutdown)
      let
        reason = if state == RcbClosed then AlreadyClosed else PeerClosed
        logAction = putStrLn $ "RST on " ++ show state
      extraFinalizers <- lift $ internalResetEverything rcb
      left (reason, logAction >> extraFinalizers)

runKeepAlive rcbRef = readMVar rcbRef >>= go
 where 
  go rcb = do
    threadDelay (1000000)
    ok <- atomically $ sendRcb rcb B.empty
    if ok
      then go rcb
      else return ()

internalResetEverything :: Rcb -> STM (IO ())
internalResetEverything rcb@(Rcb {..}) = do
  -- We send an RST as well
  sendMailbox rcbToNic mkRstPkt

  sealMailbox rcbFromApp
  sealMailbox rcbToApp
  sealMailbox rcbFromNic
  sealMailbox rcbToNic

  writeTVar rcbState RcbClosed

  -- Let the caller to stop the underlying raw peer
  -- And the runner threads will stop by themselves.
  extraFinalizers <- readTVar rcbExtraFinalizers 
  return $ sequence_ extraFinalizers 

runSend :: MVar Rcb -> IO ()
runSend rcbRef = readMVar rcbRef >>= go
 where
  go rcb = do
    now <- getCurrentTime
    goOn <- atomically $ goSTM rcb now
    when goOn (go rcb)

  goSTM rcb@(Rcb {..}) now = do
    -- Check if there are too many unacked packets. If so,
    -- wait until the number decrease.
    let ConnOption {..} = rcbConnOpt

    tooManyUnacks <- txUnackOverflow rcb
    when tooManyUnacks retry

    mbBs <- recvMailbox rcbFromApp
    case mbBs of
      Nothing ->
        -- Sealed: FIN or closed. This thread is done.
        -- False to discontinue the loop
        return False
      Just (seqNo, payload) -> do
        sendDataOrFinPkt rcb (mkDataPkt seqNo payload) now
        -- True to continue the loop
        return True

  barf :: SomeException -> IO ()
  barf e = do
    putStrLn $ "[runSend] STM.retry: " ++ show e

sendDataOrFinPkt :: Rcb -> Packet -> UTCTime -> STM ()
sendDataOrFinPkt (Rcb {..}) packet@(Packet {..}) now = do
  sendMailbox rcbToNic packet
  let
    -- Add to OutputQ and schedule a resend
    (nextTime, nextBackOff) =
      calcBackOff now (optDefaultBackOff rcbConnOpt)
  modifyTVar' rcbOutputQ $ M.insert pktSeqNo packet
  modifyTVar' rcbResendQ $ M.insert (nextTime, pktSeqNo) (nextBackOff, 0)


sendMailbox :: Mailbox a -> a -> STM Bool
sendMailbox (Mailbox (output, _, _)) a = P.send output a

sendsMailbox :: Mailbox a -> [a] -> STM Bool
sendsMailbox m@(Mailbox (output, _, _)) xs =
  all id <$> mapM (sendMailbox m) xs

recvMailbox :: Mailbox a -> STM (Maybe a)
recvMailbox (Mailbox (_, input, _)) = P.recv input

fromMailbox (Mailbox (_, input, _)) = P.fromInput input
toMailbox (Mailbox (output, _, _)) = P.toOutput output

-- Closes the mailbox but still allow reading 
sealMailbox :: Mailbox a -> STM ()
sealMailbox (Mailbox (_, _, seal)) = seal

calcBackOff :: UTCTime -> Int -> (UTCTime, Int)
calcBackOff now backOff = (nextTime, floor $ (fromIntegral backOff) * 1.2)
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

txUnackOverflow :: Rcb -> STM Bool
txUnackOverflow (Rcb {..}) = do
  let ConnOption {..} = rcbConnOpt
  unacked <- M.size <$> readTVar rcbResendQ
  return $ unacked >= optMaxUnackedPackets

