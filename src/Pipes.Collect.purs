module Pipes.Collect where

import Prelude

import Control.Monad.Rec.Class (class MonadRec, Step(..), tailRecM)
import Control.Monad.ST.Class (liftST)
import Data.Array.ST as Array.ST
import Data.HashMap (HashMap)
import Data.HashMap as HashMap
import Data.Hashable (class Hashable)
import Data.List (List)
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Tuple.Nested (type (/\), (/\))
import Effect.Class (class MonadEffect, liftEffect)
import Foreign.Object (Object)
import Foreign.Object.ST as Object.ST
import Foreign.Object.ST.Unsafe as Object.ST.Unsafe
import Pipes.Core (Producer)
import Pipes.Internal (Proxy(..))

-- | Fold every value produced with a monadic action
-- |
-- | Uses `MonadRec`, supporting producers of arbitrary length.
traverse :: forall a b m. MonadRec m => (b -> a -> m b) -> b -> Producer a m Unit -> m b
traverse f b0 p0 =
  flip tailRecM (p0 /\ b0) \(p /\ b) ->
    case p of
      Respond a m -> Loop <$> (m unit /\ _) <$> f b a
      M m -> Loop <$> (_ /\ b) <$> m
      Request _ _ -> pure $ Done b
      Pure _ -> pure $ Done b

-- | Fold every value produced
-- |
-- | Uses `MonadRec`, supporting producers of arbitrary length.
fold :: forall a b m. MonadRec m => (b -> a -> b) -> b -> Producer a m Unit -> m b
fold f b0 p0 = traverse (\b a -> pure $ f b a) b0 p0

-- | Execute a monadic action on every item in a producer.
-- |
-- | Uses `MonadRec`, supporting producers of arbitrary length.
foreach :: forall a m. MonadRec m => (a -> m Unit) -> Producer a m Unit -> m Unit
foreach f p0 = traverse (\_ a -> f a) unit p0

-- | Collect all values from a `Producer` into an array.
toArray :: forall a m. MonadRec m => MonadEffect m => Producer a m Unit -> m (Array a)
toArray p = do
  st <- liftEffect $ liftST $ Array.ST.new
  foreach (void <<< liftEffect <<< liftST <<< flip Array.ST.push st) p
  liftEffect $ liftST $ Array.ST.unsafeFreeze st

-- | Collect all values from a `Producer` into a list.
toList :: forall a m. MonadRec m => MonadEffect m => Producer a m Unit -> m (List a)
toList = map List.reverse <<< fold (flip List.Cons) List.Nil

-- | Collect all values from a `Producer` into a Javascript Object.
toObject :: forall a m. MonadRec m => MonadEffect m => Producer (String /\ a) m Unit -> m (Object a)
toObject p = do
  st <- liftEffect $ liftST $ Object.ST.new
  foreach (\(k /\ v) -> void $ liftEffect $ liftST $ Object.ST.poke k v st) p
  liftEffect $ liftST $ Object.ST.Unsafe.unsafeFreeze st

-- | Collect all values from a `Producer` into a `HashMap`
toHashMap :: forall k v m. Hashable k => MonadRec m => Producer (k /\ v) m Unit -> m (HashMap k v)
toHashMap = fold (\map (k /\ v) -> HashMap.insert k v map) HashMap.empty

-- | Collect all values from a `Producer` into a `Map`
toMap :: forall k v m. Ord k => MonadRec m => Producer (k /\ v) m Unit -> m (Map k v)
toMap = fold (\map (k /\ v) -> Map.insert k v map) Map.empty
