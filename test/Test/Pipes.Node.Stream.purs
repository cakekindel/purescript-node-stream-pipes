module Test.Pipes.Node.Stream where

import Prelude

import Control.Monad.Cont (lift)
import Control.Monad.Error.Class (liftEither)
import Control.Monad.Except (runExcept)
import Data.Array as Array
import Data.Bifunctor (lmap)
import Data.Either (Either(..))
import Data.Foldable (fold, intercalate)
import Data.FoldableWithIndex (forWithIndex_)
import Data.FunctorWithIndex (mapWithIndex)
import Data.Int as Int
import Data.List ((:))
import Data.List as List
import Data.Maybe (Maybe)
import Data.Newtype (wrap)
import Data.Profunctor.Strong (first)
import Data.String as String
import Data.String.Gen (genAlphaString)
import Data.Traversable (for_, traverse)
import Data.Tuple.Nested (type (/\), (/\))
import Effect (Effect)
import Effect.Aff (Aff, delay)
import Effect.Class (class MonadEffect, liftEffect)
import Effect.Exception (error)
import Effect.Unsafe (unsafePerformEffect)
import Foreign (Foreign)
import Node.Buffer (Buffer)
import Node.Buffer as Buffer
import Node.Encoding (Encoding(..))
import Node.FS.Stream as FS.Stream
import Node.FS.Sync as FS
import Node.Stream.Object as O
import Pipes (each) as Pipe
import Pipes (yield, (>->))
import Pipes.Async (sync, (>-/->))
import Pipes.Collect as Pipe.Collect
import Pipes.Core (Consumer, Producer, runEffect)
import Pipes.Node.Buffer as Pipe.Buffer
import Pipes.Node.FS as Pipe.FS
import Pipes.Node.Stream as Pipe.Node
import Pipes.Node.Zlib as Pipe.Zlib
import Pipes.Prelude (toListM) as Pipe
import Simple.JSON (readImpl, readJSON, writeJSON)
import Test.Common (jsonStringify, tmpFile, tmpFiles)
import Test.QuickCheck.Arbitrary (arbitrary)
import Test.QuickCheck.Gen (randomSample')
import Test.Spec (Spec, around, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

foreign import readableFromArray :: forall @a. Array a -> O.Readable a
foreign import discardTransform :: forall a b. Effect (O.Transform a b)
foreign import slowTransform :: forall a b. Effect (O.Transform a b)
foreign import charsTransform :: Effect (O.Transform String String)
foreign import cborEncodeSync :: forall a. a -> Effect Buffer
foreign import cborDecodeSync :: forall a. Buffer -> Effect a
foreign import cborEncode :: forall a. Effect (O.Transform a Buffer)
foreign import cborDecode :: forall a. Effect (O.Transform Buffer a)
foreign import csvEncode :: forall a. Effect (O.Transform a String)
foreign import csvDecode :: forall a. Effect (O.Transform String a)

writer :: forall m. MonadEffect m => String -> m (O.Writable Buffer /\ Consumer (Maybe Buffer) Aff Unit)
writer a = do
  stream <- liftEffect $ O.unsafeCoerceWritable <$> FS.Stream.createWriteStream a
  pure $ stream /\ Pipe.Node.fromWritable stream

reader :: forall m. MonadEffect m => String -> m (Producer (Maybe Buffer) Aff Unit)
reader a = liftEffect $ Pipe.Node.fromReadable <$> O.unsafeCoerceReadable <$> FS.Stream.createReadStream a

spec :: Spec Unit
spec =
  describe "Test.Pipes.Node.Stream" do
    describe "Readable" do
      describe "Readable.from(<Iterable>)" do
        it "empty" do
          vals <- Pipe.toListM $ (Pipe.Node.fromReadable $ readableFromArray @{ foo :: String } []) >-> Pipe.Node.unEOS
          vals `shouldEqual` List.Nil
        it "singleton" do
          vals <- Pipe.toListM $ (Pipe.Node.fromReadable $ readableFromArray @{ foo :: String } [ { foo: "1" } ]) >-> Pipe.Node.unEOS
          vals `shouldEqual` ({ foo: "1" } : List.Nil)
        it "many elements" do
          let exp = (\n -> { foo: show n }) <$> Array.range 0 100
          vals <- Pipe.toListM $ (Pipe.Node.fromReadable $ readableFromArray exp) >-> Pipe.Node.unEOS
          vals `shouldEqual` (List.fromFoldable exp)
    describe "Writable" $ around tmpFile do
      describe "fs.WriteStream" do
        it "pipe to file" \p -> do
          stream <- O.unsafeCoerceWritable <$> liftEffect (FS.Stream.createWriteStream p)
          let
            w = Pipe.Node.fromWritable stream
            source = do
              buf <- liftEffect $ Buffer.fromString "hello" UTF8
              yield buf
          runEffect $ Pipe.Node.withEOS source >-> w
          contents <- liftEffect $ FS.readTextFile UTF8 p
          contents `shouldEqual` "hello"
          shouldEqual true =<< liftEffect (O.isWritableEnded stream)
        it "async pipe to file" \p -> do
          w <- Pipe.Node.fromWritable <$> O.unsafeCoerceWritable <$> liftEffect (FS.Stream.createWriteStream p)
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
          runEffect $ Pipe.Node.withEOS (source >-> Pipe.Buffer.fromString UTF8) >-> w
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
          runEffect $ Pipe.Node.withEOS (Pipe.each objs >-> jsonStringify >-> Pipe.Buffer.fromString UTF8) >-> w
          contents <- liftEffect $ FS.readTextFile UTF8 p
          contents `shouldEqual` exp
          shouldEqual true =<< liftEffect (O.isWritableEnded stream)
    describe "Transform" do
      let
        bignums = Array.range 1 1000
        firstNames = String.split (wrap "\n") $ unsafePerformEffect (FS.readTextFile UTF8 "./test/Test/first_names.txt")
        lastNames = String.split (wrap "\n") $ unsafePerformEffect (FS.readTextFile UTF8 "./test/Test/last_names.txt")
        names n = do
          first <- firstNames
          last <- Array.take (Int.round $ Int.toNumber n / Int.toNumber (Array.length firstNames)) lastNames
          pure $ first <> " " <> last
        people n = mapWithIndex (\ix name -> {id: show $ ix + 1, name}) (names n)
        peopleCSV n = "id,name\n" <> intercalate "\n" ((\{id, name} -> id <> "," <> name) <$> people n)

      for_ [4000, 8000, 32000, 64000, 200000] \n -> do
        let
          csv = peopleCSV n
          people' = people n
        around tmpFiles
          $ it (show n <> " row csv >-/-> csv-parse >-/-> cborEncode") \(a /\ _) -> do
              liftEffect $ FS.writeTextFile UTF8 a csv
              cbor :: Buffer <- Pipe.Collect.toBuffer
                $ Pipe.FS.read a
                  >-> Pipe.Node.inEOS (Pipe.Buffer.toString UTF8)
                  >-/-> Pipe.Node.fromTransformEffect csvDecode
                  >-/-> Pipe.Node.fromTransformEffect cborEncode
                  >-> Pipe.Node.unEOS
              f :: Array Foreign <- liftEffect $ cborDecodeSync cbor
              ppl <- traverse (liftEither <<< lmap (error <<< show) <<< runExcept <<< readImpl) f
              ppl `shouldEqual` people'

        around tmpFiles
          $ it (show n <> " row csv >-> sync csv-parse >-> sync cborEncode") \(a /\ _) -> do
              liftEffect $ FS.writeTextFile UTF8 a csv
              cbor :: Buffer <- Pipe.Collect.toBuffer
                $ Pipe.FS.read a
                  >-> Pipe.Node.inEOS (Pipe.Buffer.toString UTF8)
                  >-> sync (Pipe.Node.fromTransformEffect csvDecode)
                  >-> sync (Pipe.Node.fromTransformEffect cborEncode)
                  >-> Pipe.Node.unEOS
              f :: Array Foreign <- liftEffect $ cborDecodeSync cbor
              ppl <- traverse (liftEither <<< lmap (error <<< show) <<< runExcept <<< readImpl) f
              ppl `shouldEqual` people'

      around tmpFiles
        $ it "file >-> sync gzip >-> sync gunzip" \(a /\ _) -> do
            liftEffect $ FS.writeTextFile UTF8 a $ writeJSON bignums
            json <- Pipe.Collect.toMonoid
              $ Pipe.FS.read a
                >-> sync Pipe.Zlib.gzip
                >-> sync Pipe.Zlib.gunzip
                >-> Pipe.Node.unEOS
                >-> Pipe.Buffer.toString UTF8
            readJSON json `shouldEqual` (Right bignums)

      around tmpFiles
        $ it "file >-/-> gzip >-/-> slow >-/-> gunzip" \(a /\ _) -> do
            liftEffect $ FS.writeTextFile UTF8 a $ writeJSON bignums
            json <-
              Pipe.Collect.toMonoid
              $ Pipe.FS.read a
                >-/-> Pipe.Zlib.gzip
                >-/-> Pipe.Node.fromTransformEffect slowTransform
                >-/-> Pipe.Zlib.gunzip
                >-> Pipe.Node.unEOS
                >-> Pipe.Buffer.toString UTF8

            readJSON json `shouldEqual` (Right bignums)
      around tmpFiles
        $ it "file >-> sync gzip >-> sync slow >-> sync gunzip" \(a /\ _) -> do
            liftEffect $ FS.writeTextFile UTF8 a $ writeJSON bignums
            json <-
              Pipe.Collect.toMonoid
              $ Pipe.FS.read a
                >-> sync Pipe.Zlib.gzip
                >-> sync (Pipe.Node.fromTransformEffect slowTransform)
                >-> sync Pipe.Zlib.gunzip
                >-> Pipe.Node.unEOS
                >-> Pipe.Buffer.toString UTF8

            readJSON json `shouldEqual` (Right bignums)
      around tmpFile $ it "file >-> discardTransform" \(p :: String) -> do
        liftEffect $ FS.writeTextFile UTF8 p "foo"
        r <- reader p
        out :: List.List Int <-
          Pipe.toListM
            $ r
                >-/-> Pipe.Node.fromTransformEffect discardTransform
                >-> Pipe.Node.unEOS
        out `shouldEqual` List.Nil
      around tmpFile $ it "file >-> charsTransform" \(p :: String) -> do
        liftEffect $ FS.writeTextFile UTF8 p "foo bar"
        r <- reader p
        out :: List.List String <-
          Pipe.toListM $
            r
            >-> Pipe.Node.inEOS (Pipe.Buffer.toString UTF8)
            >-/-> Pipe.Node.fromTransformEffect charsTransform
            >-> Pipe.Node.unEOS
        out `shouldEqual` List.fromFoldable [ "f", "o", "o", " ", "b", "a", "r" ]
