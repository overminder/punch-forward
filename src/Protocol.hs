{-# LANGUAGE RecordWildCards, DeriveDataTypeable, ScopedTypeVariables #-}

-- Pipes-based UDP-to-reliable-protocol adapter

module Protocol where

import Control.Applicative
import Data.Bits
import Data.Typeable
import qualified Data.Map as M
import Data.Serialize
import qualified Data.ByteString as B
import Data.Foldable
import Data.Traversable
import Prelude hiding (forM, forM_, mapM, mapM_, all, elem)
import Pipes
import qualified Pipes.Concurrent as P
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Monad hiding (mapM)
import System.Random.MWC
-- ^ Not crypto though

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
  deriving (Show, Eq, Ord, Enum)

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
  -> IO (Mailbox B.ByteString)
  -- ^ Connected endpoints. Assume that bytestrings are already split into
  -- smaller pieces.
establish pktMailbox@(pktIn, pktOut) = do
  inQ <- newTVarIO M.empty
  outQ <- newTVarIO M.empty
  deliveryQ <- newTVarIO M.empty
  lastDeliveredSeqNo <- newTVarIO 0
  lastUsedSeqNo <- newTVarIO 0

  (bsOut, bsIn) <- P.spawn P.Unbounded

  let
    genSeqNo = modifyTVar' lastUsedSeqNo (+1) *> readTVar lastUsedSeqNo
    checkDelivery = packetIsDelivered lastDeliveredSeqNo
    deliver = deliverPacket lastDeliveredSeqNo deliveryQ bsOut

  readPktT <- async $ forever $ atomically $ do
    Just pkt <- P.recv pktIn
    onPacket pktOut pkt genSeqNo checkDelivery (void . deliver) inQ outQ

  resendPktT <- async $ forever $ atomically $
    resendAll pktOut inQ outQ

  writePktT <- async $ forever $ atomically $ do
    Just bs <- P.recv bsIn
    sendData pktOut genSeqNo bs outQ

  return (bsIn, bsOut)

sendData
  :: P.Output Packet
  -- ^ Endpoint
  -> STM Int
  -- ^ Seq No generator
  -> B.ByteString
  -- ^ Payload (already cut into correct size)
  -> TVar (M.Map Int Packet)
  -- ^ Output queue
  -> STM Bool
  -- ^ False if Endpoint closed
sendData pktOut genSeqNo payload outQ = do
  seqNo <- genSeqNo
  let pkt = Packet seqNo (-1) [] payload
  modifyTVar' outQ $ M.insert seqNo pkt
  P.send pktOut pkt

resendAll
  :: P.Output Packet
  -> TVar (M.Map Int (Packet, Packet))
  -- ^ inQ: Map seqNo (dataPkt, replyPkt)
  -> TVar (M.Map Int Packet)
  -> STM Bool
resendAll pktOut inQ outQ = do
  ok1 <- allM . mapM (P.send pktOut . snd) =<< readTVar inQ
  ok2 <- allM . mapM (P.send pktOut) =<< readTVar outQ
  return $ ok1 && ok2
 where
  allM = (all id <$>)

deliverPacket
  :: TVar Int
  -> TVar (M.Map Int Packet)
  -> P.Output B.ByteString
  -> Packet
  -> STM Bool
  -- ^ Whether all the deliveries are successful.
deliverPacket lastDeliverySeqNo deliveryQ bsOut pkt@(Packet {..}) = do
  weReDone <- packetIsDelivered lastDeliverySeqNo pkt
  if weReDone
    then return True
    else do
      modifyTVar' deliveryQ $ M.insert pktSeqNo pkt
      go
 where
  go = do
    lastNo <- readTVar lastDeliverySeqNo
    mbPkt <- M.lookup lastNo <$> readTVar deliveryQ
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
  :: TVar Int
  -> Packet
  -> STM Bool
packetIsDelivered lastDeliverySeqNo (Packet {..}) =
  (pktSeqNo <=) <$> readTVar lastDeliverySeqNo

onPacket
  :: P.Output Packet
  -> Packet
  -> STM Int
  -> (Packet -> STM Bool)
  -> (Packet -> STM ())
  -> TVar (M.Map Int (Packet, Packet))
  -> TVar (M.Map Int Packet)
  -> STM ()
onPacket pktOut pkt@(Packet {..}) genSeqNo checkDelivery deliver inQ outQ
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
            modifyTVar' inQ $ M.insert pktSeqNo (pkt, replyPkt)
          Just (_, replyPkt) -> do
            -- Do nothing and wait for the resender to resend ACK-ECHO
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

