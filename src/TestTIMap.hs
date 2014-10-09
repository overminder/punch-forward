
import Test.QuickCheck
import Test.QuickCheck.Instances

import qualified Network.Punch.Util.TIMap as TM
import qualified Data.Map as M

propInsertDelEmpty :: [Int] -> [Char] -> [String] -> Bool
propInsertDelEmpty ks1 ks2 vs = if m' == TM.empty then True else error errMsg
 where
  errMsg = show m' ++ " != TM.empty"
  kvs = zip (zip ks1 ks2) vs
  m = TM.fromList kvs
  m' = foldr TM.delete m (map fst kvs)

propCheckInsert :: [Int] -> [Char] -> [String] -> Bool
propCheckInsert ks1 ks2 vs = fst (foldr once (True, TM.empty) kvs)
 where
  once ((k1, k2), v) (prevRes, m0) = (prevRes && mbVA == justV &&
                                      mbV1 == justV && mbV2 == justV,
                                      m1)
   where
    m1 = TM.insert (k1, k2) v m0
    justV = Just v
    mbVA = TM.lookupA (k1, k2) m1
    mbV1 = M.lookup k2 $ TM.lookup1 k1 m1
    mbV2 = M.lookup k1 $ TM.lookup2 k2 m1
  kvs = zip (zip ks1 ks2) vs

main = do
  quickCheck propInsertDelEmpty
  quickCheck propCheckInsert

