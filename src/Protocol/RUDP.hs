{-# LANGUAGE RecordWildCards, DeriveDataTypeable, ScopedTypeVariables #-}

-- Pipes-based UDP-to-reliable-protocol adapter

module Protocol.RUDP where

import Control.Applicative
import Data.Bits
import Data.Typeable
import Data.Data
import qualified Data.List as L
import Data.Function
import Control.Exception
import Data.Ord
import qualified Data.Map as M
import Data.Serialize
import qualified Data.ByteString as B
import Data.Foldable
import Data.Traversable
import qualified Data.Serialize as S
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
import Text.Printf

import Util

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
  ieAckEchoPkt :: Packet,
  ieAcked :: Bool
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
               False

-- XXX: ugly hack. This makes a inputEntry from an ACKECHO from remote
-- with acked=True.
inputEntryDummy :: Packet -> InputEntry
inputEntryDummy remoteAckEchoPkt
  = InputEntry (DataSeq $ pktSeqNo remoteAckEchoPkt)
               (AckEchoSeq (-1))
               remoteAckEchoPkt
               remoteAckEchoPkt
               True

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

showPacket :: Packet -> String
showPacket pkt@(Packet {..}) =
  printf "seq = %d, ack_seq = %d, flags = [%s], data_len = %d"
         pktSeqNo pktAckNo flags (B.length pktPayload)
 where
  flags = if flags' == "" then "D" else flags'
  flags' = (map (head . show) . L.delete ACK $ pktFlags) ++ ackDot
  ackDot = if elem ACK pktFlags then "." else ""

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
    sendPacket "[send] " pktOut pkt

sendPacket who dest pkt = do
  P.send dest pkt

resendAll
  :: P.Output Packet
  -> TVar InputQueue
  -> TVar OutputQueue
  -> STM (Maybe Int)
resendAll pktOut inQ outQ = do
  res1 <- mapM sendInQ . Ix.toList =<< readTVar inQ
  res2 <- mapM (sendPacket "[resend/outQ] " pktOut) =<< readTVar outQ
  let
    allOk = all id res1 && all id res2
    nSent = length res1 + M.size res2
  if allOk
    then return $ Just nSent
    else return Nothing
 where
  sendInQ entry
    | ieAcked entry = return True
      -- ^ Ignore acked entries
    | otherwise = sendPacket "[resend/inQ] " pktOut (ieAckEchoPkt entry)

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
      weReDone <- packetSeqIsBelow (nameTag ++ "/deliveryQ")
                                   lastDeliverySeqNo pkt
      if weReDone
        then return ()
        else do
          trace2 (nameTag ++ " put to deliveryQ! " ++ show pkt) $ return ()
          modifyTVar' deliveryQ $ M.insert (pktSeqNo pkt) pkt
          pkts <- mergeAndPopEntriesBy lastDeliverySeqNo deliveryQ
                                       M.lookup (return . maybeToBool)
                                       M.delete
          mapM_ sendDataOnly pkts

          currSeqNo <- readTVar lastDeliverySeqNo
          currQ <- readTVar deliveryQ
          trace2 (nameTag ++ " current deliveryQ: " ++ show currQ ++
                  ", currSeqNo: " ++ show currSeqNo) $ return ()
 where
  sendDataOnly pkt@(Packet {..})
    | isData pktFlags = do
      trace2 (nameTag ++ " actually delivering " ++ show pkt) $ return ()
      P.send bsOut pktPayload
    | otherwise = return True

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
    ok <- check $ lookupStore (i + 1) store
    if ok
      then go $! i + 1
      else return i

mergeAndPopEntriesBy
  :: TVar Int
  -> TVar s
  -> (Int -> s -> Maybe a)
  -> (Maybe a -> STM Bool)
  -> (Int -> s -> s)
  -> STM [a]
mergeAndPopEntriesBy lastNoVar storeVar lookupStore check deleteStore =
  withTVar lastNoVar $ \ lastNo -> do
    withTVar storeVar $ \ store -> do
      newNo <- mergeEntries lastNo store lookupStore check
      let ixs = [lastNo + 1..newNo]
          vals = map (fromJust . flip lookupStore store) ixs
      return $ (foldr deleteStore store ixs, (newNo, vals))
 where
  fromJust (Just x) = x
  fromJust _ = error "mergeEntriesBy.fromJust: got Nothing"

maybeToBool = maybe False (const True)

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
        mbAckEchoPkt <- case mbInfo of
          Nothing -> do
            -- Not stored and haven't send a ACK-ECHO yet.
            seqNo <- genSeqNo
            let replyPkt = Packet seqNo pktSeqNo [ACK, ECHO] B.empty
            modifyTVar' inQ $ Ix.insert $ inputEntry pkt replyPkt
            return $ Just replyPkt
          Just (InputEntry {..}) -> if ieAcked
            -- if acked: send nothing since remote already know this is
            -- received.
            then return Nothing
            else return $ Just ieAckEchoPkt
        -- Anyway, send the ackEcho once (more).
        trace2 (nameTag ++ " sendAckEcho " ++ show mbAckEchoPkt) $ return ()
        void $ maybe (return True) (sendPacket "[send/onDATA] " pktOut)
                     mbAckEchoPkt

  | isAckEcho pktFlags = do
    -- ^ ACK-ECHO: Remove the data packet in the outQ and send an ACK.
    deliver pkt
    modifyTVar' outQ $ M.delete pktAckNo
    sendPacket "[send/ACK] " pktOut $ Packet (-1) pktSeqNo [ACK] B.empty
    shallIgnore <- packetSeqIsBelow (nameTag ++ "/inQ") lastInQAckNo pkt
    if shallIgnore
      then return ()
      else do
        traceInQ "before insert"
        insertDummyToInQ
        traceInQ "after insert, before merge"
        mergeInQ
        traceInQ "after merge"

  | isAck pktFlags = do
    -- ^ ACK: Remove the ACK-ECHO packet in the inQ and try to merge
    -- and remove ACKed packets.
    mbInfo <- unsingleton . Ix.getEQ (AckEchoSeq pktAckNo) <$> readTVar inQ
    case mbInfo of
      Nothing -> return ()
      Just entry -> do
        modifyTVar' inQ ( Ix.insert (entry { ieAcked = True })
                        . Ix.delete entry
                        )
        mergeInQ

 where
  listToMaybe [] = Nothing
  listToMaybe [x] = Just x
  listToMaybe _ = error "listToMaybe: too many items"

  traceInQ x = do
    q <- readTVar inQ
    traceM $ nameTag ++ " inQ " ++ x ++ ": " ++ show q

  unsingleton :: (Typeable s, Data s, Ix.Indexable s, Ord s)
              => Ix.IxSet s -> Maybe s
  unsingleton = listToMaybe . Ix.toList

  ixLookup :: (Typeable k, Typeable s, Data s, Data k, Ord s, Ix.Indexable s)
           => k -> Ix.IxSet s -> Maybe s
  ixLookup k s = unsingleton (Ix.getEQ k s)

  checkAck Nothing = False
  checkAck (Just (InputEntry {..})) = ieAcked

  deleteByIx i s = let Just a = listToMaybe $ Ix.toList $
                                  Ix.getEQ (DataSeq i) s
                    in Ix.delete a s

  -- When pkt is an ACKECHO
  insertDummyToInQ = do
    let dummy = inputEntryDummy pkt
    modifyTVar' inQ $ Ix.insert dummy
    traceM $ nameTag ++ " insertDummy " ++ show dummy
    return ()

  mergeInQ = do
    merged <- mergeAndPopEntriesBy lastInQAckNo inQ (ixLookup . DataSeq)
                                   (return . checkAck) deleteByIx
    afterMerge <- readTVar inQ
    trace2 (nameTag ++ " merged " ++ show (length merged) ++ ": " ++
            show merged ++ ", after: " ++ show afterMerge) $ return ()

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
