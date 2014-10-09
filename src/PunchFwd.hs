import Network.Socket
import System.Environment

import qualified Config
import qualified Network.Punch.Peer.Simple as SP
import qualified Network.Punch.Peer.PortFwd.Local as L
import qualified Network.Punch.Peer.PortFwd.Remote as R

main = withSocketsDo $ do
  args <- getArgs
  case args of
    ["-r"] -> R.run
    ["-l"] -> L.run
    ["--rs"] ->
      R.runWithAddrSock =<<
        SP.punch Config.peerId Config.simplePort Config.simpleLocal
    ["--ls"] ->
      L.runWithAddrSock =<<
        SP.punch Config.peerId Config.simplePort Config.simpleRemote
    _ -> putStrLn "usage: [program] [-r|-l]"

