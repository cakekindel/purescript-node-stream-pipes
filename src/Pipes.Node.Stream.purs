module Pipes.Node.Stream where

import Prelude hiding (join)

import Control.Monad.Error.Class (class MonadThrow, throwError)
import Control.Monad.Rec.Class (class MonadRec, Step(..), tailRecM)
import Control.Monad.ST.Class (liftST)
import Control.Monad.ST.Global (Global)
import Control.Monad.ST.Ref (STRef)
import Control.Monad.ST.Ref as ST.Ref
import Control.Monad.ST.Ref as STRef
import Control.Monad.Trans.Class (lift)
import Data.Maybe (Maybe(..), maybe)
import Data.Traversable (for_, traverse_)
import Data.Tuple.Nested ((/\))
import Effect (Effect)
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (class MonadEffect, liftEffect)
import Effect.Exception (Error)
import Node.Stream.Object (WriteResult(..), maybeReadResult)
import Node.Stream.Object as O
import Pipes (await, yield)
import Pipes (for) as P
import Pipes.Async (AsyncPipe(..))
import Pipes.Async as AsyncPipe
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

newtype TransformContext a b =
  TransformContext
    { stream :: O.Transform a b
    , removeErrorListener :: Effect Unit
    , errorST :: STRef Global (Maybe Error)
    }

transformCleanup :: forall m a b. MonadEffect m => TransformContext a b -> m Unit
transformCleanup (TransformContext {removeErrorListener}) = do
  liftEffect removeErrorListener

transformStream :: forall a b. TransformContext a b -> O.Transform a b
transformStream (TransformContext {stream}) = stream

transformRethrow :: forall m a b. MonadThrow Error m => MonadEffect m => TransformContext a b -> m Unit
transformRethrow (TransformContext {errorST}) = traverse_ throwError =<< liftEffect (liftST $ ST.Ref.read errorST)

-- | Convert a `Transform` stream to an `AsyncPipe`.
fromTransform
  :: forall a b m
   . MonadThrow Error m
  => MonadAff m
  => Effect (O.Transform a b)
  -> AsyncPipe (TransformContext a b) m (Maybe a) (Maybe b)
fromTransform t =
  let
    init = do
      stream <- liftEffect t
      { error: errorST, cancel: removeErrorListener } <- liftEffect $ O.withErrorST stream
      pure $ TransformContext {errorST, removeErrorListener, stream}
    write x Nothing = do
      let s = transformStream x
      liftEffect $ O.end s
      pure AsyncPipe.WriteEnded
    write x (Just a) = do
      transformRethrow x
      let s = transformStream x
      w <- liftEffect $ O.write s a
      pure $ case w of
        WriteOk -> AsyncPipe.WriteAgain
        WriteWouldBlock -> AsyncPipe.WriteNeedsDrain
    awaitWrite x = do
      transformRethrow x
      let s = transformStream x
      liftAff $ O.awaitWritableOrClosed s
      ended <- liftEffect $ O.isWritableEnded s
      if ended then
        pure $ AsyncPipe.WriteSignalEnded
      else do
        liftAff $ O.awaitWritableOrClosed s
        pure $ AsyncPipe.WriteSignalOk
    read x =
      do
        transformRethrow x
        let s = transformStream x
        readEnded <- liftEffect $ O.isReadableEnded s
        if readEnded then do
          pure $ AsyncPipe.ReadOk Nothing
        else
          maybe AsyncPipe.ReadWouldBlock (AsyncPipe.ReadOk <<< Just) <$> maybeReadResult <$> liftEffect (O.read s)
    awaitRead x = do
      transformRethrow x
      let s = transformStream x
      ended <- liftEffect $ O.isReadableEnded s
      if ended then
        pure $ AsyncPipe.ReadSignalEnded
      else do
        liftAff $ O.awaitReadableOrClosed s
        pure $ AsyncPipe.ReadSignalOk
  in
    AsyncPipe init write awaitWrite read awaitRead

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
