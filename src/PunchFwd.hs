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

rcbFromPeer rcbOpt peer = do
  rcbRef <- newRcb rcbOpt
  rcb <- readMVar rcbRef
  let (bsFromRcb, bsToRcb) = transportsForRcb rcbRef
  async $ runEffect $ fromPeer peer >-> bsToRcb
  async $ runEffect $ bsFromRcb >-> toPeer peer
  return rcbRef

main = withSocketsDo $ do
  let rcbOpt = ConnOption 10000 20 480
  args <- getArgs
  f <- case args of
    ["--listen", port] ->
      return $ serveLocalRequest (read port)
    ["--connect", port] ->
      return $ connectToDest (read port)
    _ -> return $ \ _ ->
      putStrLn "usage: [program] [--listen port | --connect port]"

  uPeer <- SP.punch Config.peerId Config.simplePort Config.simpleRemote
  rcbRef <- rcbFromPeer rcbOpt uPeer
  f rcbRef

