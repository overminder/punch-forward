{-# LANGUAGE ScopedTypeVariables, RecordWildCards #-}

module Protocol.Exchange (
  PacketType(..),
  startClient,
  startServer
) where

import Data.IORef
import Control.Exception
import Control.Applicative
import Control.Monad
import qualified Data.Map as M
import Network.Socket
import Network.BSD
import Text.Read
import Text.Printf

-- The exchange protocol is used to let two clients know each other's
-- public ip and port. It should be run on a public server.
--
-- XXX: this is just an unreliable protoype.

data Packet
  = Packet {
    pktType :: PacketType,
    pktPeerId :: String,
    pktPubAddr :: String,
    pktPrivAddr :: String
  }
  deriving (Show)

encodePacket :: Packet -> String
encodePacket (Packet {..})
  = show (show pktType, pktPeerId, pktPubAddr, pktPrivAddr)

decodePacket :: String -> Packet
decodePacket xs = Packet ty cid sPubAddr sPrivAddr
 where
  ty = readOrError "decodePacket" sTy
  (sTy, cid, sPubAddr, sPrivAddr) = readOrError "decodePacket" xs

readOrError :: Read a => String -> String -> a
readOrError err xs = maybe (error err) id $ readMaybe xs 

encodeAddr :: SockAddr -> String
encodeAddr (SockAddrInet localPort localAddr)
  = show localAddr ++ ":" ++ show localPort

decodeAddr :: String -> SockAddr
decodeAddr xs = SockAddrInet (fromIntegral port) addr
 where
  (sAddr, _:sPort) = span (/= ':') xs
  port = readOrError "decodeAddr" sPort :: Int
  addr = readOrError "decodeAddr" sAddr

data PacketType
  = Listen
  | Connect
  deriving (Show, Eq, Ord, Read)

bindUDPSock :: Int -> IO Socket
bindUDPSock port = do
  s <- socket AF_INET Datagram defaultProtocol
  localhost <- hostAddress <$> getHostByName "192.168.2.3"
  -- ^ Better use INADDR_ANY
  bindSocket s (SockAddrInet (fromIntegral port) localhost)
  return s

startClient
  :: (String, Int)
  -- ^ Exchange server's hostname and port
  -> PacketType
  -- ^ Connect or Listen
  -> String
  -- ^ Client Id
  -> IO (SockAddr, Socket)
  -- ^ Established and hole punched connection.
startClient (serverHostName, serverPort) ty cid = do
  s <- bindUDPSock 0
  localAddr <- getSocketName s

  [serverHost] <- hostAddresses <$> getHostByName serverHostName
  let
    serverAddr = SockAddrInet (fromIntegral serverPort) serverHost
    pkt = Packet ty cid "" $ encodeAddr localAddr
    -- ^ XXX: hack

  sendTo s (encodePacket pkt) serverAddr

  let
    readServerReply = do
      (got, _, who) <- recvFrom s 512
      putStrLn $ "readServerReply -> " ++ show got
      if who /= serverAddr
        then readServerReply
        else return got

  got <- readServerReply
  -- ^ The other client's addresses
  let peerPkt = decodePacket got
      pubAddr = decodeAddr (pktPubAddr peerPkt)
      privAddr = decodeAddr (pktPrivAddr peerPkt)

  sendTo s cid pubAddr
  sendTo s cid privAddr
  -- ^ Punch

  let
    readPeerReply = do
      (got, _, who) <- recvFrom s 512
      if got == cid && who == pubAddr
        then return pubAddr
        else if got == cid && who == privAddr
          then return privAddr
          else readPeerReply

  peerAddr <- readPeerReply
  return (peerAddr, s)

startServer
  :: Int
  -- ^ Port
  -> IO ()
startServer port = do
  s <- bindUDPSock port
  clients <- newIORef M.empty
  forever $ do
    (got, _, who) <- recvFrom s 512
    eiPkt <- try $ return $ decodePacket got
    case eiPkt of
      Left (e :: SomeException) -> return ()
      Right pktWithoutPub -> do
        let pkt = pktWithoutPub { pktPubAddr = encodeAddr who }
        printf "[Server] %s\n" (show pkt)
        mbPending <- M.lookup (pktPeerId pkt) <$> readIORef clients
        let
          onPairing = do
            let Just pending = mbPending
            modifyIORef clients $ M.delete (pktPeerId pkt)
            sendTo s (encodePacket pending) (decodeAddr (pktPubAddr pkt))
            sendTo s (encodePacket pkt) (decodeAddr (pktPubAddr pending))
            return ()

        case (pktType pkt, pktType <$> mbPending) of
          (Listen, Just Connect) -> onPairing
          (Connect, Just Listen) -> onPairing
          _ -> do
            -- XXX: dup udp msg will overwrite!
            modifyIORef clients $ M.insert (pktPeerId pkt) pkt

