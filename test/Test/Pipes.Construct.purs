module Test.Pipes.Construct where

import Prelude

import Data.Array as Array
import Data.List as List
import Data.Map as Map
import Data.Tuple.Nested (type (/\), (/\))
import Effect.Class (liftEffect)
import Pipes.Collect as Pipes.Collect
import Pipes.Construct as Pipes.Construct
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Test.Pipes.Construct" do
    describe "eachMap" do
      it "empty map" do
        kvs <- Pipes.Collect.toArray $ Pipes.Construct.eachMap Map.empty
        kvs `shouldEqual` ([] :: Array (Int /\ Int))
      it "nonempty map" do
        let
          exp = (\n -> n /\ n) <$> Array.range 0 99999
          map = Map.fromFoldable exp
        kvs <-
          liftEffect
            $ Pipes.Collect.toArray
            $ Pipes.Construct.eachMap
            $ map
        kvs `shouldEqual` exp
    describe "eachArray" do
      it "empty array" do
        kvs <- Pipes.Collect.toArray $ Pipes.Construct.eachArray []
        kvs `shouldEqual` ([] :: Array Int)
      it "nonempty array" do
        let
          inp = (\n -> n /\ n) <$> Array.range 0 99999
        kvs <-
          liftEffect
            $ Pipes.Collect.toArray
            $ Pipes.Construct.eachArray
            $ inp
        kvs `shouldEqual` inp
    describe "eachList" do
      it "empty list" do
        kvs <- Pipes.Collect.toArray $ Pipes.Construct.eachList List.Nil
        kvs `shouldEqual` ([] :: Array Int)
      it "nonempty list" do
        let
          inp = (\n -> n /\ n) <$> Array.range 0 99999
        kvs <-
          liftEffect
            $ Pipes.Collect.toArray
            $ Pipes.Construct.eachList
            $ List.fromFoldable
            $ inp
        kvs `shouldEqual` inp
