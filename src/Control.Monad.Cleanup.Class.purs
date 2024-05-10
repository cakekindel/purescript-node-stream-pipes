module Control.Monad.Cleanup where

import Prelude

import Control.Monad.Error.Class (class MonadError, liftEither, try)
import Control.Monad.State (StateT, modify_, runStateT)
import Data.Tuple.Nested ((/\))

type CleanupT m = StateT (m Unit) m

finally :: forall m. Monad m => (m Unit) -> CleanupT m Unit
finally m = modify_ (_ *> m)

runCleanup :: forall m a. Monad m => CleanupT m a -> m a
runCleanup m = do
  a /\ final <- runStateT m (pure unit)
  final
  pure a

runCleanupE :: forall e m a. MonadError e m => CleanupT m a -> m a
runCleanupE m = do
  ea /\ final <- runStateT (try m) (pure unit)
  final
  liftEither ea
