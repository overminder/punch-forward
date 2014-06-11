{-# LANGUAGE RecordWildCards, ScopedTypeVariables, OverloadedStrings #-}

import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as BU8
import Control.Applicative
import Control.Monad
import Control.Concurrent.Async
import Pipes
import qualified Pipes.Concurrent as P
import qualified Pipes.Prelude as P
import Network.Socket
import qualified Network.Socket.ByteString as SB
import Data.Bits
import qualified Data.Serialize as S

import Protocol.Exchange
import Protocol.RUDP

putPacket :: Packet -> S.Put
putPacket (Packet {..}) = do
  S.put pktSeqNo
  S.put pktAckNo
  S.put $ foldFlags pktFlags
  S.put pktPayload

getPacket :: S.Get Packet
getPacket = Packet <$> S.get <*> S.get <*> (unfoldFlags <$> S.get) <*> S.get

foldFlags :: Enum a => [a] -> Int
foldFlags = foldr (flip setFlag) 0

unfoldFlags :: (Bounded a, Enum a) => Int -> [a]
unfoldFlags flag = concatMap check [minBound..maxBound]
 where
  check a = if hasFlag flag a then [a] else []

hasFlags :: Enum a => Int -> [a] -> Bool
hasFlags flag xs = foldr combine True xs
 where
  combine x out = hasFlag flag x && out

hasFlag :: Enum a => Int -> a -> Bool
hasFlag flag a = testBit flag (fromEnum a)

setFlag :: Enum a => Int -> a -> Int
setFlag flag a = setBit flag (fromEnum a)

delFlag :: Enum a => Int -> a -> Int
delFlag flag a = clearBit flag (fromEnum a)

mkPacketPipe
  :: SockAddr
  -> Int
  -> Socket
  -> IO (P.Input Packet, P.Output Packet)
mkPacketPipe addr bufsize s = do
  (pktWOut, pktWIn) <- P.spawn P.Unbounded
  (pktROut, pktRIn) <- P.spawn P.Unbounded

  let
    toS = forever $ do
      bs <- await
      liftIO $ SB.sendTo s bs addr

    fromS = forever $ do
      (bs, who) <- liftIO $ SB.recvFrom s bufsize
      if who /= addr
        then return ()
        else yield bs

    serialized = forever $ do
      x <- await
      let bs = S.runPut (putPacket x)
      yield bs

    deserialized = forever $ do
      bs <- await
      let eiX = S.runGet getPacket bs
      case eiX of
        Left _ -> return ()
        Right x -> yield x

  async $ runEffect $ P.fromInput pktRIn >-> serialized >-> toS
  async $ runEffect $ fromS >-> deserialized >-> P.toOutput pktWOut

  return (pktWIn, pktROut)

cutBsTo :: Monad m => Int -> Pipe B.ByteString B.ByteString m ()
cutBsTo n = forever $ do
  bs <- await
  mapM_ yield (cut bs)
 where
  cut bs
    | B.length bs <= n = [bs]
    | otherwise = B.take n bs : cut (B.drop n bs)

main = do
  let
    serverPort = 10005
    serverHost = "ihome.ust.hk"
  --ts <- async $ startServer serverPort
  tc1 <- async $ do
    (a2, s1) <- startClient (serverHost, serverPort) Listen "foo"
    p1 <- mkPacketPipe a2 512 s1
    (bsIn, rawBsOut) <- establish p1 "server"
    let bsOut = cutBsTo 512 >-> P.toOutput rawBsOut
    runEffect $ P.fromInput bsIn >-> bsOut
    -- ^ Echo server

  tc2 <- async $ do
    (a1, s2) <- startClient (serverHost, serverPort) Connect "foo"
    p2 <- mkPacketPipe a1 512 s2
    (bsIn, rawBsOut) <- establish p2 "client"
    let bsOut = cutBsTo 512 >-> P.toOutput rawBsOut
    runEffect $ do
      each (map BU8.fromString $ words "Hello, world!") >-> bsOut
      P.fromInput bsIn >-> P.show >-> P.stdoutLn

  wait tc1
  wait tc2

