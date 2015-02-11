module Network.Punch.Peer.Reliable.Types where

import Control.Applicative ((<$>), (<*>))
import Control.Concurrent.MVar
import Control.Concurrent.Async (Async, async)
import Control.Concurrent.STM (STM, TVar)
import Control.DeepSeq (NFData)
import qualified Data.ByteString as B
import qualified Data.Serialize as S
import Data.Time
import Data.Bits (testBit, setBit, clearBit)
import qualified Data.Map as M
import Data.Data (Data)
import Data.Typeable (Typeable)
import qualified Pipes.Concurrent as P
import Text.Printf (printf)

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

showPacket :: Packet -> String
showPacket pkt@(Packet {..}) =
  printf "<Packet %-5d, %-10s, %5d bytes>"
         pktSeqNo (show pktFlags) (B.length pktPayload)

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
  = ConnOption
  { optDefaultBackOff :: Int
    -- ^ In micros
  , optMaxRetries :: Int
  , optMaxPayloadSize :: Int
  , optMaxUnackedPackets :: Int
    -- ^ Used to avoid congestion
  , optTxBufferSize :: Int
    -- ^ Size of the fromApp mailbox size
  , optRxBufferSize :: Int
    -- ^ Size of the toApp mailbox size
  }

newtype Mailbox a = Mailbox (P.Output a, P.Input a, STM ())

-- XXX: Shall we call some of them `control blocks` instead?
type OutputQueue = M.Map Int Packet
type DeliveryQueue = M.Map Int B.ByteString
type ResendQueue = M.Map (UTCTime, Int) (Int, Int)
-- ^ (resend-time, DATA-seq) => (next-backoff-micros, n-retries)

data RcbState
  = RcbOpen
  | RcbFinSent
  | RcbCloseWait
  | RcbClosed
  deriving (Show, Eq)

data CloseReason
  = PeerClosed
  | TooManyRetries
  | GracefullyShutdown
  | AlreadyClosed
  deriving (Show, Eq, Ord, Typeable)

-- | Reliable Control Block
data Rcb = Rcb
  { rcbConnOpt :: ConnOption
  , rcbFromNic :: Mailbox Packet
  , rcbToNic :: Mailbox Packet
  , rcbFromApp :: Mailbox (Int, B.ByteString)
  -- ^ (SeqNo, Payload)
  -- We link the seqNo early since this makes FIN handling easier.
  , rcbToApp :: Mailbox B.ByteString
  -- ^ Used to track the current number of unacked packets.
  , rcbMutRef :: TVar RcbMut
  }

data RcbMut = RcbMut
  { rcbState :: RcbState
  , rcbSeqGen :: Int
  , rcbFinSeq :: Int
  -- ^ Only available when entering the CloseWait state.
  -- This is the last DATA seq that we are going to receive.
  , rcbLastDeliverySeq :: Int

  -- ^ In case this is connected to any other pipes
  , rcbOutputQ :: OutputQueue
  , rcbDeliveryQ :: DeliveryQueue
  , rcbResendQ :: ResendQueue
  -- ^ A priority-queue like for the timer thread to use

  , rcbExtraFinalizers :: [IO ()]
  }

type RcbRef = Rcb

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

hasFlag :: Enum a => Int -> a -> Bool
hasFlag flag a = testBit flag (fromEnum a)

setFlag :: Enum a => Int -> a -> Int
setFlag flag a = setBit flag (fromEnum a)

delFlag :: Enum a => Int -> a -> Int
delFlag flag a = clearBit flag (fromEnum a)

-- Util

