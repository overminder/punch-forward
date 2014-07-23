{-# LANGUAGE RecordWildCards #-}

module Network.PunchForward.TIMap where

import Data.Function
import Data.Ord
import qualified Data.Map as M

-- Two-index map.
-- Strictness here seems to be not affecting the performance.
data TIMap k1 k2 v
  = TIMap {
    tmMap1 :: !(M.Map  k1     (M.Map k2 v)),
    tmMap2 :: !(M.Map      k2 (M.Map k1 v)),
    tmMapA :: !(M.Map (k1, k2)          v)
  }
  deriving (Eq)

instance (Show k1, Show k2, Show v) => Show (TIMap k1 k2 v) where
  show x = "fromList " ++ (show . toList $ x)

empty :: (Ord k1, Ord k2) => TIMap k1 k2 v
empty = TIMap M.empty M.empty M.empty

fromList :: (Ord k1, Ord k2) => [((k1, k2), v)] -> TIMap k1 k2 v
fromList = foldr insertEntry empty
 where
  insertEntry ((k1, k2), v) m0 = insert (k1, k2) v m0

toList :: TIMap k1 k2 v -> [((k1, k2), v)]
toList = M.toList . tmMapA

elems :: TIMap k1 k2 v -> [v]
elems = M.elems . tmMapA

size = M.size . tmMapA

insert :: (Ord k1, Ord k2) => (k1, k2) -> v -> TIMap k1 k2 v -> TIMap k1 k2 v
insert (k1, k2) v (TIMap {..})
  = TIMap (M.insert k1 k1Map' tmMap1)
          (M.insert k2 k2Map' tmMap2)
          (M.insert (k1, k2) v tmMapA)
 where
  k1Map = maybe M.empty id (M.lookup k1 tmMap1)
  k1Map' = M.insert k2 v k1Map
  k2Map = maybe M.empty id (M.lookup k2 tmMap2)
  k2Map' = M.insert k1 v k2Map

delete :: (Ord k1, Ord k2) => (k1, k2) -> TIMap k1 k2 v -> TIMap k1 k2 v
delete (k1, k2) m0@(TIMap {..}) = case mbEntry of
  Nothing -> m0
  Just _ -> let k1Map = maybe M.empty id (M.lookup k1 tmMap1)
                k1Map' = M.delete k2 k1Map
                k1Action = if M.null k1Map' then M.delete k1 else M.insert k1 k1Map'
                k2Map = maybe M.empty id (M.lookup k2 tmMap2)
                k2Map' = M.delete k1 k2Map
                k2Action = if M.null k2Map' then M.delete k2 else M.insert k2 k2Map'
             in TIMap (k1Action tmMap1) (k2Action tmMap2) (M.delete (k1, k2) tmMapA)
 where
  mbEntry = lookupA (k1, k2) m0

lookup1 :: (Ord k1, Ord k2) =>  k1       -> TIMap k1 k2 v -> M.Map k2 v
lookup1 k1 m0@(TIMap {..}) = maybe M.empty id (M.lookup k1 tmMap1)

lookup2 :: (Ord k1, Ord k2) =>      k2   -> TIMap k1 k2 v -> M.Map k1 v
lookup2 k2 m0@(TIMap {..}) = maybe M.empty id (M.lookup k2 tmMap2)

lookupA :: (Ord k1, Ord k2) => (k1, k2)  -> TIMap k1 k2 v -> Maybe v
lookupA (k1, k2) m0 = M.lookup (k1, k2) (tmMapA m0)

