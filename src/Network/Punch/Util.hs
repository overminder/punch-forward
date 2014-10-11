module Network.Punch.Util where

import Control.Applicative
import Network.Socket
import Network.BSD
import Control.Monad
import Pipes
import Pipes.Prelude as P
import Control.Monad.Identity
import qualified Data.ByteString as B
import Debug.Trace

trace2 _ a = a
--trace2 = trace

traceM s = trace2 s $ return ()

infoM s = trace s $ return ()

cutBsTo :: Monad m => Int -> Pipe B.ByteString B.ByteString m ()
cutBsTo n = forever $ do
  bs <- await
  mapM_ yield (cut bs)
 where
  cut bs
    | B.length bs <= n = [bs]
    | otherwise = B.take n bs : cut (B.drop n bs)

cutBs :: Int -> B.ByteString -> [B.ByteString]
cutBs n bs = runIdentity $ P.toListM $ yield bs >-> cutBsTo n

sockAddrFor :: Maybe String -> Int -> IO SockAddr
sockAddrFor mbHostName port = do
  host <- maybe (return iNADDR_ANY) getHost mbHostName
  return (SockAddrInet (fromIntegral port) host)
 where
  getHost hostName = do
    (host:_) <- hostAddresses <$> getHostByName hostName
    return host

pipeWith printIt = forever $ do
  wat <- await
  liftIO $ printIt wat
  yield wat

