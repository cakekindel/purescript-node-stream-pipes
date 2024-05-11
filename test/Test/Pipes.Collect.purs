module Test.Pipes.Collect where

import Prelude

import Control.Monad.Gen (chooseInt)
import Control.Monad.Rec.Class (Step(..), tailRecM)
import Control.Monad.ST as ST
import Control.Monad.ST.Ref as STRef
import Data.Array as Array
import Data.Bifunctor (lmap)
import Data.HashMap (HashMap)
import Data.HashMap as HashMap
import Data.List (List)
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Data.Tuple.Nested (type (/\), (/\))
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Unsafe (unsafePerformEffect)
import Foreign.Object (Object)
import Foreign.Object as Object
import Pipes (yield)
import Pipes.Collect as Pipes.Collect
import Pipes.Core (Producer)
import Test.QuickCheck.Gen (randomSampleOne)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

testData
  :: { array :: Array (Int /\ Int)
     , list :: List (Int /\ Int)
     , strarray :: Array (String /\ Int)
     , object :: Object Int
     , map :: Map Int Int
     , hashMap :: HashMap Int Int
     , stream :: Producer (Int /\ Int) Aff Unit
     , streamStr :: Producer (String /\ Int) Aff Unit
     }
testData =
  unsafePerformEffect $ do
    array <-
      flip traverse (Array.range 0 99999) \k -> do
        v <- liftEffect $ randomSampleOne $ chooseInt 0 99999
        pure $ k /\ v
    let
      strarray = lmap show <$> array
      object = Object.fromFoldable strarray

      map' :: forall m. m -> (Int -> Int -> m -> m) -> m
      map' empty insert = ST.run do
        st <- STRef.new empty
        ST.foreach array \(k /\ v) -> void $ STRef.modify (insert k v) st
        STRef.read st
      hashMap = map' HashMap.empty HashMap.insert
      map = map' Map.empty Map.insert
    pure
      { array
      , strarray
      , list: List.fromFoldable array
      , object
      , hashMap
      , map
      , stream: flip tailRecM 0 \ix -> case Array.index array ix of
          Just a -> yield a $> Loop (ix + 1)
          Nothing -> pure $ Done unit
      , streamStr: flip tailRecM 0 \ix -> case Array.index strarray ix of
          Just a -> yield a $> Loop (ix + 1)
          Nothing -> pure $ Done unit
      }

spec :: Spec Unit
spec =
  describe "Test.Pipes.Collect" do
    describe "toArray" do
      it "collects an array" do
        act <- Pipes.Collect.toArray testData.stream
        act `shouldEqual` testData.array
      it "empty ok" do
        act :: Array Int <- Pipes.Collect.toArray (pure unit)
        act `shouldEqual` []
    describe "toObject" do
      it "collects" do
        act <- Pipes.Collect.toObject $ testData.streamStr
        act `shouldEqual` testData.object
      it "empty ok" do
        act :: Object Int <- Pipes.Collect.toObject (pure unit)
        act `shouldEqual` Object.empty
    describe "toMap" do
      it "collects" do
        act <- Pipes.Collect.toMap testData.stream
        act `shouldEqual` testData.map
      it "empty ok" do
        act :: Map String Int <- Pipes.Collect.toMap (pure unit)
        act `shouldEqual` Map.empty
    describe "toHashMap" do
      it "collects" do
        act <- Pipes.Collect.toHashMap testData.stream
        act `shouldEqual` testData.hashMap
      it "empty ok" do
        act :: HashMap String Int <- Pipes.Collect.toHashMap (pure unit)
        act `shouldEqual` HashMap.empty
    describe "toList" do
      it "collects" do
        act <- Pipes.Collect.toList testData.stream
        act `shouldEqual` testData.list
      it "empty ok" do
        act :: List (String /\ Int) <- Pipes.Collect.toList (pure unit)
        act `shouldEqual` List.Nil
