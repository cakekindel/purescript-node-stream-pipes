module Pipes.Util where

import Prelude

import Control.Monad.Maybe.Trans (MaybeT(..), runMaybeT)
import Control.Monad.Rec.Class (whileJust)
import Control.Monad.ST.Class (liftST)
import Control.Monad.ST.Ref (STRef)
import Control.Monad.ST.Ref as STRef
import Control.Monad.Trans.Class (lift)
import Data.Array.ST (STArray)
import Data.Array.ST as Array.ST
import Data.Maybe (Maybe(..))
import Effect.Class (class MonadEffect, liftEffect)
import Pipes (await, yield)
import Pipes.Core (Pipe)

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
