{-# LANGUAGE RecordWildCards, ScopedTypeVariables, OverloadedStrings #-}

module Network.PunchForward.RunRemote where

import qualified Data.ByteString as B
import Control.Applicative
import Control.Monad
import Pipes
import qualified Pipes.Concurrent as P
import Network.Socket

import Network.PunchForward.Protocol.Exchange
import Network.PunchForward.Protocol.RUDP
import Network.PunchForward.Protocol.Forward
import Network.PunchForward.Util
import qualified Network.PunchForward.Config as Config

run = do
  let
    (serverHost, serverPort) = Config.exchangeServer

  (addr, sock) <- startClient (serverHost, serverPort) Listen Config.peerId
  pipe <- mkPacketPipe addr 512 sock
  putStrLn "Server"
  (bsIn, rawBsOut) <- establish pipe "Server"
  let bsOut = cutBsTo 300 >-> P.toOutput rawBsOut
  simpleL2RForwardOnRemote Config.remotePort (P.fromInput bsIn, bsOut)


