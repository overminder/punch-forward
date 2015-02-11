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
  , retry
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
  let
    mut = RcbMut
      { rcbState = RcbOpen
      , rcbSeqGen = 0
      , rcbFinSeq = (-1)
      , rcbLastDeliverySeq = 0
      , rcbOutputQ = M.empty
      , rcbDeliveryQ = M.empty
      , rcbResendQ = M.empty
      , rcbExtraFinalizers = []
      }

  mutRef <- newTVarIO mut
  -- Used for circular initialization
  rcbRef <- newEmptyMVar
  [fromNic, toNic] <- replicateM 2 $ P.spawn' P.Unbounded
  fromApp <- P.spawn' (P.Bounded optTxBufferSize)
  toApp <- P.spawn' (P.Bounded optRxBufferSize)

  tResend <- async $ runResend rcbRef
  tRecv <- async $ runRecv rcbRef
  tSend <- async $ runSend rcbRef
  tKeepAlive <- async $ runKeepAlive rcbRef
  -- ^ Those will kill themselves when the connection is closed
  
  putMVar rcbRef $ Rcb
    { rcbConnOpt = opt
    , rcbFromNic = Mailbox fromNic
    , rcbToNic = Mailbox toNic
    , rcbFromApp = Mailbox fromApp
    , rcbToApp = Mailbox toApp
    , rcbMutRef = mutRef
    }
  readMVar rcbRef

modifyRcb :: Rcb -> (RcbMut -> STM (RcbMut, a)) -> STM a
modifyRcb (Rcb {..}) f = do
  mut <- readTVar rcbMutRef
  (mut', a) <- f mut
  writeTVar rcbMutRef mut'
  return a

modifyRcb_ :: Rcb -> (RcbMut -> STM RcbMut) -> STM ()
modifyRcb_ rcb f = modifyRcb rcb f'
 where
  f' mut = do
    mut' <- f mut
    return (mut', ())

newRcbFromPeer :: Peer p => ConnOption -> p -> IO RcbRef
newRcbFromPeer rcbOpt peer = do
  rcb <- newRcb rcbOpt
  let (bsFromRcb, bsToRcb) = transportsForRcb rcb
  async $ runEffect $ fromPeer peer >-> bsToRcb
  async $ runEffect $ bsFromRcb >-> toPeer peer
  atomically $ modifyRcb_ rcb $ \ mut@(RcbMut {..}) ->
    return $ mut
      { rcbExtraFinalizers = (closePeer peer) : rcbExtraFinalizers }
  return rcb

gracefullyShutdownRcb :: RcbRef -> IO ()
gracefullyShutdownRcb rcb = do
  now <- getCurrentTime
  atomically $ modifyRcb_ rcb $ \ mut@(RcbMut {..}) -> do
    let
      finPkt = mkFinPkt $ rcbSeqGen + 1
    mut' <- sendDataOrFinPkt rcb mut finPkt now
    return $ mut' { rcbState = RcbFinSent }

sendRcb :: RcbRef -> B.ByteString -> STM Bool
sendRcb rcb@(Rcb {..}) bs = modifyRcb rcb $ \ mut@(RcbMut {..}) -> do
  let
    bss = cutBs (optMaxPayloadSize rcbConnOpt) bs
    newSeqGen = rcbSeqGen + length bss
    changedMut = mut { rcbSeqGen = newSeqGen }
  ok <- sendsMailbox rcbFromApp $ zip [rcbSeqGen + 1..] bss
  return (changedMut, ok)

recvRcb :: RcbRef -> STM (Maybe B.ByteString)
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

  goSTM rcb now = modifyRcb rcb $ \ mut@(RcbMut {..}) -> do
    if rcbState == RcbClosed
      then return (mut, (False, return ()))
      else do
        eiMut <- runEitherT $ resendOnce rcb mut now
        let
          (mutRes, mbErr) = case eiMut of
            Left e -> (mut, Just e)
            Right changedMut
              | isCloseWaitDone changedMut ->
                (changedMut, Just GracefullyShutdown)
              | otherwise ->
                (changedMut, Nothing)
        case mbErr of
          Nothing ->
            return (mutRes, (True, return ()))
          Just err -> do
            let action = printCloseReason "runResend" err
            (mutRes2, extraFinalizers) <- internalResetEverything rcb mutRes
            return (mutRes2, (False, action >> extraFinalizers))
        

  isCloseWaitDone :: RcbMut -> Bool
  isCloseWaitDone (RcbMut {..}) =
    rcbState == RcbCloseWait &&
    rcbLastDeliverySeq + 1 == rcbFinSeq &&
    -- ^ We have received all DATA packets from the other side.
    M.null rcbOutputQ
    -- ^ And the other side has ACKed all of our DATA packets.

  resendOnce :: Rcb -> RcbMut -> UTCTime -> EitherT CloseReason STM RcbMut
  resendOnce (Rcb {..}) mut@(RcbMut {..}) now = do
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
    return $ mut { rcbResendQ = newResendQ }

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
      Just action ->
        action

  goSTM rcb@(Rcb {..}) = do
    mbPkt <- recvMailbox rcbFromNic
    case mbPkt of
      Just pkt -> do
        mbErr <- modifyRcb rcb (onPkt pkt rcb)
        return $ fmap mergeLogAndAction mbErr
      Nothing -> do
        currState <- rcbState <$> readTVar rcbMutRef
        if currState /= RcbClosed
          -- This mean the connection was closed.
          then return $ Just $ 
            printCloseReason "runRecv|fromNic->Nothing|Debug" PeerClosed
          else return $ Just $ return ()

  mergeLogAndAction (err, action) = case err of
    AlreadyClosed -> action
    _ -> printCloseReason "runRecv|fromNic->Just" err >> action

  onPkt :: Packet -> Rcb -> RcbMut
        -> STM (RcbMut, Maybe (CloseReason, IO ()))
  onPkt pkt rcb mut@(RcbMut {..}) = do
    eiRes <- runEitherT $ onPktState rcbState pkt rcb mut
    return $ either (second Just) (,Nothing) eiRes

  onPktState :: RcbState -> Packet -> Rcb -> RcbMut
             -> EitherT (RcbMut, (CloseReason, IO ())) STM RcbMut
  onPktState RcbClosed pkt@(Packet {..}) rcb mut@(RcbMut {..}) =
    left (mut, (AlreadyClosed, return ()))

  onPktState _ pkt@(Packet {..}) rcb@(Rcb {..}) mut@(RcbMut {..})
    | pktFlags `areFlags` [DATA] = do
      -- Send a DATA-ACK anytime a DATA packet is received.
      let ackPkt = mkDataAckPkt pktSeqNo
      True <- lift $ sendMailbox rcbToNic ackPkt

      -- Check if we need to deliver this payload.
      if rcbLastDeliverySeq < pktSeqNo
        then do
          let
            -- And see how many payloads shall we deliver
            insertedDeliveryQ = M.insert pktSeqNo pktPayload rcbDeliveryQ
            (newDeliveryQ, newLastDeliverySeq, sequentialPayloads) =
              mergeExtract insertedDeliveryQ rcbLastDeliverySeq
          True <- any id . (True:)
              <$> mapM (lift . sendMailbox rcbToApp) sequentialPayloads
          return $ mut
            { rcbDeliveryQ = newDeliveryQ
            , rcbLastDeliverySeq = newLastDeliverySeq
            }
        else
          return mut

    | pktFlags `areFlags` [DATA, ACK] =
      -- And the resending thread will note this and stop rescheduling
      -- this packet.
      return $ mut { rcbOutputQ = M.delete pktSeqNo rcbOutputQ }

    | pktFlags `areFlags` [FIN] = do
      -- Always send a reply.
      let ackPkt = mkFinAckPkt pktSeqNo
      True <- lift $ sendMailbox rcbToNic ackPkt
      -- Shutdown App -> Nic.
      lift $ sealMailbox rcbFromApp
      let
        mbChange = case rcbState of
          RcbOpen -> Just $ \ s -> s
            -- Only change the state and record the seq when we were open.
            { rcbFinSeq = pktSeqNo
            , rcbState = RcbCloseWait
            }
          _ -> Nothing
      return $ maybe mut ($ mut) mbChange

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
      return $ maybe mut ($ mut) mbChange

    | pktFlags `areFlags` [RST] = do
      -- This can happen before FIN-ACK is received (if we are initiating
      -- the graceful shutdown)
      let
        reason = if rcbState == RcbClosed then AlreadyClosed else PeerClosed
        logAction = putStrLn $ "RST on " ++ show rcbState
      (mut', extraFinalizers) <- lift $ internalResetEverything rcb mut
      left (mut', (reason, logAction >> extraFinalizers))

runKeepAlive rcbRef = readMVar rcbRef >>= go
 where 
  go rcb = do
    threadDelay (1000000)
    ok <- atomically $ sendRcb rcb B.empty
    if ok
      then go rcb
      else return ()

internalResetEverything :: Rcb -> RcbMut -> STM (RcbMut, IO ())
internalResetEverything rcb@(Rcb {..}) mut@(RcbMut {..}) = do
  -- We send an RST as well
  sendMailbox rcbToNic mkRstPkt

  sealMailbox rcbFromApp
  sealMailbox rcbToApp
  sealMailbox rcbFromNic
  sealMailbox rcbToNic

  -- Stop the underlying raw peer
  let extraFinalizers = sequence_ rcbExtraFinalizers 

  -- And the runner threads will stop by themselves.
  return (mut { rcbState = RcbClosed }, extraFinalizers)

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

    unacked <- M.size . rcbResendQ <$> readTVar rcbMutRef
    if unacked >= optMaxUnackedPackets
      then retry
      else return ()

    mbBs <- recvMailbox rcbFromApp
    case mbBs of
      Nothing ->
        -- Sealed: FIN or closed. This thread is done.
        -- False to discontinue the loop
        return False
      Just (seqNo, payload) -> do
        modifyRcb_ rcb $ \ mut ->
          sendDataOrFinPkt rcb mut (mkDataPkt seqNo payload) now
        -- Loop
        return True

  barf :: SomeException -> IO ()
  barf e = do
    putStrLn $ "[runSend] STM.retry: " ++ show e

sendDataOrFinPkt :: Rcb -> RcbMut -> Packet -> UTCTime -> STM RcbMut
sendDataOrFinPkt (Rcb {..}) mut@(RcbMut {..}) packet@(Packet {..}) now = do
  sendMailbox rcbToNic packet
  let
    -- Add to OutputQ and schedule a resend
    (nextTime, nextBackOff) =
      calcBackOff now (optDefaultBackOff rcbConnOpt)
    newOutputQ = M.insert pktSeqNo packet rcbOutputQ
    newResendQ = M.insert (nextTime, pktSeqNo) (nextBackOff, 0) rcbResendQ
  return $ mut
    { rcbOutputQ = newOutputQ
    , rcbResendQ = newResendQ
    }

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
