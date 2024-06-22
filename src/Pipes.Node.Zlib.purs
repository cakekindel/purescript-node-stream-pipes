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
import Pipes.Node.Stream (TransformContext, fromTransform)

type X = TransformContext Buffer Buffer

fromZlib :: forall r m. MonadAff m => MonadThrow Error m => Effect (ZlibStream r) -> AsyncPipe X (Maybe Buffer) (Maybe Buffer) m
fromZlib z =
  fromTransform do
    raw <- liftEffect $ Zlib.toDuplex <$> z
    pure $ O.unsafeCoerceTransform raw

gzip :: forall m. MonadAff m => MonadThrow Error m => AsyncPipe X (Maybe Buffer) (Maybe Buffer) m
gzip = fromZlib Zlib.createGzip

gunzip :: forall m. MonadAff m => MonadThrow Error m => AsyncPipe X (Maybe Buffer) (Maybe Buffer) m
gunzip = fromZlib Zlib.createGunzip

unzip :: forall m. MonadAff m => MonadThrow Error m => AsyncPipe X (Maybe Buffer) (Maybe Buffer) m
unzip = fromZlib Zlib.createUnzip

inflate :: forall m. MonadAff m => MonadThrow Error m => AsyncPipe X (Maybe Buffer) (Maybe Buffer) m
inflate = fromZlib Zlib.createInflate

deflate :: forall m. MonadAff m => MonadThrow Error m => AsyncPipe X (Maybe Buffer) (Maybe Buffer) m
deflate = fromZlib Zlib.createDeflate

brotliCompress :: forall m. MonadAff m => MonadThrow Error m => AsyncPipe X (Maybe Buffer) (Maybe Buffer) m
brotliCompress = fromZlib Zlib.createBrotliCompress

brotliDecompress :: forall m. MonadAff m => MonadThrow Error m => AsyncPipe X (Maybe Buffer) (Maybe Buffer) m
brotliDecompress = fromZlib Zlib.createBrotliDecompress
