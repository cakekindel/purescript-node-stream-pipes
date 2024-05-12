module Pipes.Util where

import Prelude

import Control.Monad.Maybe.Trans (MaybeT(..), runMaybeT)
import Control.Monad.Rec.Class (class MonadRec, forever, whileJust)
import Control.Monad.ST.Class (liftST)
import Control.Monad.ST.Ref (STRef)
import Control.Monad.ST.Ref as STRef
import Control.Monad.Trans.Class (lift)
import Data.Array.ST (STArray)
import Data.Array.ST as Array.ST
import Data.HashSet as HashSet
import Data.Hashable (class Hashable, hash)
import Data.List.NonEmpty (NonEmptyList)
import Data.Maybe (Maybe(..))
import Data.Tuple.Nested (type (/\), (/\))
import Effect.Class (class MonadEffect, liftEffect)
import Pipes (await, yield)
import Pipes.Core (Pipe)
import Pipes.Internal (Proxy(..))

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

  whileJust $ runMaybeT do
    a <- MaybeT await
    isFirst <- getIsFirst
    if isFirst then markNotFirst else lift $ yield $ Just sep
    lift $ yield $ Just a

  yield Nothing

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

  whileJust $ runMaybeT do
    a <- MaybeT await
    chunkPut a
    len <- chunkLength
    when (len >= size) $ lift $ yield =<< Just <$> chunkTake
  yield =<< Just <$> chunkTake
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
