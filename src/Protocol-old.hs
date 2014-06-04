-- Those things need to be put into the serializer
buildFlags :: Enum a => [a] -> Int
buildFlags = foldr setFlag 0

hasFlags :: Enum a => [a] -> Int -> Bool
hasFlags xs flag = foldr combine True xs
 where
  combine x out = hasFlag x flag && out

hasFlag :: Enum a => a -> Int -> Bool
hasFlag = testBit . fromEnum

setFlag :: Enum a => a -> Int -> Int
setFlag = setBit . fromEnum

delFlag :: Enum a => a -> Int -> Int
delFlag = clearBit . fromEnum

type Mailbox a = (P.Input a, P.Output a)

-- Used temporarily.
rightOrThrow :: Typeable e => Either e a -> IO a
rightOrThrow = either throwIO return

justOrThrow :: Typeable e => e -> Maybe a -> IO a
justOrThrow e = maybe (throwIO e) return

nothingOrThrow :: Typeable e => Maybe e -> IO ()
nothingOrThrow = maybe (return ()) throwIO

establish
  :: ConnOption
  -- ^ Options?
  -> Mailbox Packet
  -- ^ Incoming and outoming packets (unreliable)
  -> IO (Mailbox B.ByteString)
  -- ^ Connected endpoints. Assume that bytestrings are already split into
  -- smaller pieces.
establish (ConnOption {..}) (pktIn, pktOut)@pktMailbox

  | optIsInitiator = do
    -- SYN
    initSeqNo <- uniform optRandGen :: IO Int
    let synPkt = mkSynPacket initSeqNo
        checkSynAck = isSynAckFor initSeqNo
    synAckPkt <- join $ rightOrThrow <$> sendRecvWithRetry pktMailbox synPkt
      optTimeoutMicros optRetryLimit checkSynAck
    -- ^ Client sends SYN and waits for server's SYN-ACK response.
    let ackPkt = mkAckPacket (initSeqNo + 1) (pkgAckNo synAckPkt)
        isNotSynAck pkt = pkt /= synAckPkt

    join $ nothingOrThrow <$> atomically $ sendUntil pktMailbox ackPkt
      retryLimit isNotThatSynAck
    -- ^ Client sends ACK.
    
    (bsIn, bsOut, bsClose)@bsMailbox <- P.spawn' P.Single
    runDataLoop bsMailbox (initSeqNo + 2)
    return bsMailbox

  | otherwise = do
    synPkt <- join $ justOrThrow PeerClosed <$> atomically $ P.recv pktIn
    -- ^ Server waits for client's first SYN.
    initSeqNo <- uniform optRandGen :: IO Int
    let ackPkt = mkAckSynPacket initSeqNo (pkgSeqNo synPkt)
        checkAck = isAckFor initSeqNo
    ackPkt <- join $ rightOrThrow <$> sendRecvWithRetry pktMailbox ackPkt 
      optTimeoutMicros optRetryLimit checkAck
    -- ^ Server sends SYN-ACK and waits for ACK.

    (bsIn, bsOut, bsClose)@bsMailbox <- P.spawn' P.Single
    runDataLoop bsMailbox (initSeqNo + 1)
    return bsMailbox

 where
  mkSynPacket seqNo = Packet seqNo (-1) (buildFlags [SYN]) B.empty
  mkAckSynPacket seqNo ackNo =
    Packet seqNo ackNo (buildFlags [ACK, SYN]) B.empty
  mkAckPacket seqNo ackNo = Packet seqNo ackNo (buildFlags [ACK]) B.empty

  isSynAckFor synSeqNo (Packet {..})@pkt =
    isAckFor synSeqNo pkt &&
    hasFlags [SYN] pktFlag

  isAckFor seqNo (Packet {..}) =
    seqNo == pktAckNo &&
    hasFlags [ACK] pktFlag

  runDataLoop (bsIn, bsOut, bsClose) seqNoStart = do
    outQueue <- newTVarIO M.empty
    inQueue <- newTVarIO M.empty
    lastDelivery <- newTVarIO (-1)
    -- ^ Last seqNo that was delivered to the application
    nextSeqNo <- newTVarIO seqNoStart
    bsInT <- async $ bsToPacket nextSeqNo
    bsOutT <- async $ packetToBs nextSeqNo
   where
    -- Just send once and store into the out queue waiting for ACKs.
    -- Another thread will be responsible for resending.
    bsToPacket nextSeqNo = do
      goNext <- atomically $ do
        mbBs <- P.recv bsIn
        case mbBs of
          Nothing ->
            -- Exhausted. Send FIN.
            shutdown
            return (return ())
          Just bs -> do
            seqNo <- readTVar nextSeqNo
            writeTVar nextSeqNo $! seqNo + 1
            let pkt = Packet seqNo (-1) (buildFlags []) bs
            modifyTVar' outQueue $ M.insert seqNo pkt
            return $ bsToPacket nextSeqNo
      goNext

    -- Handles incoming packets.
    packetToBs = do
      goNext <- atomically $ do
        mbPkt <- P.recv pktIn
        case mbPkt of
          Nothing ->
            -- Exhausted. Close this side.
            bsClose
            return (return ())
          Just pkt@(Packet {..}) -> do
            lastNo <- readTVar lastDelivery
            if pkgSeqNo <= lastNo
              then do
                -- Already handled. Ignore that if it's an ACK, or send an
                -- ACK if it's a data packet.
                when (not $ hasFlag ACK pktFlags) $ sendAckFor pkt
              else do
                when (hasFlag ACK pktFlags) $
                  -- Got ACK: remove that pkt in the outQueue
                  modifyTVar' outQueue $ M.delete pktAckNo
                -- Store it into the inQueue and check for delivery
                modifyTVar' inQueue $ M.insert pktSeqNo pkt
            return packetToBs
      goNext

shutdown = error "Shutdown not implemented"


-- Data sender need to use timeout to poll for acks.
sendRecvWithRetry
  :: Mailbox Packet
  -- ^ Packet side
  -> Packet
  -- ^ Packet to send
  -> Int
  -- ^ Timeout in microseconds
  -> Int
  -- ^ Allowed retries
  -> (Packet -> Bool)
  -- ^ Accept if True, and continue to wait if False
  -> IO (Either ConnectionError Packet)
sendRecvWithRetry (pktIn, pktOut) pkt waitMicros retryLimit pktCheck
  = go 0
 where
  go retries
    | retries >= retryLimit = return $ Left TooManyRetries
    | otherwise = do
      runEffect $ yield pkt >-> P.toOutput pktOut
      mmPkt <- timeout waitMicros $ atomically $ recvIf pktCheck (P.recv pktIn)
      case mmPkt of
        Nothing ->
          -- Timeout
          go $ retryNo + 1
        Just Nothing ->
          return $ Left PeerClosed
        Just (Just pkt) ->
          return $ Right pkt

-- ACK sender needs to continue send until the ACK-ed packet is not seen again.
-- Note that this might fall into an infinite loop.
sendUntil
  :: Mailbox Packet
  -> Packet
  -> Int
  -- ^ Max retries
  -> (Packet -> Bool)
  -- ^ True if we see another packet
  -> STM (Maybe ConnectionError)
  -- ^ Nothing if we know that the ACK is received by the peer.

sendUntil (pktIn, pktOut) pkt retryLimit pktCheck
  = go 0
 where
  go retries 
    | retries >= retryLimit = return False
    | otherwise = do
      peerClosed <- P.send pktOut pkt
      if peerClosed
        then return $ Just PeerClosed
        else do
          mbPkt <- recvIf pktCheck (P.recv pktIn)
          case mbPkt of
            Nothing -> return $ Just PeerClosed
            Just pkt -> return Nothing

recvIf :: Monad m => (a -> Bool) -> m (Maybe a) -> m (Maybe a)
recvIf check runInput = do
  mbA <- runInput
  case check <$> mbA of
    Just False ->
      -- Not expected: drop it.
      recvIf check runInput
    _ ->
      -- Either accepted or exhausted.
      return mbA
