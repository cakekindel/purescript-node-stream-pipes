module Pipes.Async where

import Prelude hiding (join)

import Control.Alternative (class Alternative, empty, guard)
import Control.Monad.Cont (class MonadTrans)
import Control.Monad.Error.Class (class MonadError, class MonadThrow, catchError, throwError)
import Control.Monad.Except (ExceptT, runExceptT)
import Control.Monad.Fork.Class (class MonadBracket, class MonadFork, fork)
import Control.Monad.Maybe.Trans (MaybeT(..), runMaybeT)
import Control.Monad.Morph (class MFunctor, hoist)
import Control.Monad.Rec.Class (class MonadRec, Step(..), tailRecM)
import Control.Monad.ST.Class (liftST)
import Control.Monad.ST.Ref (STRef)
import Control.Monad.ST.Ref as ST.Ref
import Control.Monad.Trans.Class (lift)
import Control.Parallel (class Parallel, parOneOf)
import Data.Array as Array
import Data.DateTime.Instant as Instant
import Data.Either (Either(..), either)
import Data.Foldable (class Foldable, fold)
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe(..), fromMaybe, isNothing)
import Data.Newtype (unwrap)
import Data.Show.Generic (genericShow)
import Data.Time.Duration (Milliseconds)
import Data.Traversable (class Traversable, traverse, traverse_)
import Data.Tuple.Nested (type (/\), (/\))
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (class MonadEffect, liftEffect)
import Effect.Console (log)
import Effect.Now as Now
import Pipes (await, yield)
import Pipes.Collect as Collect
import Pipes.Core (Pipe, Proxy, Producer)

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
derive instance Foldable ReadResult
derive instance Traversable ReadResult
instance Show a => Show (ReadResult a) where show = genericShow

type AsyncIO a b m r =
  { write :: a -> m WriteResult
  , read :: m (ReadResult b)
  , awaitWrite :: m WriteSignal
  , awaitRead :: m ReadSignal
  }
  /\ AsyncPipe a b m r

-- | An `AsyncPipe` is a `Pipe`-like struct that allows
-- | concurrently reading from a `Producer` and writing to a `Consumer`.
-- |
-- | An implementation of `AsyncPipe` for Node `Transform` streams
-- | is provided in `Pipes.Node.Stream`.
data AsyncPipe a b m r
  -- | A pure return value
  = Pure r
  -- | An `AsyncPipe` behind a computation
  | M (m (AsyncPipe a b m r))
  -- | Interface to write & read from the backing resource
  | AsyncIO (AsyncIO a b m r)

-- | Modify request / response types
mapIO :: forall aa ab ba bb m r. Monad m => (ab -> aa) -> (ba -> bb) -> AsyncPipe aa ba m r -> AsyncPipe ab bb m r
mapIO _ _ (Pure a) = Pure a
mapIO a b (M m) = M $ mapIO a b <$> m
mapIO a b (AsyncIO ({write, awaitWrite, read, awaitRead} /\ m)) =
  AsyncIO $ {write: write <<< a, awaitWrite, read: map b <$> read, awaitRead} /\ mapIO a b m

-- | Modify request / response types
bindIO :: forall aa ab ba bb m r. Monad m => (ab -> m aa) -> (ba -> m bb) -> AsyncPipe aa ba m r -> AsyncPipe ab bb m r
bindIO _ _ (Pure a) = Pure a
bindIO a b (M m) = M $ bindIO a b <$> m
bindIO a b (AsyncIO ({write, awaitWrite, read, awaitRead} /\ m)) =
  AsyncIO $ {write: flip bind write <<< a, awaitWrite, read: traverse b =<< read, awaitRead} /\ bindIO a b m

-- | Remove the `AsyncPipe` wrapper by discarding the IO
stripIO :: forall a b m r. Monad m => AsyncPipe a b m r -> m r
stripIO (Pure r) = pure r
stripIO (M m) = m >>= stripIO
stripIO (AsyncIO (_ /\ m)) = stripIO m

-- | Execute the `AsyncPipe` monad stack until `AsyncIO` is reached (if any)
getAsyncIO :: forall a b m r. Monad m => AsyncPipe a b m r -> m (Maybe (AsyncIO a b m r))
getAsyncIO (AsyncIO a) = pure $ Just a
getAsyncIO (M m) = m >>= getAsyncIO
getAsyncIO (Pure _) = pure Nothing

instance MonadTrans (AsyncPipe a b) where
  lift = M <<< map Pure

instance MFunctor (AsyncPipe a b) where
  hoist _ (Pure a) = Pure a
  hoist f (M m) = M $ f $ hoist f <$> m
  hoist f (AsyncIO ({read, write, awaitWrite, awaitRead} /\ m)) =
    AsyncIO
      $ { read: f read
        , write: f <<< write
        , awaitWrite: f awaitWrite
        , awaitRead: f awaitRead
        }
        /\ hoist f m

instance Monad m => Functor (AsyncPipe a b m) where
  map f (Pure r) = Pure $ f r
  map f (M m) = M $ map f <$> m
  map f (AsyncIO (io /\ m)) = AsyncIO $ io /\ (f <$> m)

instance Monad m => Apply (AsyncPipe a b m) where
  apply (Pure f) ma = f <$> ma
  apply (M mf) ma = M $ (_ <*> ma) <$> mf
  apply (AsyncIO (io /\ mf)) ma = AsyncIO $ io /\ (mf <*> ma)

instance Monad m => Applicative (AsyncPipe a b m) where
  pure = Pure

instance Monad m => Bind (AsyncPipe a b m) where
  bind (Pure a) f = f a
  bind (M ma) f = M $ (_ >>= f) <$> ma
  bind (AsyncIO (io /\ m)) f = AsyncIO $ io /\ (m >>= f)

instance Monad m => Monad (AsyncPipe a b m)

instance MonadThrow e m => MonadThrow e (AsyncPipe a b m) where
  throwError = lift <<< throwError

instance MonadError e m => MonadError e (AsyncPipe a b m) where
  catchError m f = lift $ catchError (stripIO m) (stripIO <<< f)

instance MonadEffect m => MonadEffect (AsyncPipe a b m) where
  liftEffect = lift <<< liftEffect

instance MonadAff m => MonadAff (AsyncPipe a b m) where
  liftAff = lift <<< liftAff

-- | Wraps all fields of an `AsyncPipe` with logging to debug
-- | behavior and timing.
debug :: forall a b m r. MonadAff m => String -> AsyncPipe (Maybe a) (Maybe b) m r -> AsyncPipe (Maybe a) (Maybe b) m r
debug c m =
  let
    logL :: forall m'. MonadEffect m' => _ -> m' Unit
    logL msg = liftEffect $ log $ "[" <> c <> "] " <> msg
    logR :: forall m'. MonadEffect m' => _ -> m' Unit
    logR msg = liftEffect $ log $ "[" <> c <> "] " <> fold (Array.replicate 20 " ") <> msg

    time :: forall m' a'. MonadEffect m' => m' a' -> m' (Milliseconds /\ a')
    time ma = do
      start <- liftEffect Now.now
      a <- ma
      end <- liftEffect Now.now
      pure $ (end `Instant.diff` start) /\ a
  in
    flip bind (fromMaybe m)
    $ runMaybeT do
      (io /\ done') <- MaybeT $ lift $ getAsyncIO m
      let
        write a = do
          logL "write >"
          elapsed /\ w <- time $ io.write a
          logL $ "< write " <> show w <> " (" <> show (unwrap elapsed) <> "ms)"
          pure w

        read = do
          logR "read >"
          elapsed /\ r <- time $ io.read
          logR $ "< read " <> show (map (const unit) <$> r) <> " (" <> show (unwrap elapsed) <> "ms)"
          pure r

        awaitWrite = do
          logL "awaitWrite >"
          elapsed /\ w <- time $ io.awaitWrite
          logL $ "< awaitWrite " <> show w <> " (" <> show (unwrap elapsed) <> "ms)"
          pure w

        awaitRead = do
          logR "awaitRead >"
          elapsed /\ r <- time $ io.awaitRead
          logR $ "< awaitRead " <> show r <> " (" <> show (unwrap elapsed) <> "ms)"
          pure r

        done = do
          logL "done >"
          elapsed /\ r <- time done'
          logL $ "< done (" <> show (unwrap elapsed) <> "ms)"
          pure r
      pure $ AsyncIO $ {write, read, awaitWrite, awaitRead} /\ done

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
sync :: forall a b f p e m r. MonadError e m => Alternative p => Parallel p m => MonadFork f m => MonadAff m => AsyncPipe (Maybe a) (Maybe b) m r -> Pipe (Maybe a) (Maybe b) m r
sync m =
  let
    liftPipe :: forall r'. (Proxy _ _ _ _ m) r' -> ExceptT (Step _ _) (Proxy _ _ _ _ m) r'
    liftPipe = lift

    liftM :: forall r'. m r' -> ExceptT (Step _ _) (Proxy _ _ _ _ m) r'
    liftM = liftPipe <<< lift
  in
  lift (getAsyncIO m) >>=
    case _ of
      Nothing -> lift $ stripIO m
      Just ({write, awaitWrite, read, awaitRead} /\ done) ->
         let
           awaitRW onR onW =
             liftM (parOneOf [Right <$> awaitWrite, Left <$> awaitRead])
             >>= either (const onR) onW

           wSignal WriteSignalOk = WriteAgain
           wSignal WriteSignalEnded = WriteEnded

           tailRecEarly f a = tailRecM (map (either identity identity) <<< runExceptT <<< f) a
           continue a = throwError (Loop a)
           break = (Done <$> liftM (stripIO done)) >>= throwError
         in do
           flip tailRecEarly WriteAgain \writable -> do
             rb <- liftM read
             case rb of
               ReadWouldBlock
                 | writable == WriteEnded -> liftM awaitRead *> continue writable
                 | writable == WriteNeedsDrain -> awaitRW (continue writable) (continue <<< wSignal)
                 | otherwise -> pure unit
               ReadOk (Just b) -> liftPipe (yield $ Just b) *> continue writable
               ReadOk Nothing -> liftPipe (yield Nothing) *> break

             when (writable /= WriteAgain) $ continue writable

             a <- liftPipe await
             writable' <- liftM $ write a
             when (isNothing a) $ continue WriteEnded
             pure $ Loop writable'

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
  :: forall e f m a b
   . MonadRec m
  => MonadAff m
  => MonadBracket e f m
  => Producer (Maybe a) m Unit
  -> AsyncPipe (Maybe a) (Maybe b) m Unit
  -> Producer (Maybe b) m Unit
pipeAsync prod m =
  lift (getAsyncIO m)
    >>= case _ of
          Nothing -> pure unit
          Just ({write, read, awaitWrite, awaitRead} /\ done) -> do
            errST :: STRef _ (Maybe e) <- lift $ liftEffect $ liftST $ ST.Ref.new Nothing
            killST :: STRef _ Boolean <- lift $ liftEffect $ liftST $ ST.Ref.new false

            let
              killThread = void $ liftEffect $ liftST $ ST.Ref.write true killST
              threadKilled = liftEffect $ liftST $ ST.Ref.read killST
              putThreadError = void <<< liftEffect <<< liftST <<< flip ST.Ref.write errST <<< Just
              getThreadError = liftEffect $ liftST $ ST.Ref.read errST

              rx a = do
                killed <- threadKilled
                guard $ not killed
                w <- lift $ write a
                case w of
                  WriteNeedsDrain -> lift $ void awaitWrite
                  WriteEnded -> empty
                  WriteAgain -> pure unit

              spawn = lift <<< fork <<< flip catchError putThreadError

            _thread <- spawn $ void $ runMaybeT $ Collect.foreach rx (hoist lift prod)

            flip tailRecM unit $ const do
              getThreadError >>= traverse_ throwError
              rb <- lift read
              case rb of
                ReadOk (Just b) -> yield (Just b) $> Loop unit
                ReadOk Nothing -> killThread *> yield Nothing $> Done unit
                ReadWouldBlock -> void (lift awaitRead) $> Loop unit

            lift $ stripIO done

infixl 7 pipeAsync as >-/->
