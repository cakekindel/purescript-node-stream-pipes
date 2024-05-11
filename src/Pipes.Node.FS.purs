module Pipes.Node.FS where

import Prelude

import Data.Maybe (Maybe)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Node.Buffer (Buffer)
import Node.FS.Stream (WriteStreamOptions)
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
write
  :: forall r trash
   . Union r trash WriteStreamOptions
  => Record r
  -> FilePath
  -> Consumer (Maybe Buffer) Aff Unit
write o p = do
  w <- liftEffect $ FS.Stream.createWriteStream' p o
  fromWritable $ O.fromBufferWritable w

-- | Open a file in write mode, failing if the file already exists.
-- |
-- | `write {flags: "wx"}`
create :: FilePath -> Consumer (Maybe Buffer) Aff Unit
create = write { flags: "wx" }

-- | Open a file in write mode, truncating it if the file already exists.
-- |
-- | `write {flags: "w"}`
truncate :: FilePath -> Consumer (Maybe Buffer) Aff Unit
truncate = write { flags: "w" }

-- | Open a file in write mode, appending written contents if the file already exists.
-- |
-- | `write {flags: "a"}`
append :: FilePath -> Consumer (Maybe Buffer) Aff Unit
append = write { flags: "a" }

-- | Creates a `fs.Readable` stream for the file at the given path.
-- |
-- | Emits `Nothing` before closing. To opt out of this behavior,
-- | use `Pipes.Node.Stream.withoutEOS` or `Pipes.Node.Stream.unEOS`.
read :: FilePath -> Producer (Maybe Buffer) Aff Unit
read p = do
  r <- liftEffect $ FS.Stream.createReadStream p
  fromReadable $ O.fromBufferReadable r
