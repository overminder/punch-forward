module Network.Punch.Peer.Reliable.Types where

import Control.Concurrent.STM (STM, atomically)

-- This should of course be more low-level (like a c-struct).
-- However it seems that the strictness annotations in this type seems to
-- be not affecting the performance..
data Packet
  = Packet {
    pktSeqNo   :: !Int,
    -- ^ DATA packets use it as the sequence No.,
    -- while DATA_ACK packets use it as the acknowledgement No.
    pktFlags   :: ![PacketFlag],
    -- ^ Bit flags
    pktPayload :: !B.ByteString
    -- ^ Currently only valid for DATA packets
  }
  deriving (Show, Typeable, Data)
  -- ^ Invariant: serialized form takes <= 512 bytes.
  -- That is, payload should be <= 480 bytes.

-- | For the strict map
instance NFData Packet

data PacketFlag
  = ACK
  -- ^ Acks a previously received DATA / FIN packet.
  | DATA
  -- ^ Contains a valid payload. Expects a DATA-ACK reply.
  | FIN
  -- ^ Starts shutdown, expects a FIN-ACK reply
  | RST
  -- ^ Hard reset.
  deriving (Show, Eq, Ord, Enum, Bounded, Typeable, Data)

data ConnOption
  = ConnOption {
    optIsInitiator :: Bool,
    -- ^ True for client, False for server
    optDefaultBackOff :: Int,
    -- ^ In micros
    optMaxRetires :: Int,
    optRandGen :: GenIO
  }

data ConnectionError
  = PeerClosed
  | TooManyRetries
  deriving (Show, Eq, Ord, Typeable)

newtype Mailbox a = Mailbox (P.Input a, P.Output a, STM ())

-- XXX: Shall we call some of them `control blocks` instead?
type OutputQueue = M.Map Int Packet
type DeliveryQueue = M.Map Int B.ByteString
type ResendQueue = M.Map (UTCTime, Int) (Int, Int)
-- ^ (resend-time, DATA-seq) => (next-backoff-micros, n-retries)

instance NFData InputEntry
instance NFData InputQueue

data RcbState
  = RcbOpen
  | RcbFinSent
  | RcbCloseWait
  | RcbClosed
  deriving (Show, Eq)

-- | Reliable Control Block
data Rcb = Rcb
  { rcbConnOpt :: ConnOption
  , rcbState :: RcbState
  , rcbFromNic :: Mailbox Packet
  , rcbToNic :: Mailbox Packet
  , rcbFromApp :: Mailbox (Int, B.ByteString)
  -- ^ (SeqNo, Payload)
  -- We link the seqNo early since this makes FIN handling easier.
  , rcbToApp :: Mailbox B.ByteString
  , rcbSeqGen :: Int
  , rcbOutputQ :: OutputQueue
  , rcbDeliveryQ :: DeliveryQueue
  , rcbLastDeliverySeq :: Int
  , rcbResendQ :: ResendQueue
  -- A priority-queue like for the timer thread to use
  , rcbFinSeq :: Int
  -- ^ Only available when entering the CloseWait state.
  -- This is the last DATA seq that we are going to receive.
  , rcbResendThread :: Async ()
  , rcbRecvThread :: Async ()
  , rcbSendThread :: Async ()
  }

type RcbRef = MVar Rcb

-- Serialization
putPacket :: Packet -> S.Put
putPacket (Packet {..}) = do
  S.put pktSeqNo
  S.put $ foldFlags pktFlags
  S.put pktPayload

getPacket :: S.Get Packet
getPacket = Packet <$> S.get <*> (unfoldFlags <$> S.get) <*> S.get

foldFlags :: Enum a => [a] -> Int
foldFlags = foldr (flip setFlag) 0

unfoldFlags :: (Bounded a, Enum a) => Int -> [a]
unfoldFlags flag = concatMap check [minBound..maxBound]
 where
  check a = if hasFlag flag a then [a] else []

-- Util

