{-# LANGUAGE RecordWildCards, ScopedTypeVariables, OverloadedStrings #-}

import qualified Data.ByteString as B
import Control.Applicative
import Control.Monad
import Pipes
import qualified Pipes.Concurrent as P
import Network.Socket

import Protocol.Exchange
import Protocol.RUDP
import Protocol.Forward
import Util
import qualified Config

main = withSocketsDo $ do
  let
    (serverHost, serverPort) = Config.exchangeServer

  (addr, sock) <- startClient (serverHost, serverPort) Connect Config.peerId
  pipe <- mkPacketPipe addr 512 sock
  (bsIn, rawBsOut) <- establish pipe "Client"
  let bsOut = cutBsTo 512 >-> P.toOutput rawBsOut
  simpleL2RForwardOnLocal Config.localPort (P.fromInput bsIn, bsOut)



