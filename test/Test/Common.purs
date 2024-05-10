module Test.Common where

import Prelude

import Control.Monad.Error.Class (class MonadError, liftEither, try)
import Data.Bifunctor (lmap)
import Data.String.Gen (genAlphaString)
import Data.Tuple (fst)
import Data.Tuple.Nested (type (/\), (/\))
import Effect.Aff (Aff, bracket)
import Effect.Class (liftEffect)
import Effect.Exception (Error, error)
import Node.FS.Sync as FS
import Pipes.Core (Pipe)
import Pipes.Prelude as Pipes
import Simple.JSON (class ReadForeign, class WriteForeign, readJSON, writeJSON)
import Test.QuickCheck.Gen (randomSampleOne, resize)

tmpFile :: (String -> Aff Unit) -> Aff Unit
tmpFile f = tmpFiles (f <<< fst)

tmpFiles :: (String /\ String -> Aff Unit) -> Aff Unit
tmpFiles =
  let
    acq = do
      randa <- liftEffect $ randomSampleOne $ resize 10 genAlphaString
      randb <- liftEffect $ randomSampleOne $ resize 10 genAlphaString
      void $ try $ liftEffect $ FS.mkdir ".tmp"
      pure $ (".tmp/tmp." <> randa) /\ (".tmp/tmp." <> randb)
    rel (a /\ b) = liftEffect (try (FS.rm a) *> void (try $ FS.rm b))
  in
    bracket acq rel

jsonStringify :: forall m a. Monad m => WriteForeign a => Pipe a String m Unit
jsonStringify = Pipes.map writeJSON

jsonParse :: forall m @a. MonadError Error m => ReadForeign a => Pipe String a m Unit
jsonParse = Pipes.mapM (liftEither <<< lmap (error <<< show) <<< readJSON)
