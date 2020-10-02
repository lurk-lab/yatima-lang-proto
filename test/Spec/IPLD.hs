{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
module Spec.IPLD where

import           Codec.Serialise
import           Codec.Serialise.Decoding
import           Codec.Serialise.Encoding

import           Control.Monad.Except

import           Data.ByteString                      (ByteString)
import qualified Data.ByteString                      as BS
import qualified Data.ByteString.Lazy                 as BSL
import qualified Data.Map                             as M
import           Data.Text                            (Text)
import qualified Data.Text                            as T

import           Language.Yatima.CID
import           Language.Yatima.IPLD
import           Language.Yatima.Term
import           Language.Yatima.Uses

import           Test.Hspec
import           Test.QuickCheck
import           Test.QuickCheck.Gen
import           Test.QuickCheck.Instances.ByteString
import           Test.QuickCheck.Instances.Text

instance Arbitrary CID where
  arbitrary = makeCID <$> (arbitrary :: Gen ByteString)

deriving instance Bounded Uses

instance Arbitrary Uses where
  arbitrary = arbitraryBoundedEnum

instance Arbitrary Tree where
  arbitrary = oneof
    [ Vari <$> arbitrary
    , Link <$> arbitrary
    , Bind <$> arbitrary
    , do
        n <- (\n -> (n * 2) `div` 3) <$> getSize
        i <- choose (0,n)
        c <- name_gen
        ts <- resize n $ vector i
        return $ Ctor c (fromIntegral i) ts
    ]

instance Arbitrary Meta where
  arbitrary = Meta <$> arbitrary

instance Arbitrary TreeDef where
  arbitrary = TreeDef <$> arbitrary <*> arbitrary

deriving instance Eq TreeDef

instance Arbitrary MetaDef where
  arbitrary = MetaDef <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

deriving instance Eq MetaDef

instance Arbitrary Package where
  arbitrary = Package <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

prop_serial :: (Eq a, Serialise a) => a -> Bool
prop_serial x = let s = serialise x in 
  case (deserialiseOrFail s) of
    Left _   -> False
    Right x' -> x == x' && (serialise x' == s)

test_defs :: (Index,Cache)
test_defs =
  let trm = Lam "A" (Lam "x" (Var "x"))
      typ = All "" "A" Many Any (All "" "x" Many (Var "A") (Var "A"))
      def = Def "id" "" trm typ
      Right (cid, cache) = runExcept (insertDef def M.empty M.empty)
   in (M.singleton "id" cid, cache)

test_index = fst test_defs
test_cache = snd test_defs

name_gen :: Gen Text
name_gen = do
  a <- elements $ ['A'..'Z'] ++ ['a'..'z']
  n <- choose (0,100) :: Gen Int
  return $ T.cons a (T.pack $ show n)

term_gen :: [Name] -> Gen Term
term_gen ctx = frequency
  [ (100,Var <$> elements ctx)
  , (100,Ref <$> elements (M.keys test_index))
  , (100, return Any)
  , (50, (name_gen >>= \n -> Lam n <$> term_gen (n:ctx)))
  , (50, App <$> term_gen ctx <*> term_gen ctx)
  , (50, Ann <$> term_gen ctx <*> term_gen ctx)
  , (33, (name_gen >>= \s -> name_gen >>= \n -> 
            All s n <$> arbitrary <*> term_gen ctx <*> term_gen (n:s:ctx)))
  , (33, (name_gen >>= \n -> 
            Let n <$> arbitrary <*> term_gen ctx <*> term_gen (n:ctx)
                  <*> term_gen (n:ctx)))
  ]

instance Arbitrary Term where
  arbitrary = term_gen ["test"]

prop_separate :: Term -> Bool
prop_separate t = either (const False) id (runExcept $ go t)
  where
    go :: Term -> Except IPLDErr Bool
    go term = do
      (tree,meta) <- termToTree "test" term test_index test_cache
      term'    <- treeToTerm tree meta
      (tree',meta') <- termToTree "test" term' test_index test_cache
      return $ term == term' && tree == tree' && meta == meta'

spec :: SpecWith ()
spec = do
  describe "Checking serialisation correctness: `x == deserialise (serialise x)`" $ do
    it "Cid"  $ property $ prop_serial @CID
    it "Meta" $ property $ prop_serial @Meta
    it "Anon" $ property $ prop_serial @Tree
    it "TreeDef" $ property $ prop_serial @TreeDef
    it "MetaDef" $ property $ prop_serial @MetaDef
    it "Package" $ property $ prop_serial @Package
  describe "Checking metadata separation correctness" $
    it "x == merge (separate x)" $ property prop_separate
