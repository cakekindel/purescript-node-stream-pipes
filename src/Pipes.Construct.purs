module Pipes.Construct where

import Prelude

import Control.Monad.Maybe.Trans (MaybeT(..), runMaybeT)
import Control.Monad.Rec.Class (class MonadRec, Step(..), tailRecM)
import Control.Monad.ST.Class (liftST)
import Control.Monad.Trans.Class (lift)
import Data.Array as Array
import Data.Array.ST as Array.ST
import Data.List (List)
import Data.List as List
import Data.Map (Map)
import Data.Map.Internal as Map.Internal
import Data.Maybe (fromMaybe)
import Data.Tuple.Nested (type (/\), (/\))
import Effect.Class (class MonadEffect, liftEffect)
import Pipes (yield, (>->))
import Pipes.Core (Producer)
import Pipes.Prelude as Pipe
import Pipes.Util as Pipe.Util

-- Producer that will emit monotonically increasing integers
-- ex `monotonic 0 -> 0 1 2 3 4 5 6 7 ..`
monotonic :: forall m. MonadRec m => Int -> Producer Int m Unit
monotonic start = flip tailRecM start \n -> yield n $> Loop (n + 1)

-- Producer that will emit integers from `start` (inclusive) to `end` (exclusive)
range :: forall m. MonadRec m => Int -> Int -> Producer Int m Unit
range start end = monotonic start >-> Pipe.take end

-- | Stack-safe producer that yields every value in an Array
eachArray :: forall a m. MonadRec m => Array a -> Producer a m Unit
eachArray as = monotonic 0 >-> Pipe.map (Array.index as) >-> Pipe.Util.whileJust

-- | Stack-safe producer that yields every value in a List
eachList :: forall a m. MonadRec m => List a -> Producer a m Unit
eachList init =
  flip tailRecM init \as -> fromMaybe (Done unit) <$> runMaybeT do
    head <- MaybeT $ pure $ List.head as
    tail <- MaybeT $ pure $ List.tail as
    lift $ yield head
    pure $ Loop tail

-- | Stack-safe producer that yields every value in a Map
eachMap :: forall k v m. MonadEffect m => MonadRec m => Map k v -> Producer (k /\ v) m Unit
eachMap init = do
  stack <- liftEffect $ liftST $ Array.ST.new
  let
    push a = void $ liftEffect $ liftST $ Array.ST.push a stack
    pop = liftEffect $ liftST $ Array.ST.pop stack
  flip tailRecM init case _ of
    Map.Internal.Leaf -> fromMaybe (Done unit) <$> runMaybeT do
      a <- MaybeT pop
      pure $ Loop a
    Map.Internal.Node _ _ k v Map.Internal.Leaf Map.Internal.Leaf -> do
      yield $ k /\ v
      pure $ Loop Map.Internal.Leaf
    Map.Internal.Node _ _ k v Map.Internal.Leaf r -> do
      yield $ k /\ v
      pure $ Loop r
    Map.Internal.Node a b k v l r -> do
      push $ Map.Internal.Node a b k v Map.Internal.Leaf r
      pure $ Loop l
