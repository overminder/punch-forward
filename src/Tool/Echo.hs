module Tool.Echo where

import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as BU8
import Pipes
import Data.Time
import Data.IORef
import Text.Printf
import Control.Concurrent hiding (yield)
import System.Timeout

-- Used to check the status of the connection (latency, drop rate etc)
-- Two kinds of echoing here. One is through raw UDP and the other is through
-- RUDP.

runEchoClient
  :: Producer B.ByteString IO ()
  -> Consumer B.ByteString IO ()
  -> IO ()
runEchoClient pktIn pktOut = once 0
 where
  onceInterval = fromIntegral $ floor 8e5
  timeoutMs = fromIntegral $ floor 5e6
  once :: Int -> IO ()
  once i = do
    let pkt = BU8.fromString (show i)
    runEffect $ yield pkt >-> pktOut
    (ok, timeUsed, nTries) <- expectWithTimeout pkt onceInterval pktIn
    let timeUsedF = (fromIntegral timeUsed / 1e6) :: Double
    if ok
      then printf "udp_seq=%d udp_tries=%d time=%.3f ms\n" i nTries timeUsedF
      else printf "receive time out (udp_tries=%d)\n" nTries
    threadDelay (onceInterval - timeUsed)
    once $! i + 1

expectWithTimeout
  :: (Eq a)
  => a
  -> Int
  -> Producer a IO ()
  -> IO (Bool, Int, Int)
expectWithTimeout a timeoutMs prod = do
  t0 <- getCurrentTime
  nTriesRef <- newIORef 0 :: IO (IORef Int)
  mbRes <- timeout timeoutMs $ loop 0 prod nTriesRef
  nTries <- readIORef nTriesRef
  t1 <- getCurrentTime
  let dt = floor $ (t1 `diffUTCTime` t0 * 1e6)
  return $ (maybe False (const True) mbRes, dt, nTries)
 where
  loop nTries p nTriesRef = do
    eiRes <- next p
    writeIORef nTriesRef nTries
    case eiRes of
      Left () -> error "expectWithTimeout: remote closed?"
      Right (a', p') -> if a' == a
        then return ()
        else loop (nTries + 1) p' nTriesRef

-- LOL
runEchoServer pktIn pktOut = runEffect $ pktIn >-> pktOut

