{-# LANGUAGE RecordWildCards, DeriveDataTypeable, ScopedTypeVariables #-}

-- Pipes-based UDP-to-reliable-protocol adapter

module Protocol.RUDP where

import Control.Applicative
import Data.Bits
import Data.Typeable
import Data.Data
import Data.Function
import Data.Ord
import qualified Data.Map as M
import Data.Serialize
import qualified Data.ByteString as B
import Data.Foldable
import Data.Traversable
import qualified Data.Serialize as S
import Debug.Trace
import Prelude hiding (forM, forM_, mapM, mapM_, all, elem, foldr, concatMap)
import Pipes
import qualified Pipes.Concurrent as P
import Control.Concurrent hiding (yield)
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Monad hiding (mapM, mapM_)
import System.Random.MWC
-- ^ Not crypto though
import qualified Network.Socket.ByteString as SB
import Network.Socket
import qualified Data.IxSet as Ix

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
  deriving (Show, Typeable, Data)
  -- ^ Invariant: serialized form takes <= 512 bytes.
  -- That is, payload should be <= 480 bytes.

data PacketFlag
  = ACK
  | RST
  | SYN
  | FIN
  | ECHO
  deriving (Show, Eq, Ord, Enum, Bounded, Typeable, Data)

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

-- To use with IxSet.
-- XXX: overkill?
data InputEntry = InputEntry {
  ieDataSeq :: DataSeq,
  ieAckEchoSeq :: AckEchoSeq,
  ieDataPkt :: Packet,
  ieAckEchoPkt :: Packet
}
  deriving (Show, Typeable, Data)

instance Eq InputEntry where
  (==) = (==) `on` ieDataSeq

instance Ord InputEntry where
  compare = comparing ieDataSeq

inputEntry :: Packet -> Packet -> InputEntry
inputEntry dataPkt ackEchoPkt
  = InputEntry (DataSeq $ pktSeqNo dataPkt)
               (AckEchoSeq $ pktSeqNo ackEchoPkt)
               dataPkt
               ackEchoPkt

newtype DataSeq = DataSeq Int
  deriving (Show, Eq, Ord, Typeable, Data)

newtype AckEchoSeq = AckEchoSeq Int
  deriving (Show, Eq, Ord, Typeable, Data)

instance Ix.Indexable InputEntry where
  empty = Ix.ixSet
    [ Ix.ixGen (Ix.Proxy :: Ix.Proxy DataSeq)
    , Ix.ixGen (Ix.Proxy :: Ix.Proxy AckEchoSeq)
    ]

-- XXX: Shall we call some of them `control blocks` instead?
type InputQueue = Ix.IxSet InputEntry
type OutputQueue = M.Map Int Packet
type DeliveryQueue = M.Map Int Packet

establish
  :: Mailbox Packet
  -- ^ Incoming and outoming packets (unreliable)
  -> String
  -- ^ Name, for debug's purpose
  -> IO (Mailbox B.ByteString)
  -- ^ Connected endpoints. Assume that bytestrings are already split into
  -- smaller pieces.
establish pktMailbox@(pktIn, pktOut) nameTag = do
  inQ <- newTVarIO Ix.empty :: IO (TVar InputQueue)
  outQ <- newTVarIO M.empty :: IO (TVar OutputQueue)
  deliveryQ <- newTVarIO M.empty :: IO (TVar DeliveryQueue)

  lastDeliveredSeqNo <- newTVarIO 0
  lastInQAckNo <- newTVarIO 0
  -- ^ Used to check if a given DATA packet is already received.
  lastUsedSeqNo <- newTVarIO 0

  -- W means app -> NIC and R means NIC -> app
  (bsWOut, bsWIn) <- P.spawn P.Unbounded
  (bsROut, bsRIn) <- P.spawn P.Unbounded

  let
    genSeqNo = modifyTVar' lastUsedSeqNo (+1) *> readTVar lastUsedSeqNo
    deliver = deliverPacket nameTag lastDeliveredSeqNo deliveryQ bsROut

  readPktT <- async $ forever $ atomically $ do
    Just pkt <- P.recv pktIn
    onPacket nameTag pktOut pkt genSeqNo (void . deliver)
             inQ lastInQAckNo outQ

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
  -> TVar OutputQueue
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
  -> TVar InputQueue
  -> TVar OutputQueue
  -> STM (Maybe Int)
resendAll pktOut inQ outQ = do
  res1 <- mapM (P.send pktOut . ieAckEchoPkt) . Ix.toList =<< readTVar inQ
  res2 <- mapM (P.send pktOut) =<< readTVar outQ
  let
    allOk = all id res1 && all id res2
    nSent = length res1 + M.size res2
  if allOk
    then return $ Just nSent
    else return Nothing

withTVar :: TVar b -> (b -> STM (b, a)) -> STM a
withTVar tv mf = do
  v <- readTVar tv
  (v', a) <- mf v
  writeTVar tv v'
  return a

deliverPacket
  :: String
  -> TVar Int
  -> TVar DeliveryQueue
  -> P.Output B.ByteString
  -> Packet
  -> STM ()
  -- ^ Num of delivered packets
deliverPacket nameTag lastDeliverySeqNo deliveryQ bsOut pkt
  | trace2 (nameTag ++ " deliver " ++ show pkt) False = undefined
  | otherwise = do
      weReDone <- packetSeqIsBelow nameTag lastDeliverySeqNo pkt
      if weReDone
        then return ()
        else do
          trace2 (nameTag ++ " put to deliveryQ! " ++ show pkt) $ return ()
          modifyTVar' deliveryQ $ M.insert (pktSeqNo pkt) pkt
          pkts <- mergeAndPopEntriesBy lastDeliverySeqNo deliveryQ
                                       M.lookup M.delete
          mapM_ (P.send bsOut . pktPayload) pkts

packetSeqIsBelow
  :: String
  -> TVar Int
  -> Packet
  -> STM Bool
packetSeqIsBelow nameTag lastNo pkt@(Packet {..}) = do
  ok <- (pktSeqNo <=) <$> readTVar lastNo
  return $
    trace2 (nameTag ++ " isBelow " ++ show pkt ++ ": " ++ show ok) ok

mergeEntries
  :: Int
  -- ^ Last merged ix
  -> b
  -- ^ Store
  -> (Int -> b -> Maybe a)
  -- ^ Lookup
  -> (Maybe a -> STM Bool)
  -- ^ Mergeable
  -> STM Int
  -- ^ New merge ix
mergeEntries lastIx store lookupStore check = go lastIx
 where
  go i = do
    ok <- check $ lookupStore i store
    if ok
      then go $! i + 1
      else return i

mergeAndPopEntriesBy
  :: TVar Int
  -> TVar s
  -> (Int -> s -> Maybe a)
  -> (Int -> s -> s)
  -> STM [a]
mergeAndPopEntriesBy lastNoVar storeVar lookupStore deleteStore =
  withTVar lastNoVar $ \ lastNo -> do
    withTVar storeVar $ \ store -> do
      newNo <- mergeEntries lastNo store lookupStore $ const (return True)
      let ixs = [lastNo + 1..newNo]
          vals = map (fromJust . flip lookupStore store) ixs
      return $ (foldr deleteStore store ixs, (newNo, vals))
 where
  fromJust (Just x) = x
  fromJust _ = error "mergeEntriesBy.fromJust: got Nothing"

onPacket
  :: String
  -> P.Output Packet
  -> Packet
  -> STM Int
  -> (Packet -> STM ())
  -- ^ Deliver the packet idempotently
  -> TVar InputQueue
  -- ^ IxSet of (data-pkt, ACKECHO-pkt)
  -- When an ACK for an ACKECHO-pkt is received, the corresponding entry
  -- will be deleted.
  -> TVar Int
  -- ^ Seq of the last input packet that can be just ignored (our ACKECHO
  -- was already ACKed)
  -> TVar (M.Map Int Packet)
  -- ^ Map of DATA-seq => DATA-pkt
  -- Will be cleared when an ACKECHO for the data-pkt is received.
  -> STM ()
onPacket nameTag pktOut pkt@(Packet {..}) genSeqNo deliver
    inQ lastInQAckNo outQ

  | trace2 (nameTag ++ " onPacket " ++ show pkt) False = undefined
    -- ^ Just logging...

  | isData pktFlags = do
    -- ^ Got data: Try to deliver it now. Also sends an ACK-ECHO.
    deliver pkt
    -- ^ Just deliver it. The delivery action will check for it first.
    shallIgnore <- packetSeqIsBelow (nameTag ++ "/inQ") lastInQAckNo pkt
    -- ^ Ignore this and don't add it to the inQ?
    if shallIgnore
      then return ()
      else do
        mbInfo <- unsingleton . Ix.getEQ (DataSeq pktSeqNo) <$> readTVar inQ
        -- ^ Check if we already stored this DATA pkt
        ackEchoPkt <- case mbInfo of
          Nothing -> do
            -- Not stored and haven't send a ACK-ECHO yet.
            seqNo <- genSeqNo
            let replyPkt = Packet seqNo pktSeqNo [ACK, ECHO] B.empty
            modifyTVar' inQ $ Ix.insert $ inputEntry pkt replyPkt
            return replyPkt
          Just (InputEntry {..}) -> do
            return ieAckEchoPkt
        -- Anyway, send the ackEcho once (more).
        void $ P.send pktOut ackEchoPkt

  | isAckEcho pktFlags = do
    -- ^ ACK-ECHO: Remove the data packet in the outQ and send an ACK.
    deliver pkt
    modifyTVar' outQ $ M.delete pktAckNo
    P.send pktOut $ Packet (-1) pktSeqNo [ACK] B.empty
    return ()

  | isAck pktFlags = do
    -- ^ ACK: Remove the ACK-ECHO packet in the inQ and try to merge
    -- and remove ACKed packets.
    mbInfo <- unsingleton . Ix.getEQ (AckEchoSeq pktAckNo) <$> readTVar inQ
    case mbInfo of
      Nothing -> return ()
      Just (InputEntry {..}) -> do
        void $ mergeAndPopEntriesBy lastInQAckNo inQ (ixLookup . DataSeq)
                                    deleteByIx
 where
  listToMaybe [] = Nothing
  listToMaybe [x] = Just x
  listToMaybe _ = error "listToMaybe: too many items"

  unsingleton = listToMaybe . Ix.toList

  ixLookup k s = unsingleton (Ix.getEQ k s)

  deleteByIx i s = let Just a = listToMaybe $ Ix.toList $ Ix.getEQ i s
                    in Ix.delete a s

isData xs = xs == []
isAckEcho xs = isAck xs && ECHO `elem` xs
isAck = (ACK `elem`)

-- Serialization
putPacket :: Packet -> S.Put
putPacket (Packet {..}) = do
  S.put pktSeqNo
  S.put pktAckNo
  S.put $ foldFlags pktFlags
  S.put pktPayload

getPacket :: S.Get Packet
getPacket = Packet <$> S.get <*> S.get <*> (unfoldFlags <$> S.get) <*> S.get

foldFlags :: Enum a => [a] -> Int
foldFlags = foldr (flip setFlag) 0

unfoldFlags :: (Bounded a, Enum a) => Int -> [a]
unfoldFlags flag = concatMap check [minBound..maxBound]
 where
  check a = if hasFlag flag a then [a] else []

hasFlags :: Enum a => Int -> [a] -> Bool
hasFlags flag xs = foldr combine True xs
 where
  combine x out = hasFlag flag x && out

hasFlag :: Enum a => Int -> a -> Bool
hasFlag flag a = testBit flag (fromEnum a)

setFlag :: Enum a => Int -> a -> Int
setFlag flag a = setBit flag (fromEnum a)

delFlag :: Enum a => Int -> a -> Int
delFlag flag a = clearBit flag (fromEnum a)

toUdpSocket s addr = forever $ do
  bs <- await
  liftIO $ SB.sendTo s bs addr

fromUdpSocket s addr size = forever $ do
  (bs, who) <- liftIO $ SB.recvFrom s size
  if who /= addr
    then return ()
    else yield bs

mkPacketPipe
  :: SockAddr
  -> Int
  -> Socket
  -> IO (P.Input Packet, P.Output Packet)
mkPacketPipe addr bufSize s = do
  (pktWOut, pktWIn) <- P.spawn P.Unbounded
  (pktROut, pktRIn) <- P.spawn P.Unbounded

  let
    serialized = forever $ do
      x <- await
      let bs = S.runPut (putPacket x)
      --liftIO $ putStrLn $ "[Packet] siz = " ++ show (B.length bs)
      yield bs

    deserialized = forever $ do
      bs <- await
      let eiX = S.runGet getPacket bs
      case eiX of
        Left _ -> return ()
        Right x -> yield x

  async $ runEffect $
    P.fromInput pktRIn >-> serialized >-> toUdpSocket s addr
  async $ runEffect $
    fromUdpSocket s addr bufSize >-> deserialized >-> P.toOutput pktWOut

  return (pktWIn, pktROut)
