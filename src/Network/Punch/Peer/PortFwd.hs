module Network.Punch.Peer.PortFwd (
  simpleL2RForwardOnLocal,
  simpleR2LForwardOnRemote
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
toSocket sock = forever (NSB.sendAll sock =<< await)

serveOnce :: SockAddr -> ((Socket, SockAddr) -> IO a) -> IO a
serveOnce addr f = bracket accept (sClose . fst) f
 where
  accept = bracket listenOnce NS.sClose NS.accept
  listenOnce = do
    s <- NS.socket AF_INET Stream defaultProtocol
    NS.bind s addr
    NS.listen s 1
    return s

connect :: SockAddr -> (Socket -> IO a) -> IO a
connect addr f = bracket doConn sClose f
 where 
  doConn = do
    s <- NS.socket AF_INET Stream defaultProtocol
    NS.connect s addr
    return s

mkSockAddr :: String -> Int -> IO SockAddr
mkSockAddr host port = do
  x

simpleL2RForwardOnLocal
  :: Int
  -- ^ Local port
  -> (Producer B.ByteString IO (),
      Consumer B.ByteString IO ())
  -> IO ()
simpleL2RForwardOnLocal port (bsIn, bsOut) = do
  addr <- sockAddrFor (Just "127.0.0.1") port
  serveOnce addr $ \ (s, who) -> do
    putStrLn $ "someone from local connected: " ++ show who
    async $ runEffect $ fromSocket s 4096 >-> logWith "fromSock " >-> bsOut
    runEffect $ bsIn >-> logWith "toSock " >-> toSocket s

simpleL2RForwardOnRemote
  :: Int
  -- ^ Remote port
  -> (Producer B.ByteString IO (),
      Consumer B.ByteString IO ())
  -> IO ()
simpleL2RForwardOnRemote port (bsIn, bsOut) = do
  addr <- sockAddrFor (Just "127.0.0.1") port
  connect addr $ \ s -> do
    async $ runEffect $ fromSocket s 4096 >-> logWith "fromSock " >-> bsOut
    runEffect $ bsIn >-> logWith "toSock " >-> toSocket s

logWith tag = forever $ await >>= yield

--logWith tag = forever $ do
--  x <- await
--  liftIO $ putStrLn $ tag ++ show x
--  yield x
