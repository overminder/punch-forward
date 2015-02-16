{-# LANGUAGE RecordWildCards #-}

import Control.Applicative
import Control.Monad (forever, void)
import Control.Exception (try, SomeException)
import Network.Socket (withSocketsDo)
import Control.Concurrent.Async (async)
import Control.Concurrent.MVar
import System.Environment
import qualified Network.Socket.ByteString as B
import Network.Socket
import Network.BSD
import System.Timeout
import Pipes (runEffect, (>->))
import Text.Read (readMaybe)

import qualified Config
import qualified Network.Punch.Peer.Simple as SP
import Network.Punch.Peer.Simple (kRecvSize)
import Network.Punch.Peer.Reliable
import Network.Punch.Peer.PortFwd
import Network.Punch.Peer.Types
import Network.Punch.Util

import qualified Network.Punch.Broker.Http as BH

punchTimeout = 10000000

data Action
  = PunchForward
    { pfPeerId :: String
    , pfServiceAction :: ServiceAction
    , pfFwdAction :: ForwardAction
    , pfFwdPort :: Int
    }
  | ForwardLite
    { flListenPort :: Int
      -- ^ The local UDP port to bind to, or the local TCP port to
      -- forward from.
    , flConnAddr :: SockAddr
      -- ^ The remote UDP host to connect to, or the local TCP host
      -- to forward incoming peers to.
    , flAction :: ServiceAction
    }
  | Usage String
  deriving (Show, Eq)

data ServiceAction = Serve | Connect
  deriving (Show, Read, Eq)

data ForwardAction = Local | Remote
  deriving (Show, Read, Eq)

-- "ssh -L|-R _:localhost:port"
parseArg [ readMaybe -> Just serviceAction
         , peerId
         , readMaybe -> Just fwdAction
         , readMaybe -> Just port]
  = return $ PunchForward peerId serviceAction fwdAction port

parseArg [ "Lite"
         , readMaybe -> Just serviceAction
         , readMaybe -> Just listenPort
         , connHost
         , readMaybe -> Just connPort] = do
  addr <- sockAddrFor (Just connHost) connPort
  return $ ForwardLite
    { flListenPort = listenPort
    , flConnAddr = addr
    , flAction = serviceAction
    }


parseArg _ = return $ Usage $ unlines errMsg
 where
  errMsg = [ "usage: [program] OPTIONS"
           , " where OPTIONS can be:"
           , "  SERVICE_ACTION PEER_ID ( 'Local' | 'Remote' ) PORT"
           , "  'Lite' SERVICE_ACTION LISTEN_PORT CONNECT_HOST CONNECT_PORT"
           , " where SERVICE_ACTION can be:"
           , "  ( 'Serve' | 'Connect' )"
           ]

main = withSocketsDo $ do
  (read -> bufSiz):rawArgs <- getArgs
  let
    rcbOpt = ConnOption 50000 30 480 bufSiz bufSiz bufSiz

  args <- parseArg rawArgs
  case args of
    Usage u -> putStrLn u
    action@(ForwardLite {..}) -> do
      forwardLite rcbOpt action
    action@(PunchForward {..}) -> do
      broker <- BH.newBroker Config.httpBroker pfPeerId
      punchForward rcbOpt broker action

forwardLite rcbOpt (ForwardLite { flAction = Serve, ..}) = do
  (serverSock, _) <- mkBoundUdpSock $ Just (fromIntegral flListenPort)
  (_, fromAddr) <- B.recvFrom serverSock kRecvSize
  rawPeer <- mkRawPeer serverSock fromAddr kRecvSize
  let SockAddrInet connPort _ = flConnAddr
  runFwdAction Remote (fromIntegral connPort) $ newRcbFromPeer rcbOpt rawPeer

forwardLite rcbOpt (ForwardLite { flAction = Connect, ..}) = do
  (clientSock, _) <- mkBoundUdpSock Nothing
  rawPeer <- mkRawPeer clientSock flConnAddr kRecvSize
  runFwdAction Local flListenPort $ newRcbFromPeer rcbOpt rawPeer

punchForward rcbOpt broker (PunchForward { pfServiceAction = Serve, .. }) = do
  BH.bind broker
  forever $ do
    eiSockAddr <- try (BH.accept broker)
    case eiSockAddr of
      Left (e :: SomeException) -> putStrLn $ "[main.accept] " ++ show e
      Right sockAddr -> do
        putStrLn "[main] before punchSock"
        mbRawPeer <- SP.punchSock pfPeerId sockAddr punchTimeout
        case mbRawPeer of
          Nothing ->
            putStrLn "[main] punchSock timeout"
          Just rawPeer -> do
            putStrLn "[main] punchSock ok"
            void $ async $ do
              putStrLn "[main] fwdloop starting..."
              runFwdAction pfFwdAction pfFwdPort $
                newRcbFromPeer rcbOpt rawPeer
              putStrLn "[main] fwdloop done..."

punchForward rcbOpt broker (PunchForward { pfServiceAction = Connect, ..}) = do
  mbSock <- BH.connect broker
  case mbSock of
    Nothing -> do
      putStrLn "[main.connect] refused"
      return ()
    Just sockAddr -> do
      putStrLn "[main] before punchSock"
      mbRawPeer <- SP.punchSock pfPeerId sockAddr punchTimeout
      case mbRawPeer of
        Nothing -> do
          putStrLn "[main] punchSock timeout"
        Just rawPeer -> do
          putStrLn "[main] punchSock ok"
          runFwdAction pfFwdAction pfFwdPort $
            newRcbFromPeer rcbOpt rawPeer
          putStrLn "[main] finished one rcb"

runFwdAction :: Peer p => ForwardAction -> Int -> IO p -> IO ()
runFwdAction Local = serveLocalRequest
runFwdAction Remote = connectToDest

