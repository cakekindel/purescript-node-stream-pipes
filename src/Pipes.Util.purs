module Pipes.Util where

import Prelude

import Control.Monad.Rec.Class (whileJust)
import Control.Monad.ST.Class (liftST)
import Control.Monad.ST.Ref as STRef
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
  isFirst <- liftEffect $ liftST $ STRef.new true
  whileJust do
    ma <- await
    isFirst' <- liftEffect $ liftST $ STRef.read isFirst
    case ma of
      Just a
        | isFirst' -> do
          void $ liftEffect $ liftST $ STRef.write false isFirst
          yield $ Just a
        | otherwise -> yield (Just sep) *>  yield (Just a)
      Nothing -> yield Nothing
    pure $ void ma
