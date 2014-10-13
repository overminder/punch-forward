module Network.Punch.Peer.PortFwd (
  serveLocalRequest,
  connectToDest
) where

import Control.Exception (bracket)
import qualified Data.ByteString as B
import Control.Monad
import Control.Concurrent.Async
import Pipes
import qualified Pipes.Concurrent as P
import Network.Socket hiding (connect, accept)
import qualified Network.Socket as NS
import Network.Socket (Socket, SockAddr (..))
import Network.BSD
import qualified Network.Socket.ByteString as NSB

import Network.Punch.Util (sockAddrFor)
import Network.Punch.Peer.Types

-- Simple L->R forward

fromSocket :: Socket -> Int -> Producer B.ByteString IO ()
fromSocket s size = go
 where
  go = do
    bs <- liftIO (NSB.recv s size)
    if B.null bs
      then return ()
      else yield bs >> go

toSocket :: Socket -> Consumer B.ByteString IO ()
toSocket sock = forever (liftIO . NSB.sendAll sock =<< await)

serveOnce :: SockAddr -> ((Socket, SockAddr) -> IO a) -> IO a
serveOnce addr f = bracket accept (sClose . fst) f
 where
  accept = bracket listenOnce sClose NS.accept
  listenOnce = do
    s <- mkTcpSock
    bind s addr
    listen s 1
    return s

connect :: SockAddr -> (Socket -> IO a) -> IO a
connect addr f = bracket doConn sClose f
 where 
  doConn = do
    s <- mkTcpSock
    NS.connect s addr
    return s

mkTcpSock :: IO Socket
mkTcpSock = do
  s <- socket AF_INET Stream defaultProtocol
  setSocketOption s ReuseAddr 1
  return s

serveLocalRequest :: Peer p => Int -> IO p -> IO ()
serveLocalRequest port mkP = do
  addr <- sockAddrFor Nothing port
  serveOnce addr $ \ (s, who) -> do
    p <- mkP
    putStrLn $ "[serveLocal] connected: " ++ show who
    t1 <- async $ runEffect $ fromSocket s 4096 >-> logWith "fromSock " >-> toPeer p
    t2 <- async $ runEffect $ fromPeer p >-> logWith "toSock " >-> toSocket s
    waitAnyCatch [t1, t2]
    closePeer p
    putStrLn $ "[serveLocal] done: " ++ show who

connectToDest :: Peer p => Int -> IO p -> IO ()
connectToDest port mkP = do
  addr <- sockAddrFor (Just "127.0.0.1") port
  connect addr $ \ s -> do
    p <- mkP
    t1 <- async $ runEffect $ fromSocket s 4096 >-> logWith "fromSock " >-> toPeer p
    t2 <- async $ runEffect $ fromPeer p >-> logWith "toSock " >-> toSocket s
    waitAnyCatch [t1, t2]
    closePeer p
    return ()

logWith tag = forever $ await >>= yield

--logWith tag = forever $ do
--  x <- await
--  liftIO $ putStrLn $ tag ++ show x
--  yield x
