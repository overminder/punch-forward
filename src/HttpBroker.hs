import Control.Concurrent.STM
import Control.Applicative
import Control.Category ((>>>))
import Control.Monad
import Control.Monad.IO.Class
import Data.Aeson hiding (json)
import qualified Data.Map as M
import qualified Data.Text.Lazy as L
import Network.Wai
import Network.Socket (SockAddr (..))
import Web.Scotty
import Control.Error (note)

import Network.Punch.Broker.Http.Types
import Network.Punch.Broker.Http.Backend

kBindAliveMicros = (5 * 60 * 1000000) :: Int
kAcceptWaitMicros = (15 * 1000000) :: Int
kBacklog = 5

main = do
  broker <- newBroker
  scotty 3000 $ do
    get "/" $ html "<h1>Too simple, sometimes naive!</h1>"

    get "/ip" $ do
      rh <- remoteHost <$> request
      json (toIpv4E $ Right rh)

    get "/bindListen/:vAddr" $ do
      -- | The unique identifier to bind to
      vAddr <- param "vAddr"
      host <- remoteHostNameForReq
      res <- liftIO $ bindListen broker kBindAliveMicros vAddr host
      json $ either MsgError (const MsgOk) res 

    get "/connect/:vAddr/:port" $ do
      vAddr <- param "vAddr"
      physAddr <- remotePunchAddr
      res <- liftIO $ connect broker vAddr physAddr
      json $ toIpv4E res

    get "/accept/:vAddr/:port" $ do
      vAddr <- param "vAddr"
      physAddr <- remotePunchAddr
      res <- liftIO $ accept broker kAcceptWaitMicros vAddr physAddr
      json $ toIpv4E res


remoteHostNameForReq = do
  SockAddrInet _ host <- remoteHost <$> request
  return host

remotePunchAddr = do
  port :: Int <- read . L.unpack <$> param "port"
  host <- remoteHostNameForReq
  return $ SockAddrInet (fromIntegral port) host

noteEM :: e -> Either e (Maybe a) -> Either e a
noteEM orElse = join . fmap (note orElse)

toIpv4E :: Either ErrorCode SockAddr -> Msg
toIpv4E = fmap (fmap MsgOkAddr . toIpv4) >>>
          noteEM (Other "Not ipv4") >>>
          either MsgError id

