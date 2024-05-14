module Pipes.Node.Stream where

import Prelude hiding (join)

import Control.Monad.Error.Class (class MonadThrow, throwError)
import Control.Monad.Rec.Class (class MonadRec, Step(..), tailRecM)
import Control.Monad.ST.Class (liftST)
import Control.Monad.ST.Ref as STRef
import Control.Monad.Trans.Class (lift)
import Data.Maybe (Maybe(..))
import Data.Newtype (wrap)
import Data.Traversable (for_)
import Data.Tuple.Nested ((/\))
import Effect.Aff (delay)
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Effect.Exception (Error)
import Node.Stream.Object as O
import Pipes (await, yield)
import Pipes (for) as P
import Pipes.Core (Consumer, Pipe, Producer, Producer_)
import Pipes.Prelude (mapFoldable) as P
import Pipes.Util (InvokeResult(..), invoke)

-- | Convert a `Readable` stream to a `Pipe`.
-- |
-- | This will yield `Nothing` before exiting, signaling
-- | End-of-stream.
fromReadable :: forall s a m. MonadThrow Error m => MonadAff m => O.Read s a => s -> Producer_ (Maybe a) m Unit
fromReadable r =
  let
    cleanup rmErrorListener = do
      liftEffect rmErrorListener
      pure $ Done unit

    go { error, cancel } = do
      err <- liftEffect $ liftST $ STRef.read error
      for_ err throwError

      res <- liftEffect $ O.read r
      case res of
        O.ReadJust a -> yield (Just a) $> Loop { error, cancel }
        O.ReadWouldBlock -> liftAff (O.awaitReadableOrClosed r) $> Loop { error, cancel }
        O.ReadClosed -> yield Nothing *> cleanup cancel
  in
    do
      e <- liftEffect $ O.withErrorST r
      tailRecM go e

-- | Convert a `Writable` stream to a `Pipe`.
-- |
-- | When `Nothing` is piped to this, the stream will
-- | be `end`ed, and the pipe will noop if invoked again.
fromWritable :: forall s a m. MonadThrow Error m => MonadAff m => O.Write s a => s -> Consumer (Maybe a) m Unit
fromWritable w =
  let
    cleanup rmErrorListener = do
      liftEffect rmErrorListener
      liftEffect $ O.end w
      liftAff $ O.awaitFinished w
      pure $ Done unit

    go { error, cancel } = do
      err <- liftEffect $ liftST $ STRef.read error
      for_ err throwError

      needsDrain <- liftEffect $ O.needsDrain w
      when needsDrain $ liftAff $ O.awaitWritableOrClosed w
      ma <- await
      case ma of
        Nothing -> cleanup cancel
        Just a -> do
          res <- liftEffect $ O.write w a
          case res of
            O.WriteClosed -> cleanup cancel
            _ -> pure $ Loop { error, cancel }
  in
    do
      r <- liftEffect $ O.withErrorST w
      tailRecM go r

-- | Convert a `Transform` stream to a `Pipe`.
-- |
-- | When `Nothing` is piped to this, the `Transform` stream will
-- | be `end`ed, and the pipe will noop if invoked again.
fromTransform :: forall a b m. MonadThrow Error m => MonadAff m => O.Transform a b -> Pipe (Maybe a) (Maybe b) m Unit
fromTransform t =
  let
    cleanup removeErrorListener = do
      yieldWhileReadable
      liftEffect $ O.end t
      liftEffect $ removeErrorListener
      fromReadable t
      pure $ Done unit

    yieldWhileReadable = do
      flip tailRecM unit \_ -> do
        res <- liftEffect $ O.read t
        case res of
          O.ReadJust a -> yield (Just a) $> Loop unit
          _ -> pure $ Done unit

    maybeYield1 = do
      res <- liftEffect $ O.read t
      case res of
        O.ReadJust a -> yield $ Just a
        _ -> pure unit

    go { error, cancel } = do
      err <- liftEffect $ liftST $ STRef.read error
      for_ err throwError

      needsDrain <- liftEffect $ O.needsDrain t
      if needsDrain then do
        liftAff $ delay $ wrap 0.0
        yieldWhileReadable
        pure $ Loop { error, cancel }
      else do
        ma <- await
        case ma of
          Nothing -> cleanup cancel
          Just a' -> do
            res <- liftEffect $ O.write t a'
            case res of
              O.WriteClosed -> cleanup cancel
              O.WriteOk -> do
                maybeYield1
                pure $ Loop { error, cancel }
              O.WriteWouldBlock -> do
                yieldWhileReadable
                pure $ Loop { error, cancel }
  in
    do
      r <- liftEffect $ O.withErrorST t
      tailRecM go r

-- | Given a `Producer` of values, wrap them in `Just`.
-- |
-- | Before the `Producer` exits, emits `Nothing` as an End-of-stream signal.
withEOS :: forall a m. Monad m => Producer a m Unit -> Producer (Maybe a) m Unit
withEOS a = do
  P.for a (yield <<< Just)
  yield Nothing

-- | Strip a pipeline of the EOS signal
unEOS :: forall a m. Monad m => Pipe (Maybe a) a m Unit
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
inEOS :: forall a b m. MonadRec m => Pipe a b m Unit -> Pipe (Maybe a) (Maybe b) m Unit
inEOS p = flip tailRecM p \p' -> do
  ma <- await
  case ma of
    Just a -> do
      res <- lift $ invoke p' a
      case res of
        Yielded (as /\ p'') -> do
          for_ (Just <$> as) yield
          pure $ Loop p''
        DidNotYield p'' -> pure $ Loop p''
        Exited -> yield Nothing $> Done unit
    _ -> yield Nothing $> Done unit
