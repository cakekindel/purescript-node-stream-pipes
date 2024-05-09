module Test.Pipes.Node.Stream where

import Prelude

import Control.Monad.Error.Class (liftEither, try)
import Control.Monad.Morph (hoist)
import Control.Monad.Trans.Class (lift)
import Data.Array as Array
import Data.Bifunctor (lmap)
import Data.Foldable (fold, intercalate)
import Data.List ((:))
import Data.List as List
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Newtype (wrap)
import Data.String.Gen (genAlphaString)
import Data.Traversable (for_, traverse)
import Data.Tuple (fst)
import Data.Tuple.Nested (type (/\), (/\))
import Effect (Effect)
import Effect.Aff (Aff, bracket, delay)
import Effect.Class (liftEffect)
import Effect.Exception (error)
import Node.Buffer (Buffer)
import Node.Buffer as Buffer
import Node.Encoding (Encoding(..))
import Node.FS.Stream as FS.Stream
import Node.FS.Sync as FS
import Node.Stream.Object as O
import Node.Zlib as Zlib
import Pipes (yield, (>->))
import Pipes.Core (Consumer, Producer, Pipe, runEffect)
import Pipes.Node.Stream as S
import Pipes.Prelude as Pipe
import Simple.JSON (class ReadForeign, class WriteForeign, readJSON, writeJSON)
import Test.QuickCheck.Arbitrary (arbitrary)
import Test.QuickCheck.Gen (randomSample', randomSampleOne, resize)
import Test.Spec (Spec, around, describe, it)
import Test.Spec.Assertions (shouldEqual)

foreign import readableFromArray :: forall @a. Array a -> O.Readable a

str2buf :: Pipe (Maybe String) (Maybe Buffer) Aff Unit
str2buf = hoist liftEffect $ Pipe.mapM (traverse $ flip Buffer.fromString UTF8)

buf2str :: Pipe (Maybe Buffer) (Maybe String) Aff Unit
buf2str = hoist liftEffect $ Pipe.mapM (traverse $ Buffer.toString UTF8)

buf2hex :: Pipe (Maybe Buffer) (Maybe String) Aff Unit
buf2hex = hoist liftEffect $ Pipe.mapM (traverse $ Buffer.toString Hex)

jsonStringify :: forall a. WriteForeign a => Pipe (Maybe a) (Maybe String) Aff Unit
jsonStringify = Pipe.map (map writeJSON)

jsonParse :: forall @a. ReadForeign a => Pipe (Maybe String) (Maybe a) Aff Unit
jsonParse = Pipe.mapM (traverse (liftEither <<< lmap (error <<< show) <<< readJSON))

writer :: String -> Effect (Consumer (Maybe Buffer) Aff Unit)
writer a = S.fromWritable <$> O.fromBufferWritable <$> FS.Stream.createWriteStream a

reader :: String -> Effect (Producer (Maybe Buffer) Aff Unit)
reader a = S.fromReadable <$> O.fromBufferReadable <$> FS.Stream.createReadStream a

tmpFile :: (String -> Aff Unit) -> Aff Unit
tmpFile f = tmpFiles (f <<< fst)

tmpFiles :: (String /\ String -> Aff Unit) -> Aff Unit
tmpFiles =
  let
    acq = do
      randa <- liftEffect $ randomSampleOne $ resize 10 genAlphaString
      randb <- liftEffect $ randomSampleOne $ resize 10 genAlphaString
      void $ try $ liftEffect $ FS.mkdir ".tmp"
      pure $ ("tmp." <> randa) /\ ("tmp." <> randb)
    rel (a /\ b) = liftEffect (try (FS.rm a) *> void (try $ FS.rm b))
  in
    bracket acq rel

spec :: Spec Unit
spec =
  describe "Test.Pipes.Node.Stream" do
    describe "Readable" do
      describe "Readable.from(<Iterable>)" do
        it "empty" do
          vals <- List.catMaybes <$> (Pipe.toListM $ S.fromReadable $ readableFromArray @{ foo :: String } [])
          vals `shouldEqual` List.Nil
        it "singleton" do
          vals <- List.catMaybes <$> (Pipe.toListM $ S.fromReadable $ readableFromArray @{ foo :: String } [ { foo: "1" } ])
          vals `shouldEqual` ({ foo: "1" } : List.Nil)
        it "many elements" do
          let exp = (\n -> { foo: show n }) <$> Array.range 0 100
          vals <- List.catMaybes <$> (Pipe.toListM $ S.fromReadable $ readableFromArray exp)
          vals `shouldEqual` (List.fromFoldable exp)
    describe "Writable" $ around tmpFile do
      describe "fs.WriteStream" do
        it "pipe to file" \p -> do
          w <- S.fromWritable <$> O.fromBufferWritable <$> liftEffect (FS.Stream.createWriteStream p)
          let
            source = do
              buf <- liftEffect $ Buffer.fromString "hello" UTF8
              yield $ Just buf
              yield Nothing
          runEffect $ source >-> w
          contents <- liftEffect $ FS.readTextFile UTF8 p
          contents `shouldEqual` "hello"
        it "async pipe to file" \p -> do
          w <- S.fromWritable <$> O.fromBufferWritable <$> liftEffect (FS.Stream.createWriteStream p)
          let
            source = do
              yield $ Just "hello, "
              lift $ delay $ wrap 5.0
              yield $ Just "world!"
              lift $ delay $ wrap 5.0
              yield $ Just " "
              lift $ delay $ wrap 5.0
              yield $ Just "this is a "
              lift $ delay $ wrap 5.0
              yield $ Just "test."
              yield Nothing
          runEffect $ source >-> str2buf >-> w
          contents <- liftEffect $ FS.readTextFile UTF8 p
          contents `shouldEqual` "hello, world! this is a test."
        it "chained pipes" \p -> do
          let
            obj = do
              str :: String <- genAlphaString
              num :: Int <- arbitrary
              stuff :: Array String <- arbitrary
              pure {str, num, stuff}
          objs <- liftEffect $ randomSample' 1 obj
          let
            exp = fold (writeJSON <$> objs)
            objs' = for_ (Just <$> objs) yield *> yield Nothing
          w <- liftEffect $ writer p
          runEffect $ objs' >-> jsonStringify >-> str2buf >-> w
          contents <- liftEffect $ FS.readTextFile UTF8 p
          contents `shouldEqual` exp
    describe "Transform" do
      it "gzip" do
        let
          json = do
            yield $ Just $ writeJSON {foo: "bar"}
            yield Nothing
          exp = "1f8b0800000000000003ab564acbcf57b2524a4a2c52aa0500eff52bfe0d000000"
        gzip <- S.fromTransform <$> O.fromBufferTransform <$> liftEffect (Zlib.toDuplex <$> Zlib.createGzip)
        outs :: List.List String <- List.catMaybes <$> Pipe.toListM (json >-> str2buf >-> gzip >-> buf2hex)
        fold outs `shouldEqual` exp
      around tmpFiles
        $ it "file >-> gzip >-> file >-> gunzip" \(a /\ b) -> do
            liftEffect $ FS.writeTextFile UTF8 a $ writeJSON [1, 2, 3, 4]
            areader <- liftEffect $ reader a
            bwriter <- liftEffect $ writer b
            gzip <- S.fromTransform <$> O.fromBufferTransform <$> liftEffect (Zlib.toDuplex <$> Zlib.createGzip)
            runEffect $ areader >-> gzip >-> bwriter

            gunzip <- S.fromTransform <$> O.fromBufferTransform <$> liftEffect (Zlib.toDuplex <$> Zlib.createGunzip)
            breader <- liftEffect $ reader b
            nums <- Pipe.toListM (breader >-> gunzip >-> buf2str >-> jsonParse @(Array Int) >-> Pipe.mapFoldable (fromMaybe []))
            Array.fromFoldable nums `shouldEqual` [1, 2, 3, 4]
