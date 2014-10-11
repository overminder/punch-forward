import Control.Concurrent.STM
import Control.Applicative
import Control.Category ((>>>))
import Control.Monad
import Control.Monad.IO.Class
import Data.Aeson hiding (json)
import Data.String (fromString)
import qualified Data.Map as M
import qualified Data.Text.Lazy as L
import Network.Wai
import Network.Wai.Handler.Warp
import Network.Socket (SockAddr (..))
import Web.Scotty
import Control.Error (note)
import System.Environment (getArgs)

import Network.Punch.Broker.Http.Types
import Network.Punch.Broker.Http.Backend
import Network.Punch.Util (resolveHost)

kBindAliveMicros = (5 * 60 * 1000000) :: Int
kAcceptWaitMicros = (15 * 1000000) :: Int
kBacklog = 5

main = do
  [bindHost] <- getArgs
  broker <- newBroker
  app <- scottyApp $ myScottyApp broker
  let
    conf = setHost (fromString bindHost) . setPort 8080
  putStrLn "Running app..."
  runSettings (conf defaultSettings) app

myScottyApp broker = do
  get "/" $ html "<h1>Too simple, sometimes naive!</h1>"

  get "/list" $ do
    json =<< liftIO (listListeners broker)

  get "/bindListen/:vAddr/:ip" $ do
    -- | The unique identifier to bind to
    vAddr <- param "vAddr"
    host <- fromIntegral <$> paramInt "ip"
    res <- liftIO $ bindListen broker kBindAliveMicros vAddr host
    json $ either MsgError (const MsgOk) res 

  get "/connect/:vAddr/:ip/:port" $ do
    vAddr <- param "vAddr"
    physAddr <- remotePunchAddr
    res <- liftIO $ connect broker vAddr physAddr
    json $ toIpv4E res

  get "/accept/:vAddr/:ip/:port" $ do
    vAddr <- param "vAddr"
    physAddr <- remotePunchAddr
    res <- liftIO $ accept broker kAcceptWaitMicros vAddr physAddr
    json $ toIpv4E res


remoteHostNameForReq = do
  SockAddrInet _ host <- remoteHost <$> request
  return host

paramInt :: L.Text -> ActionM Int
paramInt key = read . L.unpack <$> param key

remotePunchAddr = do
  host <- paramInt "ip"
  port <- paramInt "port"
  return $ SockAddrInet (fromIntegral port) (fromIntegral host)

noteEM :: e -> Either e (Maybe a) -> Either e a
noteEM orElse = join . fmap (note orElse)

toIpv4E :: Either ErrorCode SockAddr -> Msg
toIpv4E = fmap (fmap MsgOkAddr . toIpv4) >>>
          noteEM (Other "Not ipv4") >>>
          either MsgError id

