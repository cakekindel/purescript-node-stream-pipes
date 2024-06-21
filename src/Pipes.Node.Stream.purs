module Pipes.Node.Stream where

import Prelude hiding (join)

import Control.Monad.Error.Class (class MonadThrow, throwError)
import Control.Monad.Rec.Class (class MonadRec, Step(..), tailRecM, whileJust)
import Control.Monad.ST.Class (liftST)
import Control.Monad.ST.Ref as STRef
import Control.Monad.Trans.Class (lift)
import Control.Parallel (parOneOf)
import Data.Maybe (Maybe(..), maybe)
import Data.Traversable (for_, traverse, traverse_)
import Data.Tuple.Nested ((/\))
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Effect.Exception (Error)
import Node.Stream.Object as O
import Pipes (await, yield)
import Pipes (for) as P
import Pipes.Core (Consumer, Pipe, Producer, Producer_)
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
        O.ReadWouldBlock -> do
          ended <- liftEffect $ O.isReadableEnded r
          if ended then do
            yield Nothing
            cleanup cancel
          else
            liftAff (O.awaitReadableOrClosed r) $> Loop { error, cancel }
  in
    do
      e <- liftEffect $ O.withErrorST r
      tailRecM go e

-- | Convert a `Writable` stream to a `Pipe`.
-- |
-- | When `Nothing` is piped to this, the stream will
-- | be `end`ed, and the pipe will noop if invoked again.
fromWritable :: forall s a m. MonadThrow Error m => MonadAff m => O.Write s a => s -> Consumer (Maybe a) m Unit
fromWritable w = do
  { error: errorST, cancel: removeErrorListener } <- liftEffect $ O.withErrorST w

  let
    maybeThrow = traverse_ throwError =<< liftEffect (liftST $ STRef.read errorST)

    waitCanWrite = do
      shouldWait <- liftEffect $ O.needsDrain w
      when shouldWait $ liftAff $ O.awaitWritableOrClosed w

    cleanup = do
      liftAff $ O.awaitFinished w
      maybeThrow
      liftEffect removeErrorListener

    onEOS = liftEffect (O.end w) *> cleanup $> Done unit
    onChunk a = liftEffect (O.write w a) $> Loop unit

    go _ = do
      maybeThrow
      waitCanWrite
      ended <- liftEffect $ O.isWritableEnded w
      if ended then
        cleanup $> Done unit
      else
        await >>= maybe onEOS onChunk

  tailRecM go unit

-- | Convert a `Transform` stream to a `Pipe`.
-- |
-- | When `Nothing` is piped to this, the `Transform` stream will
-- | be `end`ed, and the pipe will noop if invoked again.
fromTransform :: forall a b m. MonadThrow Error m => MonadAff m => O.Transform a b -> Pipe (Maybe a) (Maybe b) m Unit
fromTransform t = do
  { error: errorST, cancel: removeErrorListener } <- liftEffect $ O.withErrorST t
  let
    maybeThrow = traverse_ throwError =<< liftEffect (liftST $ STRef.read errorST)

    cleanup = do
      flip tailRecM unit $ const do
        liftAff $ O.awaitReadableOrClosed t
        readEnded <- liftEffect $ O.isReadableEnded t
        yieldWhileReadable
        pure $ (if readEnded then Done else Loop) unit

      liftAff $ O.awaitFinished t
      maybeThrow
      liftEffect $ removeErrorListener
      yield Nothing

    yieldWhileReadable = void $ whileJust $ maybeYield1

    maybeYield1 = traverse (\a -> yield (Just a) $> Just unit) =<< O.maybeReadResult <$> liftEffect (O.read t)

    onEOS = liftEffect (O.end t) *> cleanup $> Done unit
    onChunk a = liftEffect (O.write t a) $> Loop unit

    go _ = do
      maybeThrow
      needsDrain <- liftEffect $ O.needsDrain t
      ended <- liftEffect $ O.isWritableEnded t
      if needsDrain then do
        yieldWhileReadable
        liftAff $ parOneOf [O.awaitWritableOrClosed t, O.awaitReadableOrClosed t]
        pure $ Loop unit
      else if ended then
        cleanup $> Done unit
      else
        await >>= maybe onEOS onChunk

  tailRecM go unit

-- | Given a `Producer` of values, wrap them in `Just`.
-- |
-- | Before the `Producer` exits, emits `Nothing` as an End-of-stream signal.
withEOS :: forall a m. Monad m => Producer a m Unit -> Producer (Maybe a) m Unit
withEOS a = do
  P.for a (yield <<< Just)
  yield Nothing

-- | Strip a pipeline of the EOS signal
unEOS :: forall a m. Monad m => Pipe (Maybe a) a m Unit
unEOS = tailRecM (const $ maybe (pure $ Done unit) (\a -> yield a $> Loop unit) =<< await) unit

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
