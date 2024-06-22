module Pipes.Async where

import Prelude hiding (join)

import Control.Alternative (class Alternative, empty, guard)
import Control.Monad.Error.Class (class MonadError, catchError, throwError)
import Control.Monad.Except (ExceptT, runExceptT)
import Control.Monad.Fork.Class (class MonadBracket, class MonadFork, fork)
import Control.Monad.Maybe.Trans (runMaybeT)
import Control.Monad.Morph (hoist)
import Control.Monad.Rec.Class (class MonadRec, Step(..), forever, tailRecM)
import Control.Monad.ST.Class (liftST)
import Control.Monad.ST.Ref (STRef)
import Control.Monad.ST.Ref as ST.Ref
import Control.Monad.Trans.Class (lift)
import Control.Parallel (class Parallel, parOneOf)
import Data.Array (fold)
import Data.Array as Array
import Data.DateTime.Instant as Instant
import Data.Either (Either(..), either)
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe(..), isNothing)
import Data.Newtype (unwrap)
import Data.Show.Generic (genericShow)
import Data.Time.Duration (Milliseconds)
import Data.Traversable (traverse_)
import Data.Tuple.Nested (type (/\), (/\))
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Exception (Error)
import Effect.Now as Now
import Pipes (await, yield)
import Pipes.Collect as Collect
import Pipes.Core (Pipe, Producer, Proxy)

data WriteSignal
  = WriteSignalOk
  | WriteSignalEnded
derive instance Generic WriteSignal _
derive instance Eq WriteSignal
derive instance Ord WriteSignal
instance Show WriteSignal where show = genericShow

instance Discard WriteSignal where
  discard = bind

data ReadSignal
  = ReadSignalOk
  | ReadSignalEnded

derive instance Generic ReadSignal _
derive instance Eq ReadSignal
derive instance Ord ReadSignal
instance Show ReadSignal where show = genericShow

instance Discard ReadSignal where
  discard = bind

data WriteResult
  = WriteAgain
  | WriteNeedsDrain
  | WriteEnded
derive instance Generic WriteResult _
derive instance Eq WriteResult
derive instance Ord WriteResult
instance Show WriteResult where show = genericShow

data ReadResult a
  = ReadOk a
  | ReadWouldBlock
derive instance Generic (ReadResult a) _
derive instance Eq a => Eq (ReadResult a)
derive instance Ord a => Ord (ReadResult a)
derive instance Functor ReadResult
instance Show a => Show (ReadResult a) where show = genericShow

-- | An `AsyncPipe` is a `Pipe`-like struct that allows
-- | concurrently reading from a `Producer` and writing to a `Consumer`.
-- |
-- | An implementation of `AsyncPipe` for Node `Transform` streams
-- | is provided in `Pipes.Node.Stream`.
-- |
-- | ## Fields
-- | - `m x`
-- |    - Initializer
-- | - `x -> a -> m WriteResult`
-- |    - Write a value `a` to the underlying resource
-- | - `x -> m WriteSignal`
-- |    - Block until the pipe is writable again (or writing must stop)
-- | - `x -> m (ReadResult b)`
-- |    - Attempt to read a chunk
-- | - `x -> m ReadSignal`
-- |    - Block until the pipe is readable again (or reading must stop)
data AsyncPipe x a b m =
  AsyncPipe
    (m x)
    (x -> a -> m WriteResult)
    (x -> m WriteSignal)
    (x -> m (ReadResult b))
    (x -> m ReadSignal)

-- | Wraps all fields of an `AsyncPipe` with logging to debug
-- | behavior and timing.
debug :: forall x a b m. MonadAff m => String -> AsyncPipe x a b m -> AsyncPipe x a b m
debug c (AsyncPipe init write awaitWrite read awaitRead) =
  let
    logL m = liftEffect $ log $ "[" <> c <> "] " <> m
    logR m = liftEffect $ log $ "[" <> c <> "] " <> fold (Array.replicate 20 " ") <> m

    time :: forall a'. m a' -> m (Milliseconds /\ a')
    time m = do
      start <- liftEffect Now.now
      a <- m
      end <- liftEffect Now.now
      pure $ (end `Instant.diff` start) /\ a

    init' = do
      logL "init >"
      elapsed /\ x <- time init
      logL $ "< init " <> "(" <> show (unwrap elapsed) <> "ms)"
      pure x

    write' x a = do
      logL "write >"
      elapsed /\ w <- time $ write x a
      logL $ "< write " <> show w <> " (" <> show (unwrap elapsed) <> "ms)"
      pure w

    read' x = do
      logR "read >"
      elapsed /\ r <- time $ read x
      logR $ "< read " <> show (r $> unit) <> " (" <> show (unwrap elapsed) <> "ms)"
      pure r

    awaitWrite' x = do
      logL "awaitWrite >"
      elapsed /\ w <- time $ awaitWrite x
      logL $ "< awaitWrite " <> show w <> " (" <> show (unwrap elapsed) <> "ms)"
      pure w

    awaitRead' x = do
      logR "awaitRead >"
      elapsed /\ r <- time $ awaitRead x
      logR $ "< awaitRead " <> show r <> " (" <> show (unwrap elapsed) <> "ms)"
      pure r
  in
    AsyncPipe init' write' awaitWrite' read' awaitRead'

-- | Convert an `AsyncPipe` to a regular `Pipe`.
-- |
-- | Rather than two concurrently-running halves (producer & consumer),
-- | this requires the `AsyncPipe` to occasionally stop `await`ing data
-- | written by the upstream `Producer` so that it can `yield` to the downstream `Consumer`.
-- |
-- | This implementation chooses to prioritize `yield`ing data to the `Consumer` over
-- | `await`ing written chunks.
-- |
-- | Note that using this limits the potential parallelism of the entire pipeline, ex:
-- |
-- | ```purs
-- | Pipe.FS.read "foo.csv"        -- read
-- |   >-> sync Pipe.CSV.parse     -- parse
-- |   >-> sync Pipe.CBOR.encode   -- encode
-- |   >-> Pipe.FS.write "foo.bin" -- write
-- | ```
-- |
-- | In the above example, this is what happens when the pipeline
-- | is executed:
-- | 1. `write` asks `encode` "do you have any data yet?" (fast)
-- | 1. `encode` asks `parse` "do you have any data yet?" (fast)
-- | 1. `parse` asks `read` "do you have any data yet?" (fast)
-- | 1. `read` passes 1 chunk to `parse` (fast)
-- | 1. `parse` blocks until the chunk is parsed (slow)
-- | 1. `parse` passes 1 chunk to `encode` (fast)
-- | 1. `encode` blocks until the chunk is encoded (slow)
-- | 1. `write` writes the block (fast)
-- |
-- | For larger workloads, changing this to use `asyncPipe` would be preferable, ex:
-- | ```purs
-- | Pipe.FS.read "foo.csv"        -- read
-- |   >-/-> Pipe.CSV.parse        -- parse
-- |   >-/-> Pipe.CBOR.encode      -- encode
-- |   >-> Pipe.FS.write "foo.bin" -- write
-- | ```
-- |
-- | With this change:
-- | * `read` will pass chunks to `parse` as fast as `parse` allows
-- | * `parse` will parse chunks and yield them to `encode` as soon as they're ready
-- | * `encode` will encode chunks and yield them to `write` as soon as they're ready
sync :: forall x a b f p e m. MonadError e m => Alternative p => Parallel p m => MonadFork f m => MonadAff m => AsyncPipe x (Maybe a) (Maybe b) m -> Pipe (Maybe a) (Maybe b) m Unit
sync (AsyncPipe init write awaitWrite read awaitRead) =
  let
    liftPipe :: forall r. (Proxy _ _ _ _ m) r -> ExceptT (Step _ _) (Proxy _ _ _ _ m) r
    liftPipe = lift

    liftM :: forall r. m r -> ExceptT (Step _ _) (Proxy _ _ _ _ m) r
    liftM = liftPipe <<< lift

    continue a = throwError (Loop a)
    break = throwError (Done unit)

    awaitRW x = parOneOf [Right <$> awaitWrite x, Left <$> awaitRead x]

    wSignal WriteSignalOk = WriteAgain
    wSignal WriteSignalEnded = WriteEnded
  in do
    x <- lift init
    flip tailRecM WriteAgain
      \w ->
      map (either identity identity)
      $ runExceptT do
          rb <- liftM $ read x
          case rb of
            ReadWouldBlock
              | w == WriteEnded -> liftM (awaitRead x) *> continue w
              | w == WriteNeedsDrain -> liftM (awaitRW x) >>= either (const $ continue w) (continue <<< wSignal)
              | otherwise -> pure unit
            ReadOk (Just b) -> liftPipe (yield $ Just b) *> continue w
            ReadOk Nothing -> liftPipe (yield Nothing) *> break

          when (w /= WriteAgain) $ continue w

          a <- liftPipe await
          w' <- liftM $ write x a
          when (isNothing a) $ continue WriteEnded
          pure $ Loop w'

-- | Implementation of `(>-/->)`
-- |
-- | In the current `MonadFork` "thread", read data from the `AsyncPipe` as it
-- | is yielded and `yield` to the downstream `Consumer`.
-- |
-- | Concurrently, in a separate thread, read data from the upstream `Producer`
-- | and write to the `AsyncPipe` at max throughput.
-- |
-- | If the producing half fails, the error is caught and rethrown.
-- |
-- | If the consuming half fails, the error is caught, the producing half is killed, and the error is rethrown.
pipeAsync
  :: forall f m x a b
   . MonadRec m
  => MonadAff m
  => MonadBracket Error f m
  => Producer (Maybe a) m Unit
  -> AsyncPipe x (Maybe a) (Maybe b) m
  -> Producer (Maybe b) m Unit
pipeAsync prod (AsyncPipe init write awaitWrite read awaitRead) =
  do
    errST :: STRef _ (Maybe Error) <- lift $ liftEffect $ liftST $ ST.Ref.new Nothing
    killST :: STRef _ Boolean <- lift $ liftEffect $ liftST $ ST.Ref.new false

    let
      killThread = void $ liftEffect $ liftST $ ST.Ref.write true killST
      threadKilled = liftEffect $ liftST $ ST.Ref.read killST
      putThreadError = void <<< liftEffect <<< liftST <<< flip ST.Ref.write errST <<< Just
      getThreadError = liftEffect $ liftST $ ST.Ref.read errST

      rx x a = do
        killed <- threadKilled
        guard $ not killed
        w <- lift $ write x a
        case w of
          WriteNeedsDrain -> lift $ void $ awaitWrite x
          WriteEnded -> empty
          WriteAgain -> pure unit

      spawn = lift <<< fork <<< flip catchError putThreadError

    x <- lift init
    _thread <- spawn $ void $ runMaybeT $ Collect.foreach (rx x) (hoist lift prod)

    forever do
      getThreadError >>= traverse_ throwError
      rb <- lift $ read x
      case rb of
        ReadOk (Just b) -> yield $ Just b
        ReadOk Nothing -> killThread *> yield Nothing
        ReadWouldBlock -> void $ lift (awaitRead x)

infixl 7 pipeAsync as >-/->
