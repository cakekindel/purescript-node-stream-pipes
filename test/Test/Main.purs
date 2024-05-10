module Test.Main where

import Prelude

import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff (launchAff_)
import Test.Pipes.Node.Stream as Test.Pipes.Node.Stream
import Test.Pipes.Node.Buffer as Test.Pipes.Node.Buffer
import Test.Pipes.Node.FS as Test.Pipes.Node.FS
import Test.Spec.Reporter (specReporter)
import Test.Spec.Runner (defaultConfig, runSpec')

main :: Effect Unit
main = launchAff_ $ runSpec' (defaultConfig { failFast = true, timeout = Nothing }) [ specReporter ] do
  Test.Pipes.Node.Stream.spec
  Test.Pipes.Node.Buffer.spec
  Test.Pipes.Node.FS.spec
