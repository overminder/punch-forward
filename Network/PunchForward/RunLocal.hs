{-# LANGUAGE RecordWildCards, ScopedTypeVariables, OverloadedStrings #-}

module Network.PunchForward.RunLocal where

import qualified Data.ByteString as B
import Control.Applicative
import Control.Monad
import Pipes
import qualified Pipes.Concurrent as P
import Network.Socket

import Network.PunchForward.Protocol.Exchange
import Network.PunchForward.Protocol.RUDP
import Network.PunchForward.Protocol.Forward
import qualified Network.PunchForward.Protocol.SamePort as SP
import Network.PunchForward.Util
import qualified Network.PunchForward.Config as Config

run = do
  let (serverHost, serverPort) = Config.exchangeServer
  runWithAddrSock =<<
    startClient (serverHost, serverPort) Connect Config.peerId

runWithAddrSock (addr, sock) = do
  pipe <- mkPacketPipe addr 512 sock
  (bsIn, rawBsOut) <- establish pipe "Client"
  let bsOut = cutBsTo 300 >-> P.toOutput rawBsOut
  simpleL2RForwardOnLocal Config.localPort (P.fromInput bsIn, bsOut)
