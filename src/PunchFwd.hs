import Control.Monad (forever)
import Network.Socket (withSocketsDo)
import Control.Concurrent.Async (async)
import Control.Concurrent.MVar
import System.Environment
import Pipes (runEffect, (>->))

import qualified Config
import qualified Network.Punch.Peer.Simple as SP
import Network.Punch.Peer.Reliable
import Network.Punch.Peer.PortFwd
import Network.Punch.Peer.Types

import Network.Punch.Broker.Http

main = withSocketsDo $ do
  let rcbOpt = ConnOption 50000 7 480

  args <- getArgs
  eiF <- case args of
    ["--listen", port] ->
      return $ Right ("L", (serveLocalRequest (read port)))
    ["--connect", port] ->
      return $ Right ("C", (connectToDest (read port)))
    _ ->
      return $ Left "usage: [program] [--listen port | --connect port]"

  case eiF of
    Left err -> putStrLn err
    Right act -> do
      broker <- newBroker "http://nol-m9.rhcloud.com" Config.peerId
      run rcbOpt Config.peerId broker act
 where
  run rcbOpt peerId broker ("L", onRcb) = do
    bind broker
    forever $ do
      sockAddr <- accept broker
      rawPeer <- SP.punchSock peerId sockAddr
      onRcb =<< newRcbFromPeer rcbOpt rawPeer
  run rcbOpt peerId broker ("C", onRcb) = do
    mbSock <- connect broker
    case mbSock of
      Nothing -> do
        putStrLn "[main.connect] refused"
        return ()
      Just sockAddr -> do
        rawPeer <- SP.punchSock peerId sockAddr
        onRcb =<< newRcbFromPeer rcbOpt rawPeer

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

