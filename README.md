# purescript-csv-stream

Type-safe bindings for the streaming API of `csv-parse` and `csv-stringify`.

## Installing
```bash
spago install csv-stream
{bun|yarn|npm|pnpm} install csv-parse csv-stringify
```

## Examples
### Stream
```purescript
module Main where

import Prelude

import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Aff (launchAff_)
import Node.Stream (pipe)
import Node.Stream as Stream
import Node.Stream.CSV.Stringify as CSV.Stringify
import Node.Stream.CSV.Parse as CSV.Parse

type MyCSVType1 = {a :: Int, b :: Int, bar :: String, baz :: Boolean}
type MyCSVType2 = {ab :: Int, bar :: String, baz :: Boolean}

atob :: MyCSVType1 -> MyCSVType2
atob {a, b, bar, baz} = {ab: a + b, bar, baz}

myCSV :: String
myCSV = "a,b,bar,baz\n1,2,\"hello, world!\",true\n3,3,,f"

main :: Effect Unit
main = launchAff_ do
  parser <- liftEffect $ CSV.Parse.make {}
  stringifier <- liftEffect $ CSV.Stringify.make {}

  input <- liftEffect $ Stream.readableFromString myCSV
  liftEffect $ Stream.pipe input parser

  records <- CSV.Parse.readAll parser
  liftEffect $ for_ records \r -> CSV.Stringify.write $ atob r
  liftEffect $ Stream.end stringifier

  -- "ab,bar,baz\n3,\"hello, world!\",true\n6,,false"
  csvString <- CSV.Stringify.readAll stringifier
  pure unit
```

### Synchronous
```purescript
module Main where

import Prelude

import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Aff (launchAff_)
import Node.Stream (pipe)
import Node.Stream as Stream
import Node.Stream.CSV.Stringify as CSV.Stringify
import Node.Stream.CSV.Parse as CSV.Parse

type MyCSVType1 = {a :: Int, b :: Int, bar :: String, baz :: Boolean}
type MyCSVType2 = {ab :: Int, bar :: String, baz :: Boolean}

atob :: MyCSVType1 -> MyCSVType2
atob {a, b, bar, baz} = {ab: a + b, bar, baz}

myCSV :: String
myCSV = "a,b,bar,baz\n1,2,\"hello, world!\",true\n3,3,,f"

main :: Effect Unit
main = launchAff_ do
  records :: Array MyCSVType1 <- CSV.Parse.parse myCSV
  -- "ab,bar,baz\n3,\"hello, world!\",true\n6,,false"
  csvString <- CSV.Stringify.stringify (atob <$> records)
  pure unit
```
