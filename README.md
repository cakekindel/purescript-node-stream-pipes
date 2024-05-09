# purescript-node-stream-pipes

Interact with node streams in object mode using [`Pipes`]!

## Example
```purescript
import Prelude

import Effect.Aff (launchAff_)
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Pipes.Prelude ((>->))
import Pipes.Prelude as Pipes
import Pipes.Core as Pipes.Core
import Pipes.Node.FS.Stream as FS
import Pipes.Node.Zlib as Zlib
import Pipes.CSV.Parse as CSV.Parse

-- == my-zipped-data.csv ==
-- id,foo,is_deleted
-- 1,hello,f
-- 2,goodbye,t

-- Logs:
-- {id: 1, foo: "hello", is_deleted: false}
-- {id: 2, foo: "goodbye", is_deleted: true}
main :: Effect Unit
main =
  Pipes.Core.runEffect
    $ FS.createReadStream "my-zipped-data.csv.gz"
        >-> Zlib.gunzip
        >-> CSV.Parse.parse @{id :: Int, foo :: String, is_deleted :: Boolean}
        >-> Pipes.mapM (liftEffect <<< log)
```

## Installing
```bash
spago install node-stream-pipes
```

[`Pipes`]: https://pursuit.purescript.org/packages/purescript-pipes/8.0.0
