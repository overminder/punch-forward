module Network.Punch.Broker.Http.Types where

import Data.Monoid
import Network.Socket
import Control.Applicative
import Data.Aeson hiding (json)

data ErrorCode
  = AddrInUse
  | NotBound
  | Timeout
  | NoAcceptor
  | AlreadyAccepting
  | WrongMethod
  | Other String
  deriving (Show, Read)

-- E.g. ('127.0.0.1', 80)
data Ipv4Addr = Ipv4Addr String Int
  deriving (Show)

data Msg
  = MsgError ErrorCode
  | MsgOk
  | MsgOkAddr Ipv4Addr
  deriving (Show)

-- Request to accept or connect to a peer.
-- Contains the port that we are using.
newtype CommRequest = CommRequest PortNumber

instance ToJSON CommRequest where
  toJSON (CommRequest port) = object ["port" .= (fromIntegral port :: Int)]

fromIpv4 :: Ipv4Addr -> IO SockAddr
fromIpv4 (Ipv4Addr host port) = SockAddrInet (fromIntegral port)
  <$> inet_addr host

toIpv4 :: SockAddr -> IO (Maybe Ipv4Addr)
toIpv4 (SockAddrInet port host) = Just
  <$> (Ipv4Addr <$> inet_ntoa host <*> pure (fromIntegral port))
toIpv4 _ = return $ Nothing

instance ToJSON Ipv4Addr where
  toJSON (Ipv4Addr host port) = object ["port" .= port, "host" .= host]

instance FromJSON Ipv4Addr where
  parseJSON (Object v) = Ipv4Addr
    <$> v .: "host"
    <*> v .: "port"

instance ToJSON ErrorCode where
  toJSON e = object $ ["code" .= errorCode] <> extra
   where
    errorCode :: String
    errorCode = case e of
      AddrInUse -> "AddrInUse"
      NotBound -> "NotBound"
      Timeout -> "Timeout"
      NoAcceptor -> "NoAcceptor"
      AlreadyAccepting -> "AlreadyAccepting"
      WrongMethod -> "WrongMethod"
      Other _ -> "Other"

    extra = case e of
      Other s -> ["extra" .= s]
      _ -> []

instance FromJSON ErrorCode where
  parseJSON (Object v) = do
    code :: String <- v .: "code"
    case code of
      "AddrInUse" -> return AddrInUse
      "NotBound" -> return NotBound
      "Timeout" -> return Timeout
      "NoAcceptor" -> return NoAcceptor
      "AlreadyAccepting" -> return AlreadyAccepting
      "WrongMethod" -> return WrongMethod
      "Other" -> Other <$> v .: "extra"
      wat -> return $ Other wat
  parseJSON _ = fail "No parse"

instance ToJSON Msg where
  toJSON (MsgError reason) =
    object ["type" .= ("error" :: String), "reason" .= reason]
  toJSON MsgOk =
    object ["type" .= ("ok" :: String)]
  toJSON (MsgOkAddr addr) =
    object ["type" .= ("okAddr" :: String), "addr" .= addr]

instance FromJSON Msg where
  parseJSON (Object v) = do
    ty <- v .: "type"
    case ty of
      ("error" :: String) ->
        MsgError <$> v .: "reason"
      "ok" ->
        return MsgOk
      ("okAddr" :: String) ->
        MsgOkAddr <$> v .: "addr"


