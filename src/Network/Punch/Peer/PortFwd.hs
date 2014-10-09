module Network.Punch.Peer.PortFwd where

import qualified Data.ByteString as B
import Control.Monad
import Control.Concurrent.Async
import Pipes
import qualified Pipes.Concurrent as P
import qualified Pipes.Network.TCP as P
import Network.Simple.TCP

-- Simple L->R forward

simpleL2RForwardOnLocal
  :: Int
  -- ^ Local port
  -> (Producer B.ByteString IO (),
      Consumer B.ByteString IO ())
  -> IO ()
simpleL2RForwardOnLocal port (bsIn, bsOut) = do
  serve (Host "127.0.0.1") (show port) $ \ (s, who) -> do
    putStrLn $ "someone from local connected: " ++ show who
    async $ runEffect $ P.fromSocket s 4096 >-> logWith "fromSock " >-> bsOut
    runEffect $ bsIn >-> logWith "toSock " >-> P.toSocket s

simpleL2RForwardOnRemote
  :: Int
  -- ^ Remote port
  -> (Producer B.ByteString IO (),
      Consumer B.ByteString IO ())
  -> IO ()
simpleL2RForwardOnRemote port (bsIn, bsOut) = do
  connect "127.0.0.1" (show port) $ \ (s, _) -> do
    async $ runEffect $ P.fromSocket s 4096 >-> logWith "fromSock " >-> bsOut
    runEffect $ bsIn >-> logWith "toSock " >-> P.toSocket s

logWith tag = forever $ await >>= yield

--logWith tag = forever $ do
--  x <- await
--  liftIO $ putStrLn $ tag ++ show x
--  yield x
