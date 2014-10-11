import Control.Applicative
import Pipes
import qualified Pipes.Concurrent as P
import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Concurrent hiding (yield)
import System.Random.MWC
import Control.Monad
import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as B

import System.Environment
import Network.Punch.Peer.Reliable
import Network.Punch.Util

data UOption
  = UOption {
    uoMaxDup :: Int,
    uoMaxDelay :: Int,
    -- ^ In microsec
    uoDropRate :: Double,
    -- ^ 0-1
    uoRandGen :: GenIO
  }

mkUOption maxDup maxDelay dropRate =
  UOption maxDup maxDelay dropRate <$> createSystemRandom

startUTransport :: UOption -> RcbRef -> RcbRef -> IO ()
startUTransport (UOption {..}) localRcbRef remoteRcbRef = do
  localRcb <- readMVar localRcbRef
  remoteRcb <- readMVar remoteRcbRef
  async $ runEffect $
    fromMailbox (rcbToNic localRcb) >->
    recvAndSend (pipeWith (pprPkt "L >> R:") >->
                 toMailbox (rcbFromNic remoteRcb))
  async $ runEffect $
    fromMailbox (rcbToNic remoteRcb) >->
    recvAndSend (pipeWith (pprPkt "L << R:") >->
                 toMailbox (rcbFromNic localRcb))
  return ()
 where
  recvAndSend dst = forever $ do
    pkt <- await
    liftIO $ lossOrDup dst pkt

  lossOrDup dst pkt = do
    diceVal <- uniform uoRandGen
    if diceVal < uoDropRate
      then
        -- Drop it
        return ()
      else do
        -- Keep it.

        -- Calculate the duplication count
        dupPercent <- uniform uoRandGen :: IO Double
        let dupCount = 1 + floor (dupPercent * (fromIntegral uoMaxDup - 1))

        waitPercents <- replicateM dupCount (uniform uoRandGen) :: IO [Double]
        let
          calcWait = floor . (* (fromIntegral uoMaxDelay))
          waitMicros = map calcWait waitPercents
        -- ^ At most wait 1 second
        forM_ waitMicros $ \ waitMicro -> do
          async $ do
            threadDelay waitMicro
            runEffect $ yield pkt >-> dst

startTransport localRcbRef remoteRcbRef = do
  localRcb <- readMVar localRcbRef
  remoteRcb <- readMVar remoteRcbRef
  async $ runEffect $
    fromMailbox (rcbToNic localRcb) >->
    pipeWith (pprPkt "L >> R:") >->
    toMailbox (rcbFromNic remoteRcb)
  async $ runEffect $
    fromMailbox (rcbToNic remoteRcb) >->
    pipeWith (pprPkt "L << R:") >->
    toMailbox (rcbFromNic localRcb)
  return ()

startEcho :: RcbRef -> IO ()
startEcho rcbRef = do
  rcb <- readMVar rcbRef
  async echoOnce
  return ()
 where
  echoOnce = do
    mbBs <- recvRcb rcbRef 
    case mbBs of
      Nothing -> return ()
      Just bs -> do
        ok <- sendRcb rcbRef bs
        case ok of
          True -> echoOnce
          False -> return ()

recvAllRcb rcbRef = go []
 where
  go out = do
    got <- recvRcb rcbRef
    case got of
      Nothing -> return $ reverse out
      Just bs -> go (bs:out)

main = do
  [read -> maxDup, read -> maxDelay, read -> dropRate, read -> dataLen]
    <- getArgs
  let connOpt = ConnOption 50000 20 480
  localRcbRef <- newRcb connOpt
  remoteRcbRef <- newRcb connOpt
  uOpt <- mkUOption maxDup maxDelay dropRate
  startUTransport uOpt localRcbRef remoteRcbRef
  --startEcho remoteRcbRef
  let manyInts = [1..dataLen] :: [Int]
  True <- sendRcb localRcbRef (B.fromString $ show manyInts)
  gracefullyShutdownRcb localRcbRef
  putStrLn "send ok"
  got <- recvAllRcb remoteRcbRef
  let restored = read (B.toString $ B.concat got) :: [Int]
  print (length restored)
  --threadDelay 5000000
  return ()

pprPkt :: String -> Packet -> IO ()
--pprPkt tag pkt = putStrLn $ tag ++ " " ++ showPacket pkt
pprPkt tag pkt = return ()

