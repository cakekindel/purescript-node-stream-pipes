module Test.Main where

import Prelude

import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff (launchAff_)
import Test.Pipes.Node.Stream as Test.Pipes.Node.Stream
import Test.Spec.Reporter (consoleReporter, specReporter)
import Test.Spec.Runner (defaultConfig, runSpec')

main :: Effect Unit
main = launchAff_ $ runSpec' (defaultConfig { timeout = Nothing }) [ specReporter ] do
  Test.Pipes.Node.Stream.spec
