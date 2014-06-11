module Util where

import Control.Monad
import Pipes
import qualified Data.ByteString as B

cutBsTo :: Monad m => Int -> Pipe B.ByteString B.ByteString m ()
cutBsTo n = forever $ do
  bs <- await
  mapM_ yield (cut bs)
 where
  cut bs
    | B.length bs <= n = [bs]
    | otherwise = B.take n bs : cut (B.drop n bs)
