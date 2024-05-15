# purescript-node-stream-pipes

Interact with node streams in object mode using [`Pipes`]!

## Install
```bash
spago install node-stream-pipes
```

## Usage
### Node Streams
#### Raw Streams
Raw `objectMode` Node streams are represented in `Node.Stream.Object`:
 - `Writable a` accepts chunks of type `a`
 - `Readable a` emits chunks of type `a`
 - `Transform a b` transforms chunks from `a` to `b`

Non-Object streams can also be represented with these types; for example an `fs.WriteStream`
can be coerced to `Writable Buffer` without issue.

Interop between these types and `Node.Stream` are provided in `Node.Stream.Object`:
- `unsafeFrom{String,Buffer}{Writable,Readable,Transform}`
- `unsafeCoerce{Writable,Readable,Transform}`

#### Pipes
Streams in `Node.Stream.Object` can be converted to `Producer`s, `Consumer`s and `Pipe`s with `Pipes.Node.Stream`:
 - `fromReadable :: forall a. <Readable a> -> Producer (Maybe a) <Aff> Unit`
 - `fromWritable :: forall a. <Writable a> -> Consumer (Maybe a) <Aff> Unit`
 - `fromTransform :: forall a b. <Transform a b> -> Pipe (Maybe a) (Maybe b) <Aff> Unit`

#### EOS Marker
Normally, pipe computations will not be executed once any computation in a pipeline exits.

To allow for resource cleanup and awareness that the stream is about to close,
`Maybe a` is used occasionally in this package as an End-of-Stream marker:

```purescript
-- foo.txt is "hello, world!\n"
chunks <- Pipes.Collect.toArray $ Pipes.FS.read "foo.txt" >-> Pipes.Node.Stream.inEOS (Pipes.Buffer.toString UTF8)
chunks `shouldEqual` [Just "hello, world!\n", Nothing]
```

Pipes from `a -> b` unaware of EOS can be lifted to `Maybe a -> Maybe b` with `Pipes.Node.Stream.inEOS`.

Producers of `Maybe a` can drop the EOS marker and emit `a` with `Pipes.Node.Stream.unEOS`.

Producers of `a` can have an EOS marker added with `Pipes.Node.Stream.withEOS`.

#### Example
`Pipes.PassThrough.js`
```javascript
import {PassThrough} from 'stream'

export const makePassThrough = () => new PassThrough()
```

`Pipes.PassThrough.purs`
```purescript
module Pipes.PassThrough where

import Prelude

import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Aff (Aff)
import Pipes.Core (Pipe)
import Node.Stream.Object as ObjectStream
import Pipes.Node.Stream as Pipes.Node.Stream

type PassThroughStream a = ObjectStream.Transform a a

foreign import makeRaw :: Effect PassThroughStream

passThrough :: forall a. Pipe a a Aff Unit
passThrough = do
  raw <- liftEffect $ makeRaw
  Pipes.Node.Stream.fromTransform raw
```

### Utilities
This package provides utilities that explicitly use `MonadRec` to ensure stack-safety
when dealing with producers of large amounts of data.

- `Pipes.Collect` provides stack-safe utilities for executing a pipeline and collecting results into a collection, `Buffer`, `Monoid` etc.
- `Pipes.Construct` provides stack-safe utilities for creating producers from in-memory collections.
- `Pipes.Util` provides some miscellaneous utilities missing from `pipes`.

### Zlib
Pipes for compression & decompression using `zlib` are provided in `Pipes.Node.Zlib`.

### FS
Read files with:
- `Pipes.Node.FS.read <path>`
- `Pipes.Node.FS.read' <WriteStreamOptions> <path>`

```purescript
Pipes.Collect.toStringWith UTF8 $ Pipes.Node.FS.read "foo.txt" >-> Pipes.Stream.unEOS
```

Write files with:
 - `Pipes.Node.FS.write' <WriteStreamOptions> <path>`
 - `Pipes.Node.FS.trunc <path>`
 - `Pipes.Node.FS.create <path>`
 - `Pipes.Node.FS.append <path>`

```purescript
  Pipes.Stream.withEOS (
    Pipes.Construct.eachArray ["id,name", "1,henry", "2,suzie"]
    >-> Pipes.Util.intersperse "\n"
    >-> Pipes.Buffer.fromString UTF8
  )
  >-> Pipes.Node.FS.create "foo.csv"
```

[`Pipes`]: https://pursuit.purescript.org/packages/purescript-pipes/8.0.0
