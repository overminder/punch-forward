import Control.Applicative
import Control.Exception
import Control.Concurrent hiding (yield)
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Monad hiding (mapM)
import qualified Data.ByteString.UTF8 as BU8
import Pipes
import qualified Pipes.Concurrent as P
import System.Random.MWC
import Test.QuickCheck
import Test.QuickCheck.Instances
import Test.QuickCheck.Monadic
import Text.Read
import System.Environment

import Network.Punch.Peer.Reliable
import Network.Punch.Util

data UnreliableOption
  = UnreliableOption {
    uoRandGen :: GenIO,
    uoMaxDelay :: Int,
    -- ^ In microsec
    uoDropRate :: Double
    -- ^ 0-1
  }

mkUnreliablePipe
  :: UnreliableOption
  -> IO (Mailbox a)
mkUnreliablePipe (UnreliableOption {..}) = do
  (thingOut, thingIn) <- P.spawn P.Unbounded
  recvT <- async $ forever $ do
    Just thing <- atomically $ P.recv thingIn
    void $ async $ do
      -- Firstly, test if we need to drop it.
      diceVal <- uniform uoRandGen :: IO Double
      if diceVal > uoDropRate
        then do
          -- Keep it.
          -- Check if we need to duplicate it.
          dupRate <- uniform uoRandGen :: IO Double
          let
            dupNum = if dupRate > 0.9 then 2 else 1
            things = replicate dupNum thing
              
          forM_ things $ \ thing -> do
            diceVal2 <- uniform uoRandGen :: IO Double
            let
              delay = diceVal2 * fromIntegral uoMaxDelay
            async $ do
              threadDelay (floor delay)
              void $ atomically $ P.send thingOut thing
        else
          return ()
  return (thingIn, thingOut)

testEcho option = monadicIO $ do
  bss <- pick $ replicateM 100 arbitrary
  --let bss = ["Hello", "World", "Bye"]
  run $ propEcho option bss

propEcho mbOption bss = do
  let
    startTransport prod cons = case mbOption of
      Nothing -> async $ runEffect $ prod >-> cons
      Just option -> do
        (altIn, altOut) <- mkUnreliablePipe option
        async $ runEffect $ prod >-> P.toOutput altOut
        async $ runEffect $ P.fromInput altIn >-> cons
  -- R and W from the point of the network interface
  -- i.e., the NIC reads from endpoint and writes to the endpoint,
  -- so R represents the incoming packets and W represents the
  -- outgoing packets.
  (remotePktROut, remotePktRIn) <- P.spawn P.Unbounded
  (remotePktWOut, remotePktWIn) <- P.spawn P.Unbounded
  (localPktROut, localPktRIn) <- P.spawn P.Unbounded
  (localPktWOut, localPktWIn) <- P.spawn P.Unbounded

  localT <- async $ do
    (localBsIn, localBsOut) <- establish
      (localPktRIn, localPktWOut) "local"
    mapM_ (atomically . P.send localBsOut) bss
    forM_ (zip [0..] bss) $ \ (i, bs) -> do
      --putStrLn $ "sending... " ++ show i
      --atomically $ P.send localBsOut bs
      --putStrLn "receiving..."
      Just bs' <- (atomically $ P.recv localBsIn) `catch`
        \ (e :: SomeException) -> do putStrLn $ "recv failed: " ++ show e
                                     return Nothing
      --putStrLn "one iter done..."
      if bs /= bs'
        then throwIO (userError "BS comparision failed")
        else return ()
    return True

  let
    loggerPipe :: Show a => Pipe a a IO ()
    loggerPipe = forever $ do
      x <- await
      liftIO $ putStrLn $ "[Log] " ++ show x
      yield x

  remoteT <- async $ do
    (remoteBsIn, remoteBsOut) <- establish
      (remotePktRIn, remotePktWOut) "remote"
    -- remote is an echo server
    (runEffect $ P.fromInput remoteBsIn >-> P.toOutput remoteBsOut) `catch`
      \ (e :: SomeException) -> do putStrLn $ "remoteT failed: " ++ show e
                                   return ()

  startTransport (P.fromInput localPktWIn)
                 (P.toOutput remotePktROut)
  startTransport (P.fromInput remotePktWIn)
                 (P.toOutput localPktROut)

  wait localT

mkBss n = take n (repeat . BU8.fromString . show $ replicate 100 'a')

main = do
  [sDelay, sDropRate, sNumItems] <- getArgs
  rndGen <- createSystemRandom
  let
    delay = maybe 100000 id $ readMaybe sDelay
    dropRate = maybe 0.1 id $ readMaybe sDropRate
    numItems = maybe 100 id $ readMaybe sNumItems
    unreliableOption = UnreliableOption rndGen delay dropRate
    bss = mkBss numItems
    --bss = map (BU8.fromString . show) (take numItems [0..])
    --bss = map BU8.fromString $ words "Hello world, this is sparta yay huh"
  --quickCheck $ testEcho reliableOption
  --quickCheck $ testEcho unreliableOption
  ok <- propEcho (Just unreliableOption) bss
  --ok <- propEcho Nothing bss
  print ok

