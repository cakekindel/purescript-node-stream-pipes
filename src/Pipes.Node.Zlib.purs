module Pipes.Node.Zlib where

import Prelude

import Control.Monad.Error.Class (class MonadThrow)
import Data.Maybe (Maybe)
import Effect (Effect)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Effect.Exception (Error)
import Node.Buffer (Buffer)
import Node.Stream.Object as O
import Node.Zlib as Zlib
import Node.Zlib.Types (ZlibStream)
import Pipes.Async (AsyncPipe)
import Pipes.Node.Stream (fromTransform)

fromZlib :: forall r m. MonadAff m => MonadThrow Error m => Effect (ZlibStream r) -> AsyncPipe (Maybe Buffer) (Maybe Buffer) m Unit
fromZlib z =
  do
    raw <- liftEffect $ Zlib.toDuplex <$> z
    fromTransform $ O.unsafeCoerceTransform raw

gzip :: forall m. MonadAff m => MonadThrow Error m => AsyncPipe (Maybe Buffer) (Maybe Buffer) m Unit
gzip = fromZlib Zlib.createGzip

gunzip :: forall m. MonadAff m => MonadThrow Error m => AsyncPipe (Maybe Buffer) (Maybe Buffer) m Unit
gunzip = fromZlib Zlib.createGunzip

unzip :: forall m. MonadAff m => MonadThrow Error m => AsyncPipe (Maybe Buffer) (Maybe Buffer) m Unit
unzip = fromZlib Zlib.createUnzip

inflate :: forall m. MonadAff m => MonadThrow Error m => AsyncPipe (Maybe Buffer) (Maybe Buffer) m Unit
inflate = fromZlib Zlib.createInflate

deflate :: forall m. MonadAff m => MonadThrow Error m => AsyncPipe (Maybe Buffer) (Maybe Buffer) m Unit
deflate = fromZlib Zlib.createDeflate

brotliCompress :: forall m. MonadAff m => MonadThrow Error m => AsyncPipe (Maybe Buffer) (Maybe Buffer) m Unit
brotliCompress = fromZlib Zlib.createBrotliCompress

brotliDecompress :: forall m. MonadAff m => MonadThrow Error m => AsyncPipe (Maybe Buffer) (Maybe Buffer) m Unit
brotliDecompress = fromZlib Zlib.createBrotliDecompress
