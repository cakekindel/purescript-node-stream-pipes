module Pipes.String where

import Prelude

import Control.Monad.Maybe.Trans (MaybeT(..), runMaybeT)
import Control.Monad.Rec.Class (whileJust)
import Control.Monad.ST.Class (liftST)
import Control.Monad.Trans.Class (lift)
import Data.Array.ST as Array.ST
import Data.Foldable (fold, traverse_)
import Data.Maybe (Maybe(..))
import Data.String (Pattern)
import Data.String as String
import Effect.Class (class MonadEffect, liftEffect)
import Pipes (await, yield)
import Pipes.Core (Pipe)

-- | Accumulate string chunks until `pat` is seen, then `yield` the buffered
-- | string up to (and not including) the pattern.
-- |
-- | When end-of-stream is reached, yields the remaining buffered string then `Nothing`.
-- |
-- | ```
-- | toList $ yield "foo,bar,baz" >-> split ","
-- | -- "foo" : "bar" : "baz" : Nil
-- | ```
split :: forall m. MonadEffect m => Pattern -> Pipe (Maybe String) (Maybe String) m Unit
split pat = do
  buf <- liftEffect $ liftST $ Array.ST.new
  whileJust $ runMaybeT do
    chunk <- MaybeT await
    case String.indexOf pat chunk of
      Nothing -> void $ liftEffect $ liftST $ Array.ST.push chunk buf
      Just ix -> do
        let
          { before, after } = String.splitAt ix chunk
        len <- liftEffect $ liftST $ Array.ST.length buf
        buf' <- liftEffect $ liftST $ Array.ST.splice 0 len [] buf
        lift $ yield $ Just $ (fold buf') <> before
        void $ liftEffect $ liftST $ Array.ST.push (String.drop 1 after) buf
  buf' <- liftEffect $ liftST $ Array.ST.unsafeFreeze buf
  traverse_ yield (Just <$> String.split pat (fold buf'))
  yield Nothing
