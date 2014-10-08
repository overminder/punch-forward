import Control.Concurrent.STM
import Control.Applicative
import Control.Monad.IO.Class
import Data.Aeson hiding (json)
import qualified Data.Map as M
import qualified Data.Text.Lazy as L
import Network.Wai
import Network.Socket
import Web.Scotty

import qualified Broker

instance ToJSON SockAddr where
  toJSON (SockAddrInet port host) = object ["port" .= portInt, "host" .= host]
   where
    portInt = fromIntegral port :: Int

instance FromJSON SockAddr where
  parseJSON (Object v) = SockAddrInet
    <$> (fromInt <$> v .: "port")
    <*> v .: "host"
   where
    fromInt :: Int -> PortNumber
    fromInt = fromIntegral

data Msg
  = MsgError String
  | MsgOk
  | MsgOkAddr SockAddr

instance ToJSON Msg where
  toJSON (MsgError reason) =
    object ["type" .= ("error" :: String), "reason" .= reason]
  toJSON MsgOk =
    object ["type" .= ("ok" :: String)]
  toJSON (MsgOkAddr addr) =
    object ["type" .= ("okAddr" :: String), "addr" .= addr]

instance FromJSON Msg where
  parseJSON (Object v) = do
    ty <- v .: "type"
    case ty of
      ("error" :: String) ->
        MsgError <$> v .: "reason"
      "ok" ->
        return MsgOk
      ("okAddr" :: String) ->
        MsgOkAddr <$> v .: "addr"
    
kBindAliveMicros = (5 * 60 * 1000000) :: Int
kAcceptWaitMicros = (15 * 1000000) :: Int
kBacklog = 5

remoteHostNameForReq = do
  SockAddrInet _ host <- remoteHost <$> request
  return host

remotePunchAddr = do
  port :: Int <- read . L.unpack <$> param "port"
  host <- remoteHostNameForReq
  return $ SockAddrInet (fromIntegral port) host

main = do
  broker <- Broker.new
  scotty 3000 $ do
    get "/" $ html "<h1>Too simple, sometimes naive!</h1>"

    get "/ip" $ do
      rh <- remoteHost <$> request
      json rh

    get "/bindListen/:vAddr" $ do
      -- | The unique identifier to bind to
      vAddr <- param "vAddr"
      host <- remoteHostNameForReq
      res <- liftIO $ Broker.bindListen broker kBindAliveMicros vAddr host
      json $ either (MsgError . show) (const MsgOk) res 

    get "/connect/:vAddr/:port" $ do
      vAddr <- param "vAddr"
      physAddr <- remotePunchAddr
      res <- liftIO $ Broker.connect broker vAddr physAddr
      json $ either (MsgError . show) MsgOkAddr res 

    get "/accept/:vAddr/:port" $ do
      vAddr <- param "vAddr"
      physAddr <- remotePunchAddr
      res <- liftIO $ Broker.accept broker kAcceptWaitMicros vAddr physAddr
      json $ either (MsgError . show) MsgOkAddr res 

