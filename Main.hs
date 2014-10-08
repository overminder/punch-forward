import Network.Socket
import System.Environment

import qualified Network.PunchForward.Config as Config
import qualified Network.PunchForward.Protocol.SamePort as SP
import qualified Network.PunchForward.RunLocal as L
import qualified Network.PunchForward.RunRemote as R

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

