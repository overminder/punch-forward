{-# LANGUAGE TupleSections #-}

module Network.Punch.Broker.Http
  ( Broker
  , newBroker
  , bind
  , accept
  , connect
  ) where

import Control.Applicative ((<$>))
import Control.Exception (throwIO, try, SomeException)
import System.IO.Error (userError)
import Control.Concurrent (threadDelay)
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

data Broker = Broker
  { brEndpoint :: String
  -- ^ Without trailing slash
  , brOurVAddr :: String
  }

newBroker :: String -> String -> IO Broker
newBroker endpoint vAddr = return $ Broker endpoint vAddr

bind :: Broker -> IO ()
bind (Broker {..}) = do
  putStrLn $ "[Http.bind] started"
  msg <- requestPostJson uri (Nothing :: Maybe String) :: IO Msg
  putStrLn $ "[Http.bind] " ++ show msg
  return ()
 where
  uri = brEndpoint ++ "/bindListen/" ++ brOurVAddr

accept :: Broker -> IO (Socket, SockAddr)
accept broker@(Broker {..}) = do
  (s, serverPort) <- mkBoundUdpSock Nothing
  let
    uri = brEndpoint ++ "/accept/" ++ brOurVAddr
  go uri s serverPort
 where
  go uri s serverPort = do
    putStrLn $ "[Http.accept] started"
    eiMsg <- try $ requestPostJson uri $ CommRequest serverPort
    case eiMsg of
      Left (connE :: SomeException) -> do
        -- There seems to be a fd leak in `accept` in case of
        -- network errors.
        sClose s
        throwIO connE
      Right msg -> do
        putStrLn $ "[Http.accept] got " ++ show msg
        case msg of
          MsgOkAddr ipv4 -> (s,) <$> fromIpv4 ipv4
          MsgError Timeout -> go uri s serverPort
          MsgError NotBound -> do
            -- Broker was restarted and lost its internal state
            putStrLn "[Http.accept] Broker seems to have be restarted. Rebinding my address..."
            bind broker
            go uri s serverPort
          MsgError err -> do
            close s
            throwIO $ userError $ "[Http.accept.go] " ++ show err

connect :: Broker -> IO (Maybe (Socket, SockAddr))
connect (Broker {..}) = do
  (s, clientPort) <- mkBoundUdpSock Nothing
  let
    uri = brEndpoint ++ "/connect/" ++ brOurVAddr
  putStrLn $ "[Http.connect] started"
  msg <- requestPostJson uri $ CommRequest clientPort
  putStrLn $ "[Http.connect] got " ++ show msg
  case msg of
    MsgOkAddr ipv4 -> Just <$> ((s,) <$> fromIpv4 ipv4)
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

