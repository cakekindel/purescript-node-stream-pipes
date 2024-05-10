module Pipes.Collect where

import Prelude

import Control.Monad.Rec.Class (class MonadRec)
import Control.Monad.ST.Class (liftST)
import Data.Array.ST as Array.ST
import Effect.Class (class MonadEffect, liftEffect)
import Pipes (for) as Pipes
import Pipes.Core (Producer)
import Pipes.Core (runEffect) as Pipes

-- | Traverse a pipe, collecting into a mutable array with constant stack usage
collectArray :: forall a m. MonadRec m => MonadEffect m => Producer a m Unit -> m (Array a)
collectArray p = do
  st <- liftEffect $ liftST $ Array.ST.new
  Pipes.runEffect $ Pipes.for p \a -> void $ liftEffect $ liftST $ Array.ST.push a st
  liftEffect $ liftST $ Array.ST.unsafeFreeze st
