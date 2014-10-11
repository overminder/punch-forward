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
serveOnce addr f = bracket accept (NS.sClose . fst) f
 where
  accept = bracket listenOnce NS.sClose NS.accept
  listenOnce = do
    s <- NS.socket NS.AF_INET NS.Stream NS.defaultProtocol
    NS.bind s addr
    NS.listen s 1
    return s

connect :: SockAddr -> (Socket -> IO a) -> IO a
connect addr f = bracket doConn NS.sClose f
 where 
  doConn = do
    s <- NS.socket NS.AF_INET NS.Stream NS.defaultProtocol
    NS.connect s addr
    return s

serveLocalRequest :: Peer p => Int -> p -> IO ()
serveLocalRequest port p = do
  addr <- sockAddrFor Nothing port
  serveOnce addr $ \ (s, who) -> do
    putStrLn $ "[serveLocal] connected: " ++ show who
    t1 <- async $ runEffect $ fromSocket s 4096 >-> logWith "fromSock " >-> toPeer p
    t2 <- async $ runEffect $ fromPeer p >-> logWith "toSock " >-> toSocket s
    waitAnyCatch [t1, t2]
    putStrLn $ "[serveLocal] done: " ++ show who

connectToDest :: Peer p => Int -> p -> IO ()
connectToDest port p = do
  addr <- sockAddrFor (Just "127.0.0.1") port
  connect addr $ \ s -> do
    t1 <- async $ runEffect $ fromSocket s 4096 >-> logWith "fromSock " >-> toPeer p
    t2 <- async $ runEffect $ fromPeer p >-> logWith "toSock " >-> toSocket s
    waitAnyCatch [t1, t2]
    return ()

logWith tag = forever $ await >>= yield

--logWith tag = forever $ do
--  x <- await
--  liftIO $ putStrLn $ tag ++ show x
--  yield x
