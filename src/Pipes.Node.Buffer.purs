module Pipes.Node.Buffer where

import Prelude

import Control.Monad.Morph (hoist)
import Effect.Class (class MonadEffect, liftEffect)
import Node.Buffer (Buffer)
import Node.Buffer as Buffer
import Node.Encoding (Encoding)
import Pipes.Core (Pipe)
import Pipes.Prelude as Pipes

toString :: forall m. MonadEffect m => Encoding -> Pipe Buffer String m Unit
toString enc = hoist liftEffect $ Pipes.mapM $ Buffer.toString enc

fromString :: forall m. MonadEffect m => Encoding -> Pipe String Buffer m Unit
fromString enc = hoist liftEffect $ Pipes.mapM $ flip Buffer.fromString enc
