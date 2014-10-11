module Network.Punch.Peer.Types where

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as B
import Network.Socket (Socket, SockAddr)
import qualified Network.Socket.ByteString as B
import qualified Pipes.Concurrent as P
import Data.Typeable (Typeable)
import Pipes (Producer, Consumer, await, yield)

class Peer a where
  sendPeer :: a -> B.ByteString -> IO Bool
  recvPeer :: a -> IO (Maybe B.ByteString)
  closePeer :: a -> IO ()

-- | Represents a UDP connection
data RawPeer = RawPeer
  { rawSock :: Socket
  , rawAddr :: SockAddr
  , rawRecvSize :: Int
  }

fromPeer :: Peer a => a -> Producer B.ByteString IO ()
fromPeer p = go
 where
  go = maybe (return ()) ((>> go) . yield) =<< (liftIO $ recvPeer p)

toPeer :: Peer a => a -> Consumer B.ByteString IO ()
toPeer p = go
 where
  go = do
    bs <- await
    ok <- liftIO $ sendPeer p bs
    when ok go

instance Peer RawPeer where
  sendPeer (RawPeer {..}) bs = B.sendAllTo rawSock bs rawAddr >> return True

  recvPeer p@(RawPeer {..}) = go
   where
    go = do
      (bs, fromAddr) <- B.recvFrom rawSock rawRecvSize
      -- | Ignore data sent from unknown hosts
      if rawAddr /= fromAddr
        then go
        else return (Just bs)

  closePeer _ = return ()

