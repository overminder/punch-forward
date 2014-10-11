module Network.Punch.Peer.PortFwd.Remote where

import qualified Data.ByteString as B
import Control.Applicative
import Control.Monad
import Pipes
import qualified Pipes.Concurrent as P
import Network.Socket

import Network.Punch.Broker.UDP
import Network.Punch.Peer.Reliable
import Network.Punch.Peer.PortFwd
import Network.Punch.Util
import qualified Config

run = do
  let
    (serverHost, serverPort) = Config.exchangeServer

  runWithAddrSock =<<
    startClient (serverHost, serverPort) Listen Config.peerId

runWithAddrSock (addr, sock) = do
  putStrLn "Server"
  (bsIn, rawBsOut) <- establish pipe "Server"
  let bsOut = cutBsTo 300 >-> P.toOutput rawBsOut
  simpleL2RForwardOnRemote Config.remotePort (P.fromInput bsIn, bsOut)

