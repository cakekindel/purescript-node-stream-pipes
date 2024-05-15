module Pipes.Node.FS where

import Prelude

import Control.Monad.Error.Class (class MonadThrow)
import Data.Maybe (Maybe)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Effect.Exception (Error)
import Node.Buffer (Buffer)
import Node.FS.Stream (WriteStreamOptions, ReadStreamOptions)
import Node.FS.Stream as FS.Stream
import Node.Path (FilePath)
import Node.Stream.Object as O
import Pipes.Core (Consumer, Producer)
import Pipes.Node.Stream (fromReadable, fromWritable)
import Prim.Row (class Union)

-- | Creates a `fs.Writable` stream for the file
-- | at the given path.
-- |
-- | Writing `Nothing` to this pipe will close the stream.
-- |
-- | See `Pipes.Node.Stream.withEOS` for converting `Producer a`
-- | into `Producer (Maybe a)`, emitting `Nothing` before exiting.
write'
  :: forall r trash m
   . Union r trash WriteStreamOptions
  => MonadAff m
  => MonadThrow Error m
  => Record r
  -> FilePath
  -> Consumer (Maybe Buffer) m Unit
write' o p = do
  w <- liftEffect $ FS.Stream.createWriteStream' p o
  fromWritable $ O.unsafeCoerceWritable w

-- | Open a file in write mode, failing if the file already exists.
-- |
-- | `write' {flags: "wx"}`
create :: forall m. MonadAff m => MonadThrow Error m => FilePath -> Consumer (Maybe Buffer) m Unit
create = write' { flags: "wx" }

-- | Open a file in write mode, truncating it if the file already exists.
-- |
-- | `write' {flags: "w"}`
trunc :: forall m. MonadAff m => MonadThrow Error m => FilePath -> Consumer (Maybe Buffer) m Unit
trunc = write' { flags: "w" }

-- | Open a file in write mode, appending written contents if the file already exists.
-- |
-- | `write' {flags: "a"}`
append :: forall m. MonadAff m => MonadThrow Error m => FilePath -> Consumer (Maybe Buffer) m Unit
append = write' { flags: "a" }

-- | Creates a `fs.Readable` stream for the file at the given path.
-- |
-- | Emits `Nothing` before closing. To opt out of this behavior,
-- | use `Pipes.Node.Stream.withoutEOS` or `Pipes.Node.Stream.unEOS`.
read :: forall m. MonadAff m => MonadThrow Error m => FilePath -> Producer (Maybe Buffer) m Unit
read p = do
  r <- liftEffect $ FS.Stream.createReadStream p
  fromReadable $ O.unsafeCoerceReadable r

-- | Creates a `fs.Readable` stream for the file at the given path.
-- |
-- | Emits `Nothing` before closing. To opt out of this behavior,
-- | use `Pipes.Node.Stream.withoutEOS` or `Pipes.Node.Stream.unEOS`.
read'
  :: forall r trash m
   . Union r trash ReadStreamOptions
  => MonadAff m
  => MonadThrow Error m
  => Record r
  -> FilePath
  -> Producer (Maybe Buffer) m Unit
read' opts p = do
  r <- liftEffect $ FS.Stream.createReadStream' p opts
  fromReadable $ O.unsafeCoerceReadable r
