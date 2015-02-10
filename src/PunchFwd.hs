import Control.Monad (forever, void)
import Control.Exception (try, SomeException)
import Network.Socket (withSocketsDo)
import Control.Concurrent.Async (async)
import Control.Concurrent.MVar
import System.Environment
import System.Timeout
import Pipes (runEffect, (>->))

import qualified Config
import qualified Network.Punch.Peer.Simple as SP
import Network.Punch.Peer.Reliable
import Network.Punch.Peer.PortFwd
import Network.Punch.Peer.Types

import Network.Punch.Broker.Http

punchTimeout = 10000000

parseArg [punchAction, peerId, fwdAction, port]
  | fwdAction == "L" =
    -- "ssh -L port:localhost:$rPort"
    return (peerId, punchAction, (serveLocalRequest (read port)))
  | fwdAction == "R" =
    -- "ssh -R $lPort:localhost:port"
    return (peerId, punchAction, (connectToDest (read port)))

parseArg _ = Left "usage: [program] [serve|connect] peerId [L|R] port"

main = withSocketsDo $ do
  let rcbOpt = ConnOption 50000 8 480 100 100 100

  args <- getArgs
  case parseArg args of
    Left err -> putStrLn err
    Right (peerId, punchAct, onRcb) -> do
      broker <- newBroker Config.httpBroker peerId
      run rcbOpt peerId broker (punchAct, onRcb)
 where
  run rcbOpt peerId broker ("serve", onRcb) = do
    bind broker
    forever $ do
      eiSockAddr <- try (accept broker)
      case eiSockAddr of
        Left (e :: SomeException) -> putStrLn $ "[main.accept] " ++ show e
        Right sockAddr -> do
          putStrLn "[main] before punchSock"
          mbRawPeer <- SP.punchSock peerId sockAddr punchTimeout
          case mbRawPeer of
            Nothing ->
              putStrLn "[main] punchSock timeout"
            Just rawPeer -> do
              putStrLn "[main] punchSock ok"
              void $ async $ do
                putStrLn "[main] fwdloop starting..."
                onRcb (newRcbFromPeer rcbOpt rawPeer)
                putStrLn "[main] fwdloop done..."

  run rcbOpt peerId broker ("connect", onRcb) = do
    mbSock <- connect broker
    case mbSock of
      Nothing -> do
        putStrLn "[main.connect] refused"
        return ()
      Just sockAddr -> do
        putStrLn "[main] before punchSock"
        mbRawPeer <- SP.punchSock peerId sockAddr punchTimeout
        case mbRawPeer of
          Nothing -> do
            putStrLn "[main] punchSock timeout"
          Just rawPeer -> do
            putStrLn "[main] punchSock ok"
            onRcb (newRcbFromPeer rcbOpt rawPeer)
            putStrLn "[main] finished one rcb"

