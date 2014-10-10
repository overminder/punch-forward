module Network.Punch.Peer.Reliable.Types where

-- This should of course be more low-level (like a c-struct).
-- However it seems that the strictness annotations in this type seems to
-- be not affecting the performance..
data Packet
  = Packet {
    pktSeqNo   :: !Int,
    pktAckNo   :: !Int,
    pktFlags   :: ![PacketFlag],
    pktPayload :: !B.ByteString
  }
  deriving (Show, Typeable, Data)
  -- ^ Invariant: serialized form takes <= 512 bytes.
  -- That is, payload should be <= 480 bytes.

-- | For the strict map
instance NFData Packet

data PacketFlag
  = SYN
  -- ^ First packet. XXX: Not used
  | ACK
  -- ^ Acks a previously received packet.
  -- Valid combinations: [SYN,ACK], [ACK], [DATA,ACK]
  | DATA
  -- ^ Contains a valid payload
  | FIN
  | RST
  deriving (Show, Eq, Ord, Enum, Bounded, Typeable, Data)

data ConnOption
  = ConnOption {
    optIsInitiator :: Bool,
    -- ^ True for client, False for server
    optTimeoutMicros :: Int,
    optMaxRetires :: Int,
    optMailbox :: Mailbox Packet,
    optRandGen :: GenIO
  }

data ConnectionError
  = PeerClosed
  | TooManyRetries
  deriving (Show, Eq, Ord, Typeable)

newtype Mailbox a = Mailbox (P.Input a, P.Output a, IO ())

-- Strictness not affecting the performance here.
data InputEntry = InputEntry
  { ieDataPkt    :: !Packet
  , ieAckEchoPkt :: !Packet
  , ieAcked      :: !Bool
  } deriving (Show, Typeable, Data)

newtype DataSeq = DataSeq Int
  deriving (Show, Eq, Ord, Typeable, Data)

newtype AckEchoSeq = AckEchoSeq Int
  deriving (Show, Eq, Ord, Typeable, Data)

-- XXX: Shall we call some of them `control blocks` instead?
type InputQueue = TM.TIMap DataSeq AckEchoSeq InputEntry
type OutputQueue = M.Map Int Packet
type DeliveryQueue = M.Map Int Packet
type ResendQueue = M.Map (UTCTime, Int) (Int, Int)
-- ^ (resend-time, DATA-seq) => (next-backoff-micros, n-retries)

instance NFData InputEntry
instance NFData InputQueue

data State = State
  { stConnOpt :: ConnOption
  , stDataSeq :: Int
  , stAckEchoSeq :: Int
  , stInputQ :: InputQueue
  , stOutputQ :: OutputQueue
  , stDeliveryQ :: DeliveryQueue
  , stResendQ :: ResendQueue
  , stMailbox :: Mailbox Packet
  , stResendThread :: Async ()
  , stRecvThread :: Async ()
  }

type StateRef = MVar State

newState :: ConnOption -> IO StateRef
newState opt = do
  stateRef <- newEmptyMVar
  tResend <- async $ runUntilFalse resendOnce stateRef
  tRecv <- async $ runUntilFalse recvOnce stateRef
  
  putMVar stateRef $ State
    { stConnOpt = opt
    , stDataSeqGen = 0
    , stAckEchoSeqGen = 0
    , stLastFinishedDataSeq = 0
    , stLastFinsihedAckSeq = 0
    , stInputQ = TM.empty
    , stOutputQ = M.empty
    , stDeliveryQ = M.empty
    , stResendQ = M.empty
    , stResendThread = tResend
    , stRecvThread = tRecv
    }
  return stateRef

runResend stateRef = go
 where
  go = do
    threadDelay (100 * 1000)
    eiResult <- modifyMVar stateRef resendOnce
    case eiResult of
      Right () -> go
      Left err -> closeState stateRef err

  resendOnce s@(State {..}) = do
    now <- getCurrentTime
    let (works, rest) = M.split (now, (-1)) stResendQ
    eiRes <- runEitherT $
      forM (M.toList works) $
        \ ((_, dataSeq), (nextBackOff, numRetries)) -> do
          case M.lookup dataSeq stOutputQ of
            Nothing -> do
              -- Received ACK-ECHO for this packet and there is no need
              -- to keep resending this packet. Clear it.
              return Nothing
            Just dataPkt -> if numRetries > optMaxRetries stConnOpt
              then left TooManyRetries
              else do
                -- Try to send it
                ok <- liftIO $ sendMailbox (optMailbox stConnOpt) dataPkt
                if not ok
                  then left PeerClosed
                  else do
                    -- And set the backoff timeout for this packet
                    let
                      nextBackOffSec = fromIntegral nextBackOff / 1000000
                      nextTime = addUTCTime nextBackOffSec now
                    return $ Just ((nextTime, dataSeq),
                                   (nextBackOff * 2, numRetries + 1))
    case eiRes of
      Left err ->
        return (s, Left err)
      Right newResends -> do
        let
          -- Add back new backoffs
          combine = maybe id (uncurry M.insert)
          newResendQ = M.foldr combine rest newResends
          s' = s { stResendQ = newResendQ }
        return (s', Right ())

recvOnce :: StateRef -> IO (State, Bool)
recvOnce stateRef = go
 where
  go = do
    mbPkt <- recvMailbox (optMailbox stConnOpt)
    case mbPkt of
      Just pkt ->
        modifyMVar stateRef (onPkt pkt)
        go
      Nothing ->
        return (Left PeerClosed)

  onPkt pkt@(Packet {..}) s@(State {..})
    | isDataPkt pkt -> do
      if dataWasFinished
        then return ()
        else do
          -- Deliver the payload.
          deliver pktSeqNo pktPayload
          -- And make a DATA-ACK for it
          sendDataAckFor pktSeqNo

    | isDataAckPkt pkt -> do
      clearInQ
      sendAckFor pktSeqNo
      

sendMailbox :: Mailbox a -> a -> IO Bool
sendMailbox (Mailbox (_, output, _)) a = P.send output a

recvMailbox :: Mailbox a -> IO (Maybe a)
sendMailbox (Mailbox (input, _, _)) = P.recv input

