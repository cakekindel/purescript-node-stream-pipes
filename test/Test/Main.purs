module Test.Main where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Time.Duration (Milliseconds(..))
import Effect (Effect)
import Effect.Aff (launchAff_)
import Test.Pipes.Collect as Test.Pipes.Collect
import Test.Pipes.Construct as Test.Pipes.Construct
import Test.Pipes.Node.Buffer as Test.Pipes.Node.Buffer
import Test.Pipes.Node.FS as Test.Pipes.Node.FS
import Test.Pipes.Node.Stream as Test.Pipes.Node.Stream
import Test.Spec.Reporter (specReporter)
import Test.Spec.Runner (defaultConfig, runSpec')

main :: Effect Unit
main = launchAff_ $ runSpec' (defaultConfig { slow = Milliseconds 0.0, failFast = true, exit = false, timeout = Nothing }) [ specReporter ] do
  Test.Pipes.Node.Stream.spec
  Test.Pipes.Node.Buffer.spec
  Test.Pipes.Node.FS.spec
  Test.Pipes.Collect.spec
  Test.Pipes.Construct.spec
