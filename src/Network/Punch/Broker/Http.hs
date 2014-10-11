module Network.Punch.Broker.Http
  ( Broker
  , newBroker
  , bind
  , accept
  , connect
  ) where

import Control.Applicative ((<$>))
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy.UTF8 as BLU8
import Network.Socket hiding (bind, accept, connect)
import qualified Network.Socket as NS
import Network.HTTP (simpleHTTP, getRequest, getResponseBody)

import Network.Punch.Broker.Http.Types
import Network.Punch.Util (resolveHost)

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
    rsp <- simpleHTTP (getRequest "http://httpbin.org/ip")
    resolveHost . Just =<< getResponseBody rsp

bind :: Broker -> IO ()
bind (Broker {..}) = do
  msg <- getResponseJson uri :: IO Msg
  putStrLn $ "[Http.bind] " ++ show msg
  return ()
 where
  uri = brEndpoint ++ "/bindListen/" ++ brOurVAddr ++ "/" ++ show brOurHost

accept :: Broker -> IO (Socket, SockAddr)
accept (Broker {..}) = do
  (s, myPort) <- mkBoundUdpSock
  let
    uri = brEndpoint ++ "/accept/" ++ brOurVAddr ++ "/" ++
          show brOurHost ++ "/" ++ show myPort
  go uri s
 where
  go uri s = do
    msg <- getResponseJson uri
    case msg of
      MsgOkAddr ipv4 -> return (s, fromIpv4 ipv4)
      MsgError Timeout -> go uri s
      MsgError err -> error $ "[Http.accept.go] " ++ show err

connect :: Broker -> IO (Maybe (Socket, SockAddr))
connect (Broker {..}) = do
  (s, myPort) <- mkBoundUdpSock
  let
    uri = brEndpoint ++ "/connect/" ++ brOurVAddr ++ "/" ++
          show brOurHost ++ "/" ++ show myPort
  msg <- getResponseJson uri
  case msg of
    MsgOkAddr ipv4 -> return $ Just (s, fromIpv4 ipv4)
    MsgError NoAcceptor -> return Nothing
    MsgError err -> error $ "[Http.connect.go] " ++ show err

--
getResponseJson uri = do
  rsp <- simpleHTTP (getRequest uri)
  Just a <- A.decode . BLU8.fromString <$> getResponseBody rsp
  return a

mkBoundUdpSock = do
  s <- socket AF_INET Datagram defaultProtocol
  NS.bind s (SockAddrInet aNY_PORT iNADDR_ANY)
  SockAddrInet port _ <- getSocketName s
  return (s, port)

