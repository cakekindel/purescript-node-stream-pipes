module Node.Stream.Object where

import Prelude

import Control.Monad.Error.Class (liftEither)
import Control.Monad.ST.Class (liftST)
import Control.Monad.ST.Global (Global)
import Control.Monad.ST.Ref (STRef)
import Control.Monad.ST.Ref as STRef
import Control.Parallel (parOneOf)
import Data.Either (Either(..))
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe(..))
import Data.Show.Generic (genericShow)
import Effect (Effect)
import Effect.Aff (Aff, effectCanceler, makeAff)
import Effect.Aff as Aff
import Effect.Class (liftEffect)
import Effect.Exception (Error, error)
import Effect.Uncurried (mkEffectFn1)
import Node.Buffer (Buffer)
import Node.EventEmitter (EventHandle(..))
import Node.EventEmitter as Event
import Node.EventEmitter.UtilTypes (EventHandle0, EventHandle1)
import Node.Stream as Stream
import Unsafe.Coerce (unsafeCoerce)

data ReadResult a
  = ReadWouldBlock
  | ReadJust a

derive instance Generic (ReadResult a) _
derive instance Functor ReadResult
derive instance Eq a => Eq (ReadResult a)
instance Show (ReadResult a) where
  show = genericShow <<< map (const "..")

maybeReadResult :: forall a. ReadResult a -> Maybe a
maybeReadResult (ReadWouldBlock) = Nothing
maybeReadResult (ReadJust a) = Just a

data WriteResult
  = WriteWouldBlock
  | WriteOk

derive instance Generic WriteResult _
derive instance Eq WriteResult
instance Show WriteResult where
  show = genericShow

type ReadResultFFI a = { wouldBlock :: ReadResult a, just :: a -> ReadResult a }
type WriteResultFFI = { wouldBlock :: WriteResult, ok :: WriteResult }

foreign import data Writable :: Type -> Type
foreign import data Readable :: Type -> Type
foreign import data Transform :: Type -> Type -> Type

foreign import endImpl :: forall s. s -> Effect Unit
foreign import writeImpl :: forall s a. WriteResultFFI -> s -> a -> Effect WriteResult
foreign import readImpl :: forall s a. ReadResultFFI a -> s -> Effect (ReadResult a)
foreign import isReadableImpl :: forall s. s -> Effect Boolean
foreign import isWritableImpl :: forall s. s -> Effect Boolean
foreign import isReadableEndedImpl :: forall s. s -> Effect Boolean
foreign import isWritableEndedImpl :: forall s. s -> Effect Boolean
foreign import isWritableFinishedImpl :: forall s. s -> Effect Boolean
foreign import isClosedImpl :: forall s. s -> Effect Boolean
foreign import needsDrainImpl :: forall s. s -> Effect Boolean
foreign import readableLengthImpl :: forall s. s -> Effect Int

readResultFFI :: forall a. ReadResultFFI a
readResultFFI = { wouldBlock: ReadWouldBlock, just: ReadJust }

writeResultFFI :: WriteResultFFI
writeResultFFI = { wouldBlock: WriteWouldBlock, ok: WriteOk }

class Stream :: Type -> Constraint
class Stream s where
  isClosed :: s -> Effect Boolean

instance Stream (Readable a) where
  isClosed = isClosedImpl
else instance Stream (Writable a) where
  isClosed = isClosedImpl
else instance Stream (Transform a b) where
  isClosed = isClosedImpl
else instance Stream s => Stream s where
  isClosed s = isClosed s

class Stream s <= Read s a | s -> a where
  readableLength :: s -> Effect Int
  isReadable :: s -> Effect Boolean
  isReadableEnded :: s -> Effect Boolean
  read :: s -> Effect (ReadResult a)

class Stream s <= Write s a | s -> a where
  isWritable :: s -> Effect Boolean
  needsDrain :: s -> Effect Boolean
  isWritableEnded :: s -> Effect Boolean
  isWritableFinished :: s -> Effect Boolean
  write :: s -> a -> Effect WriteResult
  end :: s -> Effect Unit

instance Read (Readable a) a where
  readableLength = readableLengthImpl
  isReadable = isReadableImpl
  isReadableEnded = isReadableEndedImpl
  read = readImpl readResultFFI
else instance Read (Transform a b) b where
  readableLength = readableLengthImpl
  isReadable = isReadableImpl
  isReadableEnded = isReadableEndedImpl
  read = readImpl readResultFFI
else instance (Read s a) => Read s a where
  readableLength = readableLengthImpl
  isReadable = isReadableImpl
  isReadableEnded = isReadableEndedImpl
  read s = read s

instance Write (Writable a) a where
  isWritable = isWritableImpl
  isWritableEnded = isWritableEndedImpl
  isWritableFinished = isWritableFinishedImpl
  write s = writeImpl writeResultFFI s
  end = endImpl
  needsDrain = needsDrainImpl
else instance Write (Transform a b) a where
  isWritable = isWritableImpl
  isWritableEnded = isWritableEndedImpl
  isWritableFinished = isWritableFinishedImpl
  write s = writeImpl writeResultFFI s
  end = endImpl
  needsDrain = needsDrainImpl
else instance (Write s a) => Write s a where
  isWritable = isWritableImpl
  isWritableEnded = isWritableEndedImpl
  isWritableFinished = isWritableFinishedImpl
  write s a = write s a
  end s = end s
  needsDrain = needsDrainImpl

withErrorST :: forall s. Stream s => s -> Effect { cancel :: Effect Unit, error :: STRef Global (Maybe Error) }
withErrorST s = do
  error <- liftST $ STRef.new Nothing
  cancel <- flip (Event.once errorH) s \e -> void $ liftST $ STRef.write (Just e) error
  pure { error, cancel }

unsafeCoerceWritable :: forall r a. Stream.Writable r -> Writable a
unsafeCoerceWritable = unsafeCoerce

unsafeCoerceReadable :: forall r a. Stream.Readable r -> Readable a
unsafeCoerceReadable = unsafeCoerce

unsafeCoerceTransform :: forall a b. Stream.Duplex -> Transform a b
unsafeCoerceTransform = unsafeCoerce

unsafeFromBufferReadable :: forall r. Stream.Readable r -> Readable Buffer
unsafeFromBufferReadable = unsafeCoerce

unsafeFromBufferTransform :: forall a. Stream.Duplex -> Transform Buffer a
unsafeFromBufferTransform = unsafeCoerce

unsafeFromBufferWritable :: forall r. Stream.Writable r -> Writable Buffer
unsafeFromBufferWritable = unsafeCoerce

unsafeFromStringReadable :: forall r. Stream.Readable r -> Readable String
unsafeFromStringReadable = unsafeCoerce

unsafeFromStringTransform :: forall a. Stream.Duplex -> Transform String a
unsafeFromStringTransform = unsafeCoerce

unsafeFromStringWritable :: forall r. Stream.Writable r -> Writable String
unsafeFromStringWritable = unsafeCoerce

awaitReadableOrClosed :: forall s a. Read s a => s -> Aff Unit
awaitReadableOrClosed s = Aff.supervise do
  fiber <-
    Aff.forkAff
    $ parOneOf
      [ onceAff0 readableH s $> Right unit
      , onceAff0 closeH s $> Right unit
      , Left <$> onceAff1 errorH s
      ]
  closed <- liftEffect $ isClosed s
  readEnded <- liftEffect $ isReadableEnded s
  readable <- liftEffect $ isReadable s
  length <- liftEffect $ readableLength s
  if (not closed && not readEnded && readable && length == 0) then
    liftEither =<< Aff.joinFiber fiber
  else
    Aff.killFiber (error "") fiber

awaitFinished :: forall s a. Write s a => s -> Aff Unit
awaitFinished s = Aff.supervise do
  fiber <-
    Aff.forkAff
    $ parOneOf
        [ onceAff0 finishH s $> Right unit
        , Left <$> onceAff1 errorH s
        ]
  finished <- liftEffect $ isWritableFinished s
  if not finished then
    liftEither =<< Aff.joinFiber fiber
  else
    Aff.killFiber (error "") fiber

awaitWritableOrClosed :: forall s a. Write s a => s -> Aff Unit
awaitWritableOrClosed s = Aff.supervise do
  fiber <-
    Aff.forkAff
    $ parOneOf
        [ onceAff0 drainH s $> Right unit
        , onceAff0 closeH s $> Right unit
        , Left <$> onceAff1 errorH s
        ]
  closed <- liftEffect $ isClosed s
  writeEnded <- liftEffect $ isWritableEnded s
  writable <- liftEffect $ isWritable s
  needsDrain <- liftEffect $ needsDrain s
  if not closed && not writeEnded && writable && needsDrain then
    liftEither =<< Aff.joinFiber fiber
  else
    Aff.killFiber (error "") fiber

onceAff0 :: forall e. EventHandle0 e -> e -> Aff Unit
onceAff0 h emitter = makeAff \res -> do
  cancel <- Event.once h (res $ Right unit) emitter
  pure $ effectCanceler cancel

onceAff1 :: forall e a. EventHandle1 e a -> e -> Aff a
onceAff1 h emitter = makeAff \res -> do
  cancel <- Event.once h (res <<< Right) emitter
  pure $ effectCanceler cancel

readableH :: forall s a. Read s a => EventHandle0 s
readableH = EventHandle "readable" identity

drainH :: forall s a. Write s a => EventHandle0 s
drainH = EventHandle "drain" identity

closeH :: forall s. Stream s => EventHandle0 s
closeH = EventHandle "close" identity

errorH :: forall s. Stream s => EventHandle1 s Error
errorH = EventHandle "error" mkEffectFn1

endH :: forall s a. Write s a => EventHandle0 s
endH = EventHandle "end" identity

finishH :: forall s a. Write s a => EventHandle0 s
finishH = EventHandle "finish" identity
