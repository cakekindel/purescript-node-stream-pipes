module Test.Pipes.Node.Buffer where

import Prelude

import Control.Monad.Error.Class (catchError)
import Control.Monad.Gen (chooseInt, sized)
import Data.Array as Array
import Data.FoldableWithIndex (forWithIndex_)
import Data.Int as Int
import Data.String.Gen (genAsciiString)
import Data.Tuple (fst, snd)
import Data.Tuple.Nested ((/\))
import Effect.Class (liftEffect)
import Effect.Unsafe (unsafePerformEffect)
import Node.Buffer (Buffer, BufferValueType(..))
import Node.Buffer as Buffer
import Node.Encoding (Encoding(..))
import Pipes ((>->))
import Pipes (each) as Pipes
import Pipes.Core (runEffect) as Pipes
import Pipes.Node.Buffer as Pipes.Node.Buffer
import Pipes.Prelude (drain, toListM) as Pipes
import Test.QuickCheck (class Arbitrary)
import Test.QuickCheck.Arbitrary (arbitrary)
import Test.QuickCheck.Gen (randomSample', vectorOf)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

data BufferJunk = BufferJunk Buffer

instance Arbitrary BufferJunk where
  arbitrary = sized \s -> do
    ns <- vectorOf s (chooseInt 0 7)
    pure $ unsafePerformEffect do
      buf <- Buffer.alloc s
      forWithIndex_ ns \ix n -> Buffer.write UInt8 (Int.toNumber n) ix buf
      pure $ BufferJunk buf

data BufferUTF8 = BufferUTF8 String Buffer

instance Arbitrary BufferUTF8 where
  arbitrary = do
    s <- genAsciiString
    pure $ BufferUTF8 s $ unsafePerformEffect $ Buffer.fromString s UTF8

spec :: Spec Unit
spec = describe "Pipes.Node.Buffer" do
  describe "toString" do
    it "fails when encoding wrong" do
      vals <- Pipes.each <$> (map \(BufferJunk b) -> b) <$> liftEffect (randomSample' 10 arbitrary)
      let
        uut = Pipes.runEffect $ vals >-> Pipes.Node.Buffer.toString UTF8 >-> Pipes.drain
        ok = do
          uut
          fail "Should have thrown"
        err _ = pure unit
      catchError ok err
    it "junk OK in hex" do
      vals <- Pipes.each <$> (map \(BufferJunk b) -> b) <$> liftEffect (randomSample' 10 arbitrary)
      Pipes.runEffect $ vals >-> Pipes.Node.Buffer.toString Hex >-> Pipes.drain
    it "UTF8 ok" do
      vals <- (map \(BufferUTF8 s b) -> s /\ b) <$> liftEffect (randomSample' 100 arbitrary)
      let
        bufs = Pipes.each $ snd <$> vals
        strs = fst <$> vals
      act <- Array.fromFoldable <$> Pipes.toListM (bufs >-> Pipes.Node.Buffer.toString UTF8)
      act `shouldEqual` strs
  describe "fromString" do
    it "ok" do
      vals <- Pipes.each <$> liftEffect (randomSample' 100 genAsciiString)
      Pipes.runEffect $ vals >-> Pipes.Node.Buffer.fromString UTF8 >-> Pipes.drain
