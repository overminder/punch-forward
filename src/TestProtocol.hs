{-# LANGUAGE RecordWildCards, DeriveDataTypeable, ScopedTypeVariables,
    OverloadedStrings #-}

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Monad hiding (mapM)
import Pipes
import qualified Pipes.Concurrent as P
import System.Random.MWC
import Test.QuickCheck
import Test.QuickCheck.Instances
import Test.QuickCheck.Monadic

import Protocol

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
          -- Keep it
          diceVal2 <- uniform uoRandGen :: IO Double
          let
            delay = diceVal2 * fromIntegral uoMaxDelay
          threadDelay (floor delay)
          void $ atomically $ P.send thingOut thing
        else
          return ()
  return (thingIn, thingOut)

testReliable = monadicIO $ do
  --bss <- pick $ replicateM 100 arbitrary
  let bss = ["a", "b", "c"]
  run $ do
    -- Out and In from the point of the network interface
    (remotePktOutR, remotePktInR) <- P.spawn P.Unbounded
    (remotePktOutW, remotePktInW) <- P.spawn P.Unbounded
    (localPktOutR, localPktInR) <- P.spawn P.Unbounded
    (localPktOutW, localPktInW) <- P.spawn P.Unbounded

    localT <- async $ do
      (localBsIn, localBsOut) <- establish (localPktInR, localPktOutW)
      results <- forM bss $ \ bs -> atomically $ do
        P.send localBsOut bs
        Just bs' <- P.recv localBsIn
        return $ bs == bs'
      return $ all id results

    remoteT <- async $ do
      (remoteBsIn, remoteBsOut) <- establish (remotePktInR, remotePktOutW)
      -- remote is an echo server
      runEffect $ P.fromInput remoteBsIn >-> P.toOutput remoteBsOut

    wait localT

main = do
  quickCheck testReliable
