-- For NATs that keep the same port numbers for translated addresses.

module Network.Punch.Peer.Simple (
  punchSock,
  kRecvSize
) where

import Control.Applicative
import qualified Data.ByteString.UTF8 as B
import Network.Socket
import Network.BSD
import System.Timeout (timeout)

import Network.Punch.Peer.Types
import Network.Punch.Util (sockAddrFor)

data Greeting
  = HowAreYou { gConnId :: String }
  | FineThanksAndYou { gConnId :: String }
  deriving (Show, Read, Eq)

encodeGreeting :: Greeting -> B.ByteString
encodeGreeting = B.fromString . show

connIdMismatch connId g = gConnId g /= connId

kRecvSize = 512

{-
punch
  :: String
  -- ^ The connection identifier
  -> Int
  -- ^ The local port to bind to
  -> (String, Int)
  -- ^ The remote server address
  -> IO RawPeer
punch connId localPort (remoteHostName, remotePort) = do
  s <- socket AF_INET Datagram defaultProtocol
  bindSocket s =<< sockAddrFor Nothing localPort
  remoteAddr <- sockAddrFor (Just remoteHostName) remotePort
  punchSock connId (s, remoteAddr)
 -}

punchSock
  :: String 
  -- ^ The connection identifier
  -> (Socket, SockAddr)
  -- ^ The bound socket to use
  -> Int
  -- ^ Timeout in micro
  -> IO (Maybe RawPeer)
punchSock connId (s, remoteAddr) timeoutMicro = do
  peer <- mkRawPeer s remoteAddr kRecvSize
  -- Handshake: first message
  sendPeer peer (encodeGreeting $ HowAreYou connId)

  let
    readReply = do
      Just (read . B.toString -> reply) <- recvPeer peer
      putStrLn $ "punch.recv: Got " ++ show reply ++
                 " from " ++ show remoteAddr
      if connIdMismatch connId reply
        then do
          putStrLn "punch.recv: connId mismatch, reply"
          readReply
        else case reply of
          HowAreYou connId' -> do
            putStrLn "punch.recv: sending FineThanksAndYou"
            sendPeer peer (encodeGreeting $ FineThanksAndYou connId)
            return ()
          FineThanksAndYou connId' ->
            putStrLn "punch.recv: handshake finished"
  mbOk <- timeout timeoutMicro $ readReply
  maybe (closePeer peer >> return Nothing) (const $ return (Just peer)) mbOk

