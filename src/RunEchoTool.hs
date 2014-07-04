import Network
import Control.Monad
import Control.Concurrent hiding (yield)
import Control.Concurrent.Async
import qualified Pipes.Concurrent as P
import Pipes
import System.Environment

import Protocol.RUDP
import Protocol.Exchange
import Tool.Echo
import Util
import qualified Config

main = withSocketsDo $ do
  [sRole, sIsRaw] <- getArgs
  let isServer = sRole == "Server"
      punchAction = if isServer then Listen else Connect
      runEcho = if isServer then runEchoServer else runEchoClient
      isRaw = read sIsRaw
      (serverHost, serverPort) = Config.exchangeServer

  (addr, sock) <- startClient (serverHost, serverPort) punchAction Config.peerId

  (bsIn, bsOut) <- if isRaw
    then return (fromUdpSocket sock addr 512, toUdpSocket sock addr)
    else do
      pipe <- mkPacketPipe addr 512 sock
      (rawBsIn, rawBsOut) <- establish pipe sRole
      let bsOut = cutBsTo 512 >-> P.toOutput rawBsOut
      return (P.fromInput rawBsIn, bsOut)

  runEcho bsIn bsOut
