module Network.Punch.Peer.PortFwd.Local where

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
  let (serverHost, serverPort) = Config.exchangeServer
  runWithAddrSock =<<
    startClient (serverHost, serverPort) Connect Config.peerId

runWithAddrSock (addr, sock) = do
  pipe <- mkPacketPipe addr 512 sock
  (bsIn, rawBsOut) <- establish pipe "Client"
  let bsOut = cutBsTo 300 >-> P.toOutput rawBsOut
  simpleL2RForwardOnLocal Config.localPort (P.fromInput bsIn, bsOut)
