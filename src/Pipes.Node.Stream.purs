module Pipes.Node.Stream where

import Prelude

import Control.Monad.Error.Class (throwError)
import Control.Monad.Rec.Class (whileJust)
import Control.Monad.ST.Class (liftST)
import Control.Monad.ST.Ref as STRef
import Control.Monad.Trans.Class (lift)
import Data.Maybe (Maybe(..), maybe)
import Data.Newtype (wrap)
import Data.Traversable (for_)
import Effect.Aff (Aff, delay)
import Effect.Aff.Class (liftAff)
import Effect.Class (liftEffect)
import Node.Stream.Object as O
import Pipes (await, yield, (>->))
import Pipes (for) as P
import Pipes.Core (Consumer, Pipe, Producer, Producer_)
import Pipes.Prelude (mapFoldable, map) as P

-- | Convert a `Readable` stream to a `Pipe`.
-- |
-- | This will yield `Nothing` before exiting, signaling
-- | End-of-stream.
fromReadable :: forall s a. O.Read s a => s -> Producer_ (Maybe a) Aff Unit
fromReadable r =
  let
    cleanup rmErrorListener = do
      liftEffect rmErrorListener
    go {error, cancel} = do
      liftAff $ delay $ wrap 0.0
      err <- liftEffect $ liftST $ STRef.read error
      for_ err throwError

      res <- liftEffect $ O.read r
      case res of
        O.ReadJust a -> yield (Just a) *> go {error, cancel}
        O.ReadWouldBlock -> lift (O.awaitReadableOrClosed r) *> go {error, cancel}
        O.ReadClosed -> yield Nothing *> cleanup cancel
  in do
    e <- liftEffect $ O.withErrorST r
    go e

-- | Convert a `Writable` stream to a `Pipe`.
-- |
-- | When `Nothing` is piped to this, the stream will
-- | be `end`ed, and the pipe will noop if invoked again.
fromWritable :: forall s a. O.Write s a => s -> Consumer (Maybe a) Aff Unit
fromWritable w =
  let
    cleanup rmErrorListener = do
      liftEffect rmErrorListener
      liftEffect $ O.end w
    go {error, cancel} = do
      liftAff $ delay $ wrap 0.0
      err <- liftEffect $ liftST $ STRef.read error
      for_ err throwError

      ma <- await
      case ma of
        Nothing -> cleanup cancel
        Just a -> do
          res <- liftEffect $ O.write w a
          case res of
            O.WriteOk -> go {error, cancel}
            O.WriteWouldBlock -> liftAff (O.awaitWritableOrClosed w) *> go {error, cancel}
            O.WriteClosed -> pure unit
  in do
    r <- liftEffect $ O.withErrorST w
    go r

-- | Convert a `Transform` stream to a `Pipe`.
-- |
-- | When `Nothing` is piped to this, the `Transform` stream will
-- | be `end`ed, and the pipe will noop if invoked again.
fromTransform :: forall a b. O.Transform a b -> Pipe (Maybe a) (Maybe b) Aff Unit
fromTransform t =
  let
    cleanup removeErrorListener = do
      liftEffect $ O.end t
      liftEffect $ removeErrorListener
      fromReadable t
    yieldFromReadableHalf = do
      res <- liftEffect (O.read t)
      case res of
        O.ReadJust a -> yield (Just a)
        O.ReadWouldBlock -> pure unit
        O.ReadClosed -> yield Nothing *> pure unit
    go {error, cancel} = do
      liftAff $ delay $ wrap 0.0
      err <- liftEffect $ liftST $ STRef.read error
      for_ err throwError

      ma <- await
      case ma of
        Nothing -> cleanup cancel
        Just a' -> do
          res <- liftEffect $ O.write t a'
          yieldFromReadableHalf
          case res of
            O.WriteOk -> go {error, cancel}
            O.WriteWouldBlock -> lift (O.awaitWritableOrClosed t) *> go {error, cancel}
            O.WriteClosed -> cleanup cancel
  in do
    r <- liftEffect $ O.withErrorST t
    go r

-- | Given a `Producer` of values, wrap them in `Just`.
-- |
-- | Before the `Producer` exits, emits `Nothing` as an End-of-stream signal.
withEOS :: forall a. Producer a Aff Unit -> Producer (Maybe a) Aff Unit
withEOS a = do
  P.for a (yield <<< Just)
  yield Nothing

-- | Strip a pipeline of the EOS signal
unEOS :: forall a. Pipe (Maybe a) a Aff Unit
unEOS = P.mapFoldable identity

-- | Lift a `Pipe a a` to `Pipe (Maybe a) (Maybe a)`.
-- |
-- | Allows easily using pipes not concerned with the EOS signal with
-- | pipes that do need this signal.
-- |
-- | (ex. `Pipes.Node.Buffer.toString` doesn't need an EOS signal, but `Pipes.Node.FS.create` does.)
-- |
-- | `Just` values will be passed to the pipe, and the response(s) will be wrapped in `Just`.
-- |
-- | `Nothing` will bypass the given pipe entirely, and the pipe will not be invoked again.
inEOS :: forall a b. Pipe a b Aff Unit -> Pipe (Maybe a) (Maybe b) Aff Unit
inEOS p = whileJust do
  ma <- await
  maybe (yield Nothing) (\a -> yield a >-> p >-> P.map Just) ma
  pure $ void ma
