module Protocol.Forward where

import qualified Data.ByteString as B
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
  listen (Host "") (show port) $ \ (s, _) -> do
    async $ runEffect $ P.fromSocket s 4096 >-> bsOut
    runEffect $ bsIn >-> P.toSocket s

simpleL2RForwardOnRemote
  :: Int
  -- ^ Remote port
  -> (Producer B.ByteString IO (),
      Consumer B.ByteString IO ())
  -> IO ()
simpleL2RForwardOnRemote port (bsIn, bsOut) = do
  connect "localhost" (show port) $ \ (s, _) -> do
    async $ runEffect $ P.fromSocket s 4096 >-> bsOut
    runEffect $ bsIn >-> P.toSocket s

