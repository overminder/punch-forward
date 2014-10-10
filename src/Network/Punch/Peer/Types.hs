module Network.Punch.Peer.Types where

import qualified Data.ByteString as B
import Network.Socket
import Network.Socket.ByteString as B
import qualified Pipes.Concurrent as P
import Data.Typeable (Typeable)
import Control.Exception (throwIO, Exception)

data ControlMessage
  = Shutdown
  | Reset
  deriving (Show, Eq, Typeable)

instance Exception ControlMessage

type PeerMessage a = Either ControlMessage a

class Peer a where
  sendPeer :: a -> B.ByteString -> IO ()
  recvPeer :: a -> IO (PeerMessage B.ByteString)
  closePeer :: a -> IO ()

-- | Represents a UDP connection
data RawPeer = RawPeer
  { rawSock :: Socket
  , rawAddr :: SockAddr
  , rawRecvSize :: Int
  }

instance Peer RawPeer where
  sendPeer (RawPeer {..}) bs = B.sendAllTo rawSock bs rawAddr

  recvPeer p@(RawPeer {..}) = go
   where
    go = do
      (bs, fromAddr) <- B.recvFrom rawSock rawRecvSize
      -- | Ignore data sent from unknown hosts
      if rawAddr /= fromAddr
        then go
        else return (Right bs)

  closePeer _ = return ()
