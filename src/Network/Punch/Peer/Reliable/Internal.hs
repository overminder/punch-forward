-- Pipes-based UDP-to-reliable-protocol adapter

module Network.Punch.Peer.Reliable.Internal where

import Control.Applicative
import Data.Bits
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
import Prelude hiding (forM, forM_, mapM, mapM_, all, elem, foldr, concatMap,
                       notElem)
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
import Text.Printf
import Control.DeepSeq
-- ^ For IxSet's leak
import Data.Time

import Network.Punch.Peer.Types
import Network.Punch.Util
import qualified Network.Punch.Util.TIMap as TM

inputEntry :: Packet -> Packet -> ((DataSeq, AckEchoSeq), InputEntry)
inputEntry dataPkt ackEchoPkt
  = ( ( DataSeq $ pktSeqNo dataPkt
      , AckEchoSeq $ pktSeqNo ackEchoPkt
      )
    , InputEntry dataPkt
                 ackEchoPkt
                 False
    )

-- XXX: ugly hack. This makes a inputEntry from an ACKECHO from remote
-- with acked=True.
inputEntryDummy :: Packet -> ((DataSeq, AckEchoSeq), InputEntry)
inputEntryDummy remoteAckEchoPkt
  = ( ( DataSeq $ pktSeqNo remoteAckEchoPkt
      , AckEchoSeq (-1)
      )
    , InputEntry remoteAckEchoPkt
                 remoteAckEchoPkt
                 True
    )

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
  inQ <- newTVarIO TM.empty :: IO (TVar InputQueue)
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
    genSeqNo = modifyTVarDeep lastUsedSeqNo (+1) *> readTVar lastUsedSeqNo
    deliver = deliverPacket nameTag lastDeliveredSeqNo deliveryQ bsROut

  readPktT <- async $ catchAndLog "resendPktT" $ forever $ atomically $ do
    catchSTMAndLog "readPktT" $ do
      Just pkt <- P.recv pktIn
      onPacket nameTag pktOut pkt genSeqNo (void . deliver)
               inQ lastInQAckNo outQ

  resendPktT <- async $ catchAndLog "resendPktT" $ forever $ do
    threadDelay 100000
    -- Resend every 100 millis
    mbNSent <- atomically $ do
      catchSTMAndLog "resendPktT" $ resendAll pktOut inQ outQ
    if mbNSent /= Nothing && mbNSent /= Just 0
      then trace2 (nameTag ++ " resendPkt: " ++ show mbNSent) return ()
      else return ()

  writePktT <- async $ catchAndLog "writePktT" $ forever $ atomically $ do
    catchSTMAndLog "writePktT (err means no more BS from app)" $ do
      Just bs <- P.recv bsWIn
      sendData nameTag pktOut genSeqNo bs outQ

  return (bsRIn, bsWOut)

catchAndLog wat m =
  m `catch` \ (e :: SomeException) -> do
    putStrLn ("catchAndLog: " ++ wat ++ " " ++ show e)
    return ()

catchSTMAndLog wat m =
  m `catchSTM` \ (e :: SomeException) -> do
    infoM ("catchSTMAndLog: " ++ wat ++ " " ++ show e)
    error "Nothing to return for catchSTMAndLog..."

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
    modifyTVarDeep outQ $ M.insert seqNo pkt
    P.send pktOut pkt

resendAll
  :: P.Output Packet
  -> TVar InputQueue
  -> TVar OutputQueue
  -> STM (Maybe Int)
resendAll pktOut inQ outQ = do
  mapM_ sendInQ . TM.elems =<< readTVar inQ
  mapM_ (P.send pktOut) =<< readTVar outQ
  return Nothing
  --let
  --  allOk = all id res1 && all id res2
  --  nSent = length res1 + M.size res2
  --if allOk
  --  then return $ Just nSent
  --  else return Nothing
 where
  sendInQ entry
    | ieAcked entry = return True
      -- ^ Ignore acked entries
    | otherwise = P.send pktOut (ieAckEchoPkt entry)

withTVar :: NFData b => TVar b -> (b -> STM (b, a)) -> STM a
withTVar tv mf = do
  v <- readTVar tv
  (v', a) <- mf v
  writeTVar tv $! deepseq2 v' v'
  return a

-- modifyTVar' usually gives better performance.
modifyTVarDeep :: NFData a => TVar a -> (a -> a) -> STM ()
modifyTVarDeep va f = modifyTVar' va f'
 where
  f' a = let a' = f a
          in deepseq2 a' a'

deepseq2 a b = b
-- ^ Over-strictness usually gives degraded performance.

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
          modifyTVarDeep deliveryQ $ M.insert (pktSeqNo pkt) pkt
          pkts <- mergeAndPopEntriesBy lastDeliverySeqNo deliveryQ
                                       M.lookup (return . maybeToBool)
                                       M.delete
          mapM_ sendDataOnly pkts

          currSeqNo <- readTVar lastDeliverySeqNo
          currQ <- readTVar deliveryQ
          traceM $ nameTag ++ " deliveryQ.size: " ++ show (M.size currQ) ++
                  ", currSeqNo: " ++ show currSeqNo
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
  :: NFData s
  => TVar Int
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
  -- ^ TIMap of (data-pkt, ACKECHO-pkt)
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
        mbInfo <- unsingleton . TM.lookup1 (DataSeq pktSeqNo)
              <$> readTVar inQ
        -- ^ Check if we already stored this DATA pkt
        mbAckEchoPkt <- case mbInfo of
          Nothing -> do
            -- Not stored and haven't send a ACK-ECHO yet.
            seqNo <- genSeqNo
            let replyPkt = Packet seqNo pktSeqNo [ACK, ECHO] B.empty
            modifyTVarDeep inQ $ uncurry TM.insert $ inputEntry pkt replyPkt
            return $ Just replyPkt
          Just (k2, InputEntry {..}) -> if ieAcked
            -- if acked: send nothing since remote already know this is
            -- received.
            then return Nothing
            else return $ Just ieAckEchoPkt
        -- Anyway, send the ackEcho once (more).
        trace2 (nameTag ++ " sendAckEcho " ++ show mbAckEchoPkt) $ return ()
        void $ maybe (return True) (P.send pktOut)
                     mbAckEchoPkt

  | isAckEcho pktFlags = do
    -- ^ ACK-ECHO: Remove the data packet in the outQ and send an ACK.
    deliver pkt
    modifyTVarDeep outQ $ M.delete pktAckNo
    P.send pktOut $! Packet (-1) pktSeqNo [ACK] B.empty
    shallIgnore <- packetSeqIsBelow (nameTag ++ "/inQ") lastInQAckNo pkt
    if shallIgnore
      then return ()
      else do
        insertDummyToInQ
        mergeInQ

  | isAck pktFlags = do
    -- ^ ACK: Remove the ACK-ECHO packet in the inQ and try to merge
    -- and remove ACKed packets.
    let k2 = AckEchoSeq pktAckNo
    mbInfo <- unsingleton . TM.lookup2 k2 <$> readTVar inQ
    case mbInfo of
      Nothing -> return ()
      Just (k1, entry) -> do
        modifyTVarDeep inQ $ TM.insert (k1, k2) (entry { ieAcked = True })
        mergeInQ

 where
  listToMaybe [] = Nothing
  listToMaybe [x] = Just x
  listToMaybe _ = error "listToMaybe: too many items"

  traceInQ x = do
    q <- readTVar inQ
    traceM $ nameTag ++ " inQ " ++ x ++ ": " ++ show q

  unsingleton = listToMaybe . M.toList

  checkAck Nothing = False
  checkAck (Just (InputEntry {..})) = ieAcked

  -- When pkt is an ACKECHO
  insertDummyToInQ = do
    let (ks, dummy) = inputEntryDummy pkt
    modifyTVarDeep inQ $ TM.insert ks dummy
    traceM $ nameTag ++ " insertDummy " ++ show dummy
    return ()

  lookupDataSeq i m =
    let mbGot = unsingleton . TM.lookup1 (DataSeq i) $ m
     in snd <$> mbGot

  deleteByDataSeq i m =
    let k1 = DataSeq i
        Just (k2, _) = unsingleton $ TM.lookup1 k1 m
     in TM.delete (k1, k2) m

  mergeInQ = do
    merged <- mergeAndPopEntriesBy lastInQAckNo inQ (lookupDataSeq)
                                   (return . checkAck) deleteByDataSeq
    afterMerge <- readTVar inQ
    traceM (nameTag ++ " merged " ++ show (length merged) ++ ": " ++
            show merged)
    traceM (nameTag ++ " inQ.size: " ++ show (TM.size afterMerge))

isData xs = xs == []
isAckEcho xs = ACK `elem` xs && ECHO `elem` xs
isAck xs = ACK `elem` xs && ECHO `notElem` xs

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

mkGenericRateLogger
  :: Int
  -- ^ sleep duration
  -> a
  -- ^ default value for data-to-log
  -> (p -> a -> a)
  -- ^ packet -> old data-to-log -> new data-to-log
  -> (a -> Int -> IO ())
  -- ^ data-to-log -> elapsed -> LogAction
  -> Pipe p p IO ()
mkGenericRateLogger intervalMs a iterF logger = do
  aRef <- liftIO $ do
    aRef <- newTVarIO a
    async $ forever $ do
      t0 <- getCurrentTime
      threadDelay intervalMs
      t1 <- getCurrentTime
      currA <- atomically $ swapTVar aRef a
      let elapsed = (t1 `diffUTCTime` t0) * 1e6
      logger currA (floor elapsed)
    return aRef
  forever $ do
    p <- await
    liftIO $ atomically $ modifyTVar' aRef (iterF p)
    yield p

mkByteRateLogger
  :: Int
  -> (Int -> Int -> IO ())
  -- ^ nbytes -> elapsed -> LogAction
  -> Pipe B.ByteString B.ByteString IO ()
mkByteRateLogger intervalMs logger
  = mkGenericRateLogger intervalMs 0 iterF logger
 where
  iterF bs count = count + B.length bs

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

    -- Some ad-hoc packet status loggers

    logByteRate :: String -> Int -> Int -> IO ()
    logByteRate tag count elapsed = do
      printf "%s: %d KB/s (%d bytes in %d microseconds)\n"
             tag
             ((floor (fromIntegral (floor 1e3 * count) / fromIntegral elapsed))
              :: Int)
             count elapsed

    logSendBR = mkByteRateLogger (floor 5e6) (logByteRate "send")
    logRecvBR = mkByteRateLogger (floor 5e6) (logByteRate "recv")

    iterPktRate pkt@(Packet {..})
                (npkt, ntotalbytes, nplbytes, nacks, ndatas, naes)
      = (npkt + 1, ntotalbytes + B.length pktBs,
         nplbytes + B.length pktPayload,
         nacks + ackincr,
         ndatas + dataincr,
         naes + aeincr)
     where
      pktBs = S.runPut (putPacket pkt)
      ackincr | isAck pktFlags = 1
              | otherwise = 0
      dataincr | isData pktFlags = 1
               | otherwise = 0
      aeincr | isAckEcho pktFlags = 1
             | otherwise = 0

    displayPktRateInfo
      :: String -> (Int, Int, Int, Int, Int, Int) -> Int -> IO ()
    displayPktRateInfo tag (npkt, ntotalbytes, nplbytes, nacks, ndatas, naes)
                       elapsed = do
      printf ("%s: %.2f packets/s, total %.2f KB/s, payload %.2f KB/s\n" ++
              "payload efficiency: %.2f%%, ACKs: %.2f%%, DATAs: %.2f%%" ++
              ", ACK/E: %.2f%%\n")
             tag
             (npkt `floatDiv` elapsed * 1e6)
             (ntotalbytes `floatDiv` elapsed * 1e3)
             (nplbytes `floatDiv` elapsed * 1e3)
             (nplbytes `floatDiv` ntotalbytes * 100)
             (nacks `floatDiv` npkt * 100)
             (ndatas `floatDiv` npkt * 100)
             (naes `floatDiv` npkt * 100)
     where
      floatDiv a b = (fromIntegral a / fromIntegral b) :: Double

    emptyPktInfo = (0,0,0,0,0,0)
    logSendPkt = mkGenericRateLogger (floor 1e7) emptyPktInfo iterPktRate
                                     (displayPktRateInfo "send")
    logRecvPkt = mkGenericRateLogger (floor 1e7) emptyPktInfo iterPktRate
                                     (displayPktRateInfo "recv")

  async $ runEffect $
    P.fromInput pktRIn >-> logSendPkt >-> serialized >-> toUdpSocket s addr
  async $ runEffect $
    fromUdpSocket s addr bufSize >-> deserialized >-> logRecvPkt >-> P.toOutput pktWOut

  return (pktWIn, pktROut)
