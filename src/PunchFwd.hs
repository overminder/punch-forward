import Control.Monad (forever, void)
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

punchTimeout = 2500000

main = withSocketsDo $ do
  let rcbOpt = ConnOption 50000 7 480

  args <- getArgs
  eiF <- case args of
    [punchAction, peerId, fwdAction, port]
      | fwdAction == "L" ->
        -- "ssh -L port:localhost:$rPort"
        return $ Right (peerId, punchAction, (serveLocalRequest (read port)))
      | fwdAction == "R" ->
        -- "ssh -R $lPort:localhost:port"
        return $ Right (peerId, punchAction, (connectToDest (read port)))
    _ ->
      return $ Left "usage: [program] [serve|connect] peerId [L|C] port"

  case eiF of
    Left err -> putStrLn err
    Right (peerId, punchAct, onRcb) -> do
      broker <- newBroker Config.httpBroker peerId
      run rcbOpt peerId broker (punchAct, onRcb)
 where
  run rcbOpt peerId broker ("serve", onRcb) = do
    bind broker
    forever $ do
      sockAddr <- accept broker
      putStrLn "[main] before punchSock"
      mbRawPeer <- timeout punchTimeout $ SP.punchSock peerId sockAddr
      case mbRawPeer of
        Nothing -> do
          putStrLn "[main] punchSock timeout"
        Just rawPeer -> do
          putStrLn "[main] punchSock ok"
          void $ async $ do
            putStrLn "[main] fwdloop starting..."
            onRcb =<< newRcbFromPeer rcbOpt rawPeer
            putStrLn "[main] fwdloop done..."

  run rcbOpt peerId broker ("connect", onRcb) = do
    mbSock <- connect broker
    case mbSock of
      Nothing -> do
        putStrLn "[main.connect] refused"
        return ()
      Just sockAddr -> do
        putStrLn "[main] before punchSock"
        mbRawPeer <- timeout punchTimeout $ SP.punchSock peerId sockAddr
        case mbRawPeer of
          Nothing -> do
            putStrLn "[main] punchSock timeout"
          Just rawPeer -> do
            putStrLn "[main] punchSock ok"
            onRcb =<< newRcbFromPeer rcbOpt rawPeer
            putStrLn "[main] finished one rcb"

main2 rcbOpt = do
  args <- getArgs
  f <- case args of
    ["--listen", port] ->
      return $ serveLocalRequest (read port)
    ["--connect", port] ->
      return $ connectToDest (read port)
    _ -> return $ \ _ ->
      putStrLn "usage: [program] [--listen port | --connect port]"

  uPeer <- SP.punch Config.peerId Config.simplePort Config.simpleRemote
  rcbRef <- newRcbFromPeer rcbOpt uPeer
  f rcbRef

