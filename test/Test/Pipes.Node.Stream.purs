module Test.Pipes.Node.Stream where

import Prelude

import Control.Monad.Trans.Class (lift)
import Data.Array as Array
import Data.Foldable (fold)
import Data.List ((:))
import Data.List as List
import Data.Maybe (Maybe)
import Data.Newtype (wrap)
import Data.String.Gen (genAlphaString)
import Data.Tuple.Nested (type (/\), (/\))
import Effect (Effect)
import Effect.Aff (Aff, delay)
import Effect.Class (class MonadEffect, liftEffect)
import Node.Buffer (Buffer)
import Node.Buffer as Buffer
import Node.Encoding (Encoding(..))
import Node.FS.Stream as FS.Stream
import Node.FS.Sync as FS
import Node.Stream.Object as O
import Node.Zlib as Zlib
import Pipes (each) as Pipes
import Pipes (yield, (>->))
import Pipes.Core (Consumer, Producer, runEffect)
import Pipes.Node.Buffer as Pipes.Buffer
import Pipes.Node.Stream as S
import Pipes.Prelude (mapFoldable, toListM) as Pipes
import Simple.JSON (writeJSON)
import Test.Common (jsonParse, jsonStringify, tmpFile, tmpFiles)
import Test.QuickCheck.Arbitrary (arbitrary)
import Test.QuickCheck.Gen (randomSample')
import Test.Spec (Spec, around, describe, it)
import Test.Spec.Assertions (shouldEqual)

foreign import readableFromArray :: forall @a. Array a -> O.Readable a
foreign import discardTransform :: forall a b. Effect (O.Transform a b)
foreign import charsTransform :: Effect (O.Transform String String)

writer :: forall m. MonadEffect m => String -> m (O.Writable Buffer /\ Consumer (Maybe Buffer) Aff Unit)
writer a = do
  stream <- liftEffect $ O.fromBufferWritable <$> FS.Stream.createWriteStream a
  pure $ stream /\ S.fromWritable stream

reader :: forall m. MonadEffect m => String -> m (Producer (Maybe Buffer) Aff Unit)
reader a = liftEffect $ S.fromReadable <$> O.fromBufferReadable <$> FS.Stream.createReadStream a

spec :: Spec Unit
spec =
  describe "Test.Pipes.Node.Stream" do
    describe "Readable" do
      describe "Readable.from(<Iterable>)" do
        it "empty" do
          vals <- Pipes.toListM $ (S.fromReadable $ readableFromArray @{ foo :: String } []) >-> S.unEOS
          vals `shouldEqual` List.Nil
        it "singleton" do
          vals <- Pipes.toListM $ (S.fromReadable $ readableFromArray @{ foo :: String } [ { foo: "1" } ]) >-> S.unEOS
          vals `shouldEqual` ({ foo: "1" } : List.Nil)
        it "many elements" do
          let exp = (\n -> { foo: show n }) <$> Array.range 0 100
          vals <- Pipes.toListM $ (S.fromReadable $ readableFromArray exp) >-> S.unEOS
          vals `shouldEqual` (List.fromFoldable exp)
    describe "Writable" $ around tmpFile do
      describe "fs.WriteStream" do
        it "pipe to file" \p -> do
          stream <- O.fromBufferWritable <$> liftEffect (FS.Stream.createWriteStream p)
          let
            w = S.fromWritable stream
            source = do
              buf <- liftEffect $ Buffer.fromString "hello" UTF8
              yield buf
          runEffect $ S.withEOS source >-> w
          contents <- liftEffect $ FS.readTextFile UTF8 p
          contents `shouldEqual` "hello"
          shouldEqual true =<< liftEffect (O.isWritableEnded stream)
        it "async pipe to file" \p -> do
          w <- S.fromWritable <$> O.fromBufferWritable <$> liftEffect (FS.Stream.createWriteStream p)
          let
            source = do
              yield "hello, "
              lift $ delay $ wrap 5.0
              yield "world!"
              lift $ delay $ wrap 5.0
              yield " "
              lift $ delay $ wrap 5.0
              yield "this is a "
              lift $ delay $ wrap 5.0
              yield "test."
          runEffect $ S.withEOS (source >-> Pipes.Buffer.fromString UTF8) >-> w
          contents <- liftEffect $ FS.readTextFile UTF8 p
          contents `shouldEqual` "hello, world! this is a test."
        it "chained pipes" \p -> do
          let
            obj = do
              str :: String <- genAlphaString
              num :: Int <- arbitrary
              stuff :: Array String <- arbitrary
              pure { str, num, stuff }
          objs <- liftEffect (randomSample' 1 obj)
          let
            exp = fold (writeJSON <$> objs)
          stream /\ w <- liftEffect $ writer p
          runEffect $ S.withEOS (Pipes.each objs >-> jsonStringify >-> Pipes.Buffer.fromString UTF8) >-> w
          contents <- liftEffect $ FS.readTextFile UTF8 p
          contents `shouldEqual` exp
          shouldEqual true =<< liftEffect (O.isWritableEnded stream)
    describe "Transform" do
      it "gzip" do
        let
          json = yield $ writeJSON { foo: "bar" }
          exp = "1f8b0800000000000003ab564acbcf57b2524a4a2c52aa0500eff52bfe0d000000"
        gzip <- S.fromTransform <$> O.fromBufferTransform <$> liftEffect (Zlib.toDuplex <$> Zlib.createGzip)
        outs :: List.List String <- Pipes.toListM (S.withEOS (json >-> Pipes.Buffer.fromString UTF8) >-> gzip >-> S.unEOS >-> Pipes.Buffer.toString Hex)
        fold outs `shouldEqual` exp
      around tmpFiles
        $ it "file >-> gzip >-> file >-> gunzip" \(a /\ b) -> do
            liftEffect $ FS.writeTextFile UTF8 a $ writeJSON [ 1, 2, 3, 4 ]
            areader <- liftEffect $ reader a
            bwritestream /\ bwriter <- liftEffect $ writer b
            gzip <- S.fromTransform <$> O.fromBufferTransform <$> liftEffect (Zlib.toDuplex <$> Zlib.createGzip)
            runEffect $ areader >-> gzip >-> bwriter
            shouldEqual true =<< liftEffect (O.isWritableEnded bwritestream)

            gunzip <- S.fromTransform <$> O.fromBufferTransform <$> liftEffect (Zlib.toDuplex <$> Zlib.createGunzip)
            breader <- liftEffect $ reader b
            nums <- Pipes.toListM (breader >-> gunzip >-> S.unEOS >-> Pipes.Buffer.toString UTF8 >-> jsonParse @(Array Int) >-> Pipes.mapFoldable identity)
            Array.fromFoldable nums `shouldEqual` [ 1, 2, 3, 4 ]
      around tmpFile $ it "file >-> discardTransform" \(p :: String) -> do
        liftEffect $ FS.writeTextFile UTF8 p "foo"
        r <- reader p
        discard' <- liftEffect discardTransform
        out :: List.List Int <- Pipes.toListM $ r >-> S.fromTransform discard' >-> S.unEOS
        out `shouldEqual` List.Nil
      around tmpFile $ it "file >-> charsTransform" \(p :: String) -> do
        liftEffect $ FS.writeTextFile UTF8 p "foo bar"
        r <- reader p
        chars' <- liftEffect charsTransform
        out :: List.List String <- Pipes.toListM $ r >-> S.inEOS (Pipes.Buffer.toString UTF8) >-> S.fromTransform chars' >-> S.unEOS
        out `shouldEqual` List.fromFoldable [ "f", "o", "o", " ", "b", "a", "r" ]
