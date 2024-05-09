module Node.Stream.Object where

import Prelude

import Data.Either (Either(..))
import Effect (Effect)
import Effect.Aff (Aff, effectCanceler, makeAff)
import Effect.Class (liftEffect)
import Effect.Exception (Error)
import Effect.Uncurried (mkEffectFn1)
import Node.Buffer (Buffer)
import Node.EventEmitter (EventHandle(..))
import Node.EventEmitter as Event
import Node.EventEmitter.UtilTypes (EventHandle0, EventHandle1)
import Node.Stream as Stream
import Unsafe.Coerce (unsafeCoerce)

data ReadResult a
  = ReadWouldBlock
  | ReadClosed
  | ReadJust a

data WriteResult
  = WriteWouldBlock
  | WriteClosed
  | WriteOk

type ReadResultFFI a = { closed :: ReadResult a, wouldBlock :: ReadResult a, just :: a -> ReadResult a }
type WriteResultFFI = { closed :: WriteResult, wouldBlock :: WriteResult, ok :: WriteResult }

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
foreign import isClosedImpl :: forall s. s -> Effect Boolean

readResultFFI :: forall a. ReadResultFFI a
readResultFFI = {closed: ReadClosed, wouldBlock: ReadWouldBlock, just: ReadJust}

writeResultFFI :: WriteResultFFI
writeResultFFI = {closed: WriteClosed, wouldBlock: WriteWouldBlock, ok: WriteOk}

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
  isReadable :: s -> Effect Boolean
  isReadableEnded :: s -> Effect Boolean
  read :: s -> Effect (ReadResult a)

class Stream s <= Write s a | s -> a where
  isWritable :: s -> Effect Boolean
  isWritableEnded :: s -> Effect Boolean
  write :: s -> a -> Effect WriteResult
  end :: s -> Effect Unit

instance Read (Readable a) a where
  isReadable = isReadableImpl
  isReadableEnded = isReadableEndedImpl
  read = readImpl readResultFFI
else instance Read (Transform a b) b where
  isReadable = isReadableImpl
  isReadableEnded = isReadableEndedImpl
  read = readImpl readResultFFI
else instance (Read s a) => Read s a where
  isReadable = isReadableImpl
  isReadableEnded = isReadableEndedImpl
  read s = read s

instance Write (Writable a) a where
  isWritable = isWritableImpl
  isWritableEnded = isWritableEndedImpl
  write s = writeImpl writeResultFFI s
  end = endImpl
else instance Write (Transform a b) a where
  isWritable = isWritableImpl
  isWritableEnded = isWritableEndedImpl
  write s = writeImpl writeResultFFI s
  end = endImpl
else instance (Write s a) => Write s a where
  isWritable = isWritableImpl
  isWritableEnded = isWritableEndedImpl
  write s a = write s a
  end s = end s

fromBufferReadable :: forall r. Stream.Readable r -> Readable Buffer
fromBufferReadable = unsafeCoerce

fromBufferTransform :: Stream.Duplex -> Transform Buffer Buffer
fromBufferTransform = unsafeCoerce

fromBufferWritable :: forall r. Stream.Writable r -> Writable Buffer
fromBufferWritable = unsafeCoerce

fromStringReadable :: forall r. Stream.Readable r -> Readable String
fromStringReadable = unsafeCoerce

fromStringTransform :: Stream.Duplex -> Transform String String
fromStringTransform = unsafeCoerce

fromStringWritable :: forall r. Stream.Writable r -> Writable String
fromStringWritable = unsafeCoerce

awaitReadableOrClosed :: forall s a. Read s a => s -> Aff Unit
awaitReadableOrClosed s = do
  closed <- liftEffect $ isClosed s
  ended <- liftEffect $ isReadableEnded s
  readable <- liftEffect $ isReadable s
  when (not ended && not closed && not readable) $ makeAff \res -> do
    cancelClose <- Event.once closeH (res $ Right unit) s
    cancelError <- Event.once errorH (res <<< Left) s
    cancelReadable <- flip (Event.once readableH) s do
      cancelClose
      cancelError
      res $ Right unit
    pure $ effectCanceler do
      cancelReadable
      cancelClose
      cancelError

awaitWritableOrClosed :: forall s a. Write s a => s -> Aff Unit
awaitWritableOrClosed s = do
  closed <- liftEffect $ isClosed s
  ended <- liftEffect $ isWritableEnded s
  writable <- liftEffect $ isWritable s
  when (not closed && not ended && not writable) $ makeAff \res -> do
    cancelClose <- Event.once closeH (res $ Right unit) s
    cancelError <- Event.once errorH (res <<< Left) s
    cancelDrain <- flip (Event.once drainH) s do
      cancelClose
      cancelError
      res $ Right unit
    pure $ effectCanceler do
      cancelDrain
      cancelClose
      cancelError

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
