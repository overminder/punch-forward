{-# LANGUAGE RecordWildCards #-}

import Control.Monad (forever, void)
import Control.Exception (try, SomeException)
import Network.Socket (withSocketsDo)
import Control.Concurrent.Async (async)
import Control.Concurrent.MVar
import System.Environment
import System.Timeout
import Pipes (runEffect, (>->))
import Text.Read (readMaybe)

import qualified Config
import qualified Network.Punch.Peer.Simple as SP
import Network.Punch.Peer.Reliable
import Network.Punch.Peer.PortFwd
import Network.Punch.Peer.Types

import Network.Punch.Broker.Http

punchTimeout = 10000000

data Action
  = PunchForward
    { pfPeerId :: String
    , pfPunchAction :: PunchAction
    , pfFwdAction :: ForwardAction
    , pfFwdPort :: Int
    }
  | ForwardLite
    { flListenPort :: Int
    , flConnPort :: Int
    }
  | Usage String
  deriving (Show, Eq)

data PunchAction = Serve | Connect
  deriving (Show, Read, Eq)

data ForwardAction = Local | Remote
  deriving (Show, Read, Eq)

-- "ssh -L|-R _:localhost:port"
parseArg [ readMaybe -> Just punchAction
         , peerId
         , readMaybe -> Just fwdAction
         , readMaybe -> Just port]
  = PunchForward peerId punchAction fwdAction port

parseArg [ "ServeLite"
         , readMaybe -> Just listenPort
         , readMaybe -> Just connPort]
  = ForwardLite
    { flListenPort = listenPort
    , flConnPort = connPort
    }

parseArg _ = Usage $ unlines errMsg
 where
  errMsg = [ "usage: [program] OPTIONS"
           , " where OPTIONS can be:"
           , "  ( 'Serve' | 'Connect' ) PEER_ID ( 'Local' | 'Remote' ) PORT"
           , "  'ServeLite' LISTEN_PORT CONNECT_PORT"
           ]

main = withSocketsDo $ do
  let rcbOpt = ConnOption 50000 8 480 1000 1000 1000

  args <- getArgs
  case parseArg args of
    Usage u -> putStrLn u
    action@(ForwardLite {..}) -> do
      forwardLite rcbOpt action
    action@(PunchForward {..}) -> do
      broker <- newBroker Config.httpBroker pfPeerId
      punchForward rcbOpt broker action

forwardLite rcbOpt (ForwardLite {..}) = error "Not implemented"

punchForward rcbOpt broker (PunchForward { pfPunchAction = Serve, .. }) = do
  bind broker
  forever $ do
    eiSockAddr <- try (accept broker)
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

punchForward rcbOpt broker (PunchForward { pfPunchAction = Connect, ..}) = do
  mbSock <- connect broker
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
