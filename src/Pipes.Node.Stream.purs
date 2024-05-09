module Pipes.Node.Stream where

import Prelude

import Control.Alternative (empty)
import Control.Monad.Maybe.Trans (MaybeT(..), runMaybeT)
import Control.Monad.Rec.Class (whileJust)
import Control.Monad.Trans.Class (lift)
import Data.Maybe (Maybe(..))
import Data.Newtype (wrap)
import Effect.Aff (Aff, delay)
import Effect.Aff.Class (liftAff)
import Effect.Class (liftEffect)
import Node.Stream.Object as O
import Pipes (await, yield)
import Pipes.Core (Consumer, Pipe, Producer)
import Pipes.Internal (Proxy)
import Pipes.Internal as P.I

type ProxyFFI :: Type -> Type -> Type -> Type -> Type -> Type -> Type
type ProxyFFI a' a b' b r pipe =
  { pure :: r -> pipe
  , request :: a' -> (a -> pipe) -> pipe
  , respond :: b -> (b' -> pipe) -> pipe
  }

proxyFFI :: forall m a' a b' b r. ProxyFFI a' a b' b r (Proxy a' a b' b m r)
proxyFFI = { pure: P.I.Pure, request: P.I.Request, respond: P.I.Respond }

fromReadable :: forall s a. O.Read s a => s -> Producer (Maybe a) Aff Unit
fromReadable r = whileJust do
  liftAff $ delay $ wrap 0.0
  a <- liftEffect $ O.read r
  case a of
    O.ReadWouldBlock -> do
      lift $ O.awaitReadableOrClosed r
      pure $ Just unit
    O.ReadClosed -> do
      yield Nothing
      pure Nothing
    O.ReadJust a' -> do
      yield $ Just a'
      pure $ Just unit

fromWritable :: forall s a. O.Write s a => s -> Consumer (Maybe a) Aff Unit
fromWritable w = do
  whileJust $ runMaybeT do
    liftAff $ delay $ wrap 0.0
    a <- MaybeT await
    res <- liftEffect $ O.write w a
    case res of
      O.WriteClosed -> empty
      O.WriteOk -> pure unit
      O.WriteWouldBlock -> do
        liftAff $ O.awaitWritableOrClosed w
        pure unit
  liftEffect $ O.end w

fromTransform :: forall a b. O.Transform a b -> Pipe (Maybe a) (Maybe b) Aff Unit
fromTransform t =
  let
    read' {exitOnWouldBlock} =
      whileJust $ runMaybeT do
        liftAff $ delay $ wrap 0.0
        res <- liftEffect $ O.read t
        case res of
          O.ReadWouldBlock ->
            if exitOnWouldBlock then do
              empty
            else do
              liftAff $ O.awaitReadableOrClosed t
              pure unit
          O.ReadJust b -> do
            lift $ yield $ Just b
            pure unit
          O.ReadClosed -> do
            lift $ yield Nothing
            empty
  in do
    whileJust $ runMaybeT do
      liftAff $ delay $ wrap 0.0

      a <- MaybeT await
      writeRes <- liftEffect $ O.write t a

      lift $ read' {exitOnWouldBlock: true}

      case writeRes of
        O.WriteOk -> pure unit
        O.WriteClosed -> empty
        O.WriteWouldBlock -> do
          liftAff $ O.awaitWritableOrClosed t
          pure unit
    liftEffect $ O.end t
    read' {exitOnWouldBlock: false}
