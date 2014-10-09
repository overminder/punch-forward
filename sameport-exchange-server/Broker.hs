module Broker where

import Data.Time
import Control.Applicative
import Control.Concurrent
import Control.Monad
import Control.Concurrent.Async
import Control.Concurrent.MVar
import qualified Data.Map as M
import Network.Socket
import System.Timeout
import Text.Printf

data ErrorCode
  = AddrInUse
  | NotBound
  | Timeout
  | NoAcceptor
  | AlreadyAccepting
  deriving (Show, Read)

type VAddr = String
data Listener
  = Listener {
    lsExpiry :: UTCTime,
    lsHost :: HostAddress,
    -- ^ Is this necessary?
    lsAcceptChan :: MVar (MVar SockAddr, MVar SockAddr)
  }

data Broker
  = Broker {
    brListeners :: MVar (M.Map VAddr Listener)
  }

new :: IO Broker
new = do
  broker <- Broker <$> newMVar M.empty
  startReaper broker
  return broker

bindListen
  :: Broker
  -> Int
  -- Maximum inactive (e.g., no accept call) time allowed before disposal
  -> VAddr
  -- Virtual address to bind to
  -> HostAddress
  -- Physical address for the binder
  -> IO (Either ErrorCode ())
bindListen Broker {..} aliveMicros vAddr serverHost = do
  now <- getCurrentTime
  let expiry = addUTCTime (fromIntegral (aliveMicros `div` 1000000)) now
  addrChan <- newEmptyMVar
  modifyMVar brListeners $ \ listeners -> do
    case M.lookup vAddr listeners of
      Nothing -> do
        let
          newListeners =
            M.insert vAddr (Listener expiry serverHost addrChan) listeners
        -- XXX: Return a security token?
        return (newListeners, Right ())
      Just _ ->
        return (listeners, Left AddrInUse)

accept
  :: Broker
  -> Int
  -> VAddr
  -> SockAddr
  -> IO (Either ErrorCode SockAddr)
accept Broker {..} waitMicros vAddr physAddr = do
  putStrLn $ "accept: first transaction " ++ show physAddr
  eiRes <- withMVar brListeners $ \ listeners -> do
    case M.lookup vAddr listeners of
      Nothing ->
        return (Left NotBound)
      Just (Listener {..}) -> do
        serverAddrChan <- newMVar physAddr
        clientAddrChan <- newEmptyMVar
        putOk <- tryPutMVar lsAcceptChan (serverAddrChan, clientAddrChan)
        if not putOk
          then return (Left AlreadyAccepting)
          -- | Need to break out the lock on brListeners since otherwise
          -- the client connection will never proceed.
          else return $ Right $ do
            mbClientAddr <- timeout waitMicros $ takeMVar clientAddrChan
            putStrLn $ "accept: timeout reached."
            case mbClientAddr of
              Nothing -> do
                -- Timeout before any client has connected.
                takeMVar lsAcceptChan
                return (Left Timeout)
              Just clientAddr ->
                return (Right clientAddr)
  case eiRes of
    Left e -> do
      putStrLn $ "accept: second transaction is not executed"
      return (Left e)
    Right runRest -> do
      putStrLn $ "accept: second transaction " ++ show physAddr
      runRest

connect :: Broker -> VAddr -> SockAddr -> IO (Either ErrorCode SockAddr)
connect (Broker {..}) vAddr clientAddr =
  withMVar brListeners $ \ listeners -> do
    case M.lookup vAddr listeners of
      Nothing ->
        return (Left NotBound)
      Just (Listener {..}) -> do
        mbChans <- tryTakeMVar lsAcceptChan
        case mbChans of
          Nothing ->
            return (Left NoAcceptor)
          Just (serverAddrChan, clientAddrChan) -> do
            serverAddr <- takeMVar serverAddrChan
            putMVar clientAddrChan clientAddr
            return (Right serverAddr)
--

startReaper = async . forever . reap
reap Broker {..} = do
  threadDelay (60 * 1000000)
  now <- getCurrentTime
  modifyMVar_ brListeners $ \ m -> do
    let m' = M.filter ((now <) . lsExpiry) m
    printf "[Reaper] %d -> %d\n" (M.size m) (M.size m')
    return m'

