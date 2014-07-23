import Network.Socket
import System.Environment

import qualified Network.PunchForward.RunLocal as L
import qualified Network.PunchForward.RunRemote as R

main = withSocketsDo $ do
  args <- getArgs
  case args of
    ["-r"] -> R.run
    ["-l"] -> L.run
    _ -> putStrLn "usage: [program] [-r|-l]"

