{-# LANGUAGE ViewPatterns #-}
module Network.PunchForward.Protocol.SamePort (
  punch
) where

import Control.Applicative
import Network.Socket
import Network.BSD

data Greeting
  = HowAreYou { gConnId :: String }
  | FineThanksAndYou { gConnId :: String }
  deriving (Show, Read, Eq)

encodeGreeting :: Greeting -> String
encodeGreeting = show

connIdMismatch connId g = gConnId g /= connId

-- For NATs that don't translate port numbers.

punch
  :: String
  -- ^ The connection identifier
  -> Int
  -- ^ The local port to bind to
  -> (String, Int)
  -- ^ The remote server address
  -> IO (SockAddr, Socket)
punch connId localPort (remoteHostName, remotePort) = do
  s <- socket AF_INET Datagram defaultProtocol
  --localhost <- hostAddress <$> getHostByName "192.168.2.3"
  -- ^ Better use INADDR_ANY
  bindSocket s (SockAddrInet (fromIntegral localPort) iNADDR_ANY)
  (remoteHost:_) <- hostAddresses <$> getHostByName remoteHostName
  let remoteAddr = SockAddrInet (fromIntegral remotePort) remoteHost

  -- Handshake: first message
  sendTo s (encodeGreeting $ HowAreYou connId) remoteAddr

  let
    readReply = do
      (read -> reply, _, who) <- recvFrom s 512
      putStrLn $ "punch.recv: Got " ++ show reply ++ " from " ++ show who
      if connIdMismatch connId reply
        then do
          putStrLn "punch.recv: connId mismatch, reply"
          readReply
        else case reply of
          HowAreYou connId' -> do
            putStrLn "punch.recv: sending FineThanksAndYou"
            sendTo s (encodeGreeting $ FineThanksAndYou connId) remoteAddr
            return ()
          FineThanksAndYou connId' ->
            putStrLn "punch.recv: handshake finished"
  readReply
  return (remoteAddr, s)
