{-# LANGUAGE RecordWildCards, DeriveDataTypeable, ScopedTypeVariables #-}

-- Pipes-based UDP-to-reliable-protocol adapter

module Protocol.RUDP where

import Control.Applicative
import Data.Bits
import Data.Typeable
import qualified Data.Map as M
import Data.Serialize
import qualified Data.ByteString as B
import Data.Foldable
import Data.Traversable
import Debug.Trace
import Prelude hiding (forM, forM_, mapM, mapM_, all, elem)
import Pipes
import qualified Pipes.Concurrent as P
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Monad hiding (mapM)
import System.Random.MWC
-- ^ Not crypto though

trace2 _ = id
--trace2 = trace

-- This should of course be more low-level (like a c-struct).
data Packet
  = Packet {
    pktSeqNo :: !Int,
    pktAckNo :: !Int,
    pktFlags :: ![PacketFlag],
    pktPayload :: !B.ByteString
  }
  deriving (Show, Eq)
  -- ^ Invariant: serialized form takes <= 512 bytes.
  -- That is, payload should be <= 480 bytes.

data PacketFlag
  = ACK
  | RST
  | SYN
  | FIN
  | ECHO
  deriving (Show, Eq, Ord, Enum, Bounded)

data ConnOption
  = ConnOption {
    optIsInitiator :: Bool,
    -- ^ True for client, False for server
    optTimeoutMicros :: Int,
    optMaxRetires :: Int,
    optRandGen :: GenIO
  }

data ConnectionError
  = PeerClosed
  | TooManyRetries
  deriving (Show, Eq, Ord, Typeable)

type Mailbox a = (P.Input a, P.Output a)

establish
  :: Mailbox Packet
  -- ^ Incoming and outoming packets (unreliable)
  -> String
  -- ^ Name, for debug's purpose
  -> IO (Mailbox B.ByteString)
  -- ^ Connected endpoints. Assume that bytestrings are already split into
  -- smaller pieces.
establish pktMailbox@(pktIn, pktOut) nameTag = do
  inQ <- newTVarIO M.empty
  -- ^ ACKECHO-seq => (data-pkt, ACKECHO-pkt)
  -- Will be cleared when an ACK for the ACKECHO-pkt is received.

  outQ <- newTVarIO M.empty
  -- ^ data-seq => data-pkt
  -- Will be cleared when an ACKECHO for the data-pkt is received
  deliveryQ <- newTVarIO M.empty
  lastDeliveredSeqNo <- newTVarIO 0
  lastUsedSeqNo <- newTVarIO 0

  -- W means app -> NIC and R means NIC -> app
  (bsWOut, bsWIn) <- P.spawn P.Unbounded
  (bsROut, bsRIn) <- P.spawn P.Unbounded

  let
    genSeqNo = modifyTVar' lastUsedSeqNo (+1) *> readTVar lastUsedSeqNo
    checkDelivery = packetIsDelivered nameTag lastDeliveredSeqNo
    deliver = deliverPacket nameTag lastDeliveredSeqNo deliveryQ bsROut

  readPktT <- async $ forever $ atomically $ do
    Just pkt <- P.recv pktIn
    onPacket nameTag pktOut pkt genSeqNo checkDelivery (void . deliver)
      inQ outQ

  resendPktT <- async $ forever $ do
    threadDelay 100000
    Just nSent <- atomically $ resendAll pktOut inQ outQ
    if nSent /= 0
      then trace2 (nameTag ++ " resendPkt: " ++ show nSent) return ()
      else return ()

  writePktT <- async $ forever $ atomically $ do
    Just bs <- P.recv bsWIn
    sendData nameTag pktOut genSeqNo bs outQ

  return (bsRIn, bsWOut)

sendData
  :: String
  -- ^ debug name
  -> P.Output Packet
  -- ^ Endpoint
  -> STM Int
  -- ^ Seq No generator
  -> B.ByteString
  -- ^ Payload (already cut into correct size)
  -> TVar (M.Map Int Packet)
  -- ^ Output queue
  -> STM Bool
  -- ^ False if Endpoint closed
sendData nameTag pktOut genSeqNo payload outQ
  | trace2 (nameTag ++ " sendData " ++ show payload) False = undefined
  | otherwise = do
    seqNo <- genSeqNo
    let pkt = Packet seqNo (-1) [] payload
    modifyTVar' outQ $ M.insert seqNo pkt
    P.send pktOut pkt

resendAll
  :: P.Output Packet
  -> TVar (M.Map Int (Packet, Packet))
  -- ^ inQ: Map seqNo (dataPkt, replyPkt)
  -> TVar (M.Map Int Packet)
  -> STM (Maybe Int)
resendAll pktOut inQ outQ = do
  res1 <- mapM (P.send pktOut . snd) =<< readTVar inQ
  res2 <- mapM (P.send pktOut) =<< readTVar outQ
  let
    allOk = all id res1 && all id res2
    nSent = M.size res1 + M.size res2
  if allOk
    then return $ Just nSent
    else return Nothing

deliverPacket
  :: String
  -> TVar Int
  -> TVar (M.Map Int Packet)
  -> P.Output B.ByteString
  -> Packet
  -> STM Bool
  -- ^ Whether all the deliveries are successful.
deliverPacket nameTag lastDeliverySeqNo deliveryQ bsOut
    pkt@(Packet {..})
  | trace2 (nameTag ++ " deliver " ++ show pkt) False = undefined
  | otherwise = do
    weReDone <- packetIsDelivered nameTag lastDeliverySeqNo pkt
    if weReDone
      then return True
      else do
        trace2 (nameTag ++ " put to deliveryQ! " ++ show pkt) $ return ()
        modifyTVar' deliveryQ $ M.insert pktSeqNo pkt
        go
 where
  go = do
    lastNo <- readTVar lastDeliverySeqNo
    mbPkt <- M.lookup (1 + lastNo) <$> readTVar deliveryQ
    case mbPkt of
      Nothing -> return True
      Just pkt@(Packet {..}) -> do
        modifyTVar' lastDeliverySeqNo (+1)
        sendRes <- if isAckEcho pktFlags
          then do
            -- Do nothing
            return True
          else if isData pktFlags
            then P.send bsOut pktPayload
            else error "deliveryPacket: Not reached"
        modifyTVar' deliveryQ $ M.delete lastNo
        if sendRes
          then go
          else return sendRes

packetIsDelivered
  :: String
  -> TVar Int
  -> Packet
  -> STM Bool
packetIsDelivered nameTag lastDeliverySeqNo pkt@(Packet {..}) = do
  ok <- (pktSeqNo <=) <$> readTVar lastDeliverySeqNo
  return $
    trace2 (nameTag ++ " isDelivered " ++ show pkt ++ ": " ++ show ok) ok

onPacket
  :: String
  -> P.Output Packet
  -> Packet
  -> STM Int
  -> (Packet -> STM Bool)
  -> (Packet -> STM ())
  -> TVar (M.Map Int (Packet, Packet))
  -> TVar (M.Map Int Packet)
  -> STM ()
onPacket nameTag pktOut pkt@(Packet {..}) genSeqNo checkDelivery deliver
    inQ outQ
  | trace2 (nameTag ++ " onPacket " ++ show pkt) False = undefined
  | isData pktFlags = do
    -- ^ Got data
    isDelivered <- checkDelivery pkt
    if isDelivered
      then
        -- ACK has been received and data has been already delivered to
        -- the application. We can just drop this packet.
        return ()
      else do
        mbInfo <- M.lookup pktSeqNo <$> readTVar inQ
        case mbInfo of
          Nothing -> do
            -- Haven't send a ACK-ECHO yet.
            seqNo <- genSeqNo
            let replyPkt = Packet seqNo pktSeqNo [ACK, ECHO] B.empty
            modifyTVar' inQ $ M.insert seqNo (pkt, replyPkt)
            P.send pktOut replyPkt
            -- ^ Send the reply NOW
          Just (_, replyPkt) -> do
            P.send pktOut replyPkt
            -- ^ Send the reply NOW
        return ()

  | isAckEcho pktFlags = do
    -- ^ ACK-ECHO: Remove the data packet in the outQ and send an ACK.
    deliver pkt
    modifyTVar' outQ $ M.delete pktAckNo
    P.send pktOut $ Packet (-1) pktSeqNo [ACK] B.empty
    return ()

  | isAck pktFlags = do
    -- ^ ACK: Remove the ACK-ECHO packet in the inQ and put the data packet
    -- into the delivery queue. Or, if there's no matching record in the
    -- inQ, do nothing.
    mbInfo <- M.lookup pktAckNo <$> readTVar inQ
    case mbInfo of
      Nothing -> return ()
      Just (dataPkt, _) -> do
        modifyTVar' inQ $ M.delete pktAckNo
        deliver dataPkt

isData xs = xs == []
isAckEcho xs = isAck xs && ECHO `elem` xs
isAck = (ACK `elem`)

