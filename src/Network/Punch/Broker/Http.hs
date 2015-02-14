module Network.Punch.Broker.Http
  ( Broker
  , newBroker
  , bind
  , accept
  , connect
  ) where

import Control.Applicative ((<$>))
import Control.Exception (throwIO)
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy.UTF8 as BLU8
import Network.Socket hiding (bind, accept, connect)
import qualified Network.Socket as NS
import Network.HTTP
  ( simpleHTTP
  , getRequest
  , postRequest
  , setRequestBody
  , getResponseBody)

import Network.Punch.Broker.Http.Types
import Network.Punch.Util (resolveHost, mkBoundUdpSock)

import Config
-- ^ XXX

newtype Origin = Origin String

instance A.FromJSON Origin where
  parseJSON (A.Object v) = Origin <$> v A..: "origin"

data Broker = Broker
  { brEndpoint :: String
  -- ^ Without trailing slash
  , brOurVAddr :: String
  , brOurHost :: HostAddress
  }

newBroker :: String -> String -> IO Broker
newBroker endpoint vAddr = Broker endpoint vAddr <$> getIp
 where
  getIp = do
    hostName <- case Config.myIp of
      Just ip -> do
        putStrLn $ "[newBroker.getIp] Force using config value: " ++ ip
        return ip
      Nothing -> do
        -- httpbin might return many ips, separated by comma
        putStrLn $ "[Http.newBroker] fetching my IP"
        Origin hostNames <- requestGetJson "http://httpbin.org/ip"
        let (hostName, _) = span (/= ',') hostNames
        putStrLn $ "[newBroker.getIp] " ++ hostNames ++ ", using " ++ hostName
        return hostName
    resolveHost (Just hostName)

bind :: Broker -> IO ()
bind (Broker {..}) = do
  putStrLn $ "[Http.bind] started"
  msg <- requestPostJson uri brOurHost :: IO Msg
  putStrLn $ "[Http.bind] " ++ show msg
  return ()
 where
  uri = brEndpoint ++ "/bindListen/" ++ brOurVAddr

accept :: Broker -> IO (Socket, SockAddr)
accept broker@(Broker {..}) = do
  (s, myPort) <- mkBoundUdpSock Nothing
  let
    uri = brEndpoint ++ "/accept/" ++ brOurVAddr
    myPortInt = fromIntegral myPort :: Int
  go uri s myPortInt
 where
  go uri s myPortInt = do
    putStrLn $ "[Http.accept] started"
    msg <- requestPostJson uri (brOurHost, myPortInt)
    putStrLn $ "[Http.accept] got " ++ show msg
    case msg of
      MsgOkAddr ipv4 -> return (s, fromIpv4 ipv4)
      MsgError Timeout -> go uri s myPortInt
      MsgError NotBound -> do
        -- Broker was restarted and lost its internal state
        putStrLn "[Http.accept] Broker seems to have be restarted. Rebinding my address..."
        bind broker
        go uri s myPortInt
      MsgError err -> do
        error $ "[Http.accept.go] " ++ show err

connect :: Broker -> IO (Maybe (Socket, SockAddr))
connect (Broker {..}) = do
  (s, myPort) <- mkBoundUdpSock Nothing
  let
    myPortInt = fromIntegral myPort :: Int
    uri = brEndpoint ++ "/connect/" ++ brOurVAddr
  putStrLn $ "[Http.connect] started"
  msg <- requestPostJson uri (brOurHost, myPortInt)
  putStrLn $ "[Http.connect] got " ++ show msg
  case msg of
    MsgOkAddr ipv4 -> return $ Just (s, fromIpv4 ipv4)
    MsgError NoAcceptor -> return Nothing
    MsgError err -> error $ "[Http.connect.go] " ++ show err

--
requestGetJson uri = do
  rsp <- simpleHTTP (getRequest uri)
  mbA <- A.decode . BLU8.fromString <$> getResponseBody rsp
  case mbA of
    Just a -> return a
    Nothing -> throwIO (userError $ "requestGetJson " ++ uri ++ ": no parse.")

requestPostJson :: (A.ToJSON a, A.FromJSON b) => String -> a -> IO b
requestPostJson uri body = do
  let
    req = setRequestBody (postRequest uri)
      ("application/json", BLU8.toString $ A.encode body)
  rsp <- simpleHTTP req
  bodyStr <- getResponseBody rsp
  let mbA = A.decode (BLU8.fromString bodyStr)
  case mbA of
    Just a -> return a
    Nothing -> throwIO (userError $
      "requestPostJson " ++ uri ++ ": no parse: " ++ bodyStr)

