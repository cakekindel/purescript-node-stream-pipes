module Pipes.Node.Zlib where

import Prelude

import Data.Maybe (Maybe)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Node.Buffer (Buffer)
import Node.Stream.Object as O
import Node.Zlib as Zlib
import Node.Zlib.Types (ZlibStream)
import Pipes.Core (Pipe)
import Pipes.Node.Stream (fromTransform)

fromZlib :: forall r. Effect (ZlibStream r) -> Pipe (Maybe Buffer) (Maybe Buffer) Aff Unit
fromZlib z = do
  raw <- liftEffect $ Zlib.toDuplex <$> z
  fromTransform $ O.fromBufferTransform raw

gzip :: Pipe (Maybe Buffer) (Maybe Buffer) Aff Unit
gzip = fromZlib Zlib.createGzip

gunzip :: Pipe (Maybe Buffer) (Maybe Buffer) Aff Unit
gunzip = fromZlib Zlib.createGunzip

unzip :: Pipe (Maybe Buffer) (Maybe Buffer) Aff Unit
unzip = fromZlib Zlib.createUnzip

inflate :: Pipe (Maybe Buffer) (Maybe Buffer) Aff Unit
inflate = fromZlib Zlib.createInflate

deflate :: Pipe (Maybe Buffer) (Maybe Buffer) Aff Unit
deflate = fromZlib Zlib.createDeflate

brotliCompress :: Pipe (Maybe Buffer) (Maybe Buffer) Aff Unit
brotliCompress = fromZlib Zlib.createBrotliCompress

brotliDecompress :: Pipe (Maybe Buffer) (Maybe Buffer) Aff Unit
brotliDecompress = fromZlib Zlib.createBrotliDecompress
