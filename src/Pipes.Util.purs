module Pipes.Util where

import Prelude

import Control.Monad.Maybe.Trans (MaybeT(..), runMaybeT)
import Control.Monad.Rec.Class (class MonadRec, Step(..), forever, tailRecM)
import Control.Monad.Rec.Class as Rec
import Control.Monad.ST.Class (liftST)
import Control.Monad.ST.Ref (STRef)
import Control.Monad.ST.Ref as STRef
import Control.Monad.Trans.Class (lift)
import Data.Array.ST (STArray)
import Data.Array.ST as Array.ST
import Data.Either (hush)
import Data.HashSet as HashSet
import Data.Hashable (class Hashable, hash)
import Data.List.NonEmpty (NonEmptyList)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Traversable (traverse_)
import Data.Tuple.Nested (type (/\), (/\))
import Effect.Class (class MonadEffect, liftEffect)
import Node.Buffer (Buffer)
import Node.Buffer as Buffer
import Pipes (await, yield)
import Pipes as Pipes
import Pipes.Core (Pipe, Producer)
import Pipes.Internal (Proxy(..))

-- | Re-yield all `Just`s, and close when `Nothing` is encountered
whileJust :: forall m a. MonadRec m => Pipe (Maybe a) a m Unit
whileJust = do
  first <- await
  flip tailRecM first $ \ma -> fromMaybe (Done unit) <$> runMaybeT do
    a <- MaybeT $ pure ma
    lift $ yield a
    lift $ Loop <$> await

-- | Yields a separator value `sep` between received values
-- |
-- | ```purescript
-- | toList $ (yield "a" *> yield "b" *> yield "c") >-> intersperse ","
-- | -- "a" : "," : "b" : "," : "c" : Nil
-- | ```
intersperse :: forall m a. MonadEffect m => a -> Pipe (Maybe a) (Maybe a) m Unit
intersperse sep = do
  isFirstST <- liftEffect $ liftST $ STRef.new true
  let
    getIsFirst = liftEffect $ liftST $ STRef.read isFirstST
    markNotFirst = void $ liftEffect $ liftST $ STRef.write false isFirstST

  Rec.whileJust $ runMaybeT do
    a <- MaybeT await
    isFirst <- getIsFirst
    if isFirst then markNotFirst else lift $ yield $ Just sep
    lift $ yield $ Just a

  yield Nothing

-- Pair every emitted value from 2 producers together, exiting when either exits.
zip :: forall a b m. MonadRec m => Producer a m Unit -> Producer b m Unit -> Producer (a /\ b) m Unit
zip as bs =
  flip tailRecM (as /\ bs) \(as' /\ bs') ->
    fromMaybe (Done unit) <$> runMaybeT do
      a /\ as'' <- MaybeT $ lift $ hush <$> Pipes.next as'
      b /\ bs'' <- MaybeT $ lift $ hush <$> Pipes.next bs'
      lift $ yield $ a /\ b
      pure $ Loop $ as'' /\ bs''

-- | Accumulate values in chunks of a given size.
-- |
-- | If the pipe closes without yielding a multiple of `size` elements,
-- | the remaining elements are yielded at the end.
chunked :: forall m a. MonadEffect m => Int -> Pipe (Maybe a) (Maybe (Array a)) m Unit
chunked size = do
  chunkST :: STRef _ (STArray _ a) <- liftEffect $ liftST $ STRef.new =<< Array.ST.new
  let
    chunkPut a = liftEffect $ liftST do
      chunkArray <- STRef.read chunkST
      void $ Array.ST.push a chunkArray
    chunkLength = liftEffect $ liftST do
      chunkArray <- STRef.read chunkST
      Array.ST.length chunkArray
    chunkTake = liftEffect $ liftST do
      chunkArray <- STRef.read chunkST
      void $ flip STRef.write chunkST =<< Array.ST.new
      Array.ST.unsafeFreeze chunkArray

  Rec.whileJust $ runMaybeT do
    a <- MaybeT await
    chunkPut a
    len <- lift chunkLength
    when (len >= size) do
      chunk <- lift chunkTake
      lift $ yield $ Just chunk
  len <- chunkLength
  when (len > 0) do
    chunk <- chunkTake
    yield $ Just chunk

  yield Nothing

-- | Buffers input to the given size before passing to subsequent pipes
buffered :: forall m. MonadEffect m => Int -> Pipe (Maybe Buffer) (Maybe Buffer) m Unit
buffered size = do
  chunkST :: STRef _ (Maybe Buffer) <- liftEffect $ liftST $ STRef.new Nothing

  let
    chunkClear = liftEffect $ liftST $ STRef.write Nothing chunkST
    chunkPeek = liftEffect $ liftST $ STRef.read chunkST
    chunkLen = maybe (pure 0) (liftEffect <<< Buffer.size) =<< chunkPeek
    chunkPut b = liftEffect do
      new <- liftST (STRef.read chunkST) >>= maybe (pure b) (\a -> Buffer.concat [a, b])
      void $ liftST $ STRef.write (Just new) chunkST
      pure new

  Rec.whileJust $ runMaybeT do
    a <- MaybeT await
    buf <- chunkPut a
    len <- lift chunkLen
    when (len > size) $ chunkClear *> lift (yield $ Just buf)

  len <- chunkLen
  chunkPeek >>= traverse_ (when (len > 0) <<< yield <<< Just)
  yield Nothing

-- | Equivalent of unix `uniq`, filtering out duplicate values passed to it.
-- |
-- | Uses a `HashSet` of hashes of `a`; for `n` elements `awaited`, this pipe
-- | will occupy O(n) space, and `yield` in O(1) time.
uniqHash :: forall a m. Hashable a => MonadEffect m => MonadRec m => Pipe a a m Unit
uniqHash = do
  seenHashesST <- liftEffect $ liftST $ STRef.new HashSet.empty
  forever do
    a <- await
    seenHashes <- liftEffect $ liftST $ STRef.read seenHashesST
    when (not $ HashSet.member (hash a) seenHashes) do
      void $ liftEffect $ liftST $ STRef.modify (HashSet.insert $ hash a) seenHashesST
      yield a

-- | The result of a single step forward of a pipe.
data InvokeResult a b m
  -- | The pipe `await`ed the value, but did not `yield` a response.
  = DidNotYield (Pipe a b m Unit)
  -- | The pipe `await`ed the value, and `yield`ed 1 or more responses.
  | Yielded (NonEmptyList b /\ Pipe a b m Unit)
  -- | The pipe `await`ed the value, and exited.
  | Exited

data IntermediateInvokeResult a b m
  = IDidNotYield (Pipe a b m Unit)
  | IYielded (NonEmptyList b /\ Pipe a b m Unit)
  | IDidNotAwait (Pipe a b m Unit)

-- | Pass a single value to a pipe, returning the result of the pipe's invocation.
invoke :: forall m a b. Monad m => Pipe a b m Unit -> a -> m (InvokeResult a b m)
invoke m a =
  let
    go :: IntermediateInvokeResult a b m -> m (InvokeResult a b m)
    go (IYielded (as /\ n)) =
      case n of
        Request _ _ -> pure $ Yielded $ as /\ n
        Respond rep f -> go (IYielded $ (as <> pure rep) /\ f unit)
        M o -> go =<< IYielded <$> (as /\ _) <$> o
        Pure _ -> pure Exited
    go (IDidNotYield n) =
      case n of
        Request _ _ -> pure $ DidNotYield n
        Respond rep f -> go (IYielded $ pure rep /\ f unit)
        M o -> go =<< IDidNotYield <$> o
        Pure _ -> pure Exited
    go (IDidNotAwait n) =
      case n of
        Request _ f -> go (IDidNotYield (f a))
        Respond rep f -> go (IYielded $ pure rep /\ f unit)
        M o -> go =<< IDidNotAwait <$> o
        Pure _ -> pure Exited
  in
    go (IDidNotAwait m)
