import Stream from "stream";

/** @type {(s: Stream.Readable | Stream.Transform) => () => boolean} */
export const isReadableImpl = (s) => () => s.readable;

/** @type {(s: Stream.Readable | Stream.Transform) => () => number} */
export const readableLengthImpl = (s) => () => s.readableLength;

/** @type {(s: Stream.Writable | Stream.Readable) => () => boolean} */
export const isClosedImpl = (s) => () => s.closed;

/** @type {(s: Stream.Writable | Stream.Transform) => () => boolean} */
export const isWritableImpl = (s) => () => s.writable;

/** @type {(s: Stream.Writable | Stream.Transform) => () => boolean} */
export const needsDrainImpl = (s) => () => s.writableNeedDrain;

/** @type {(s: Stream.Readable | Stream.Transform) => () => boolean} */
export const isReadableEndedImpl = (s) => () => s.readableEnded;

/** @type {(s: Stream.Writable | Stream.Transform) => () => boolean} */
export const isWritableEndedImpl = (s) => () => s.writableEnded;

/** @type {(s: Stream.Writable | Stream.Transform) => () => boolean} */
export const isWritableFinishedImpl = (s) => () => s.writableFinished;

/** @type {(s: Stream.Writable | Stream.Transform) => () => void} */
export const endImpl = (s) => () => s.end();

/** @type {<WriteResult>(o: {ok: WriteResult, wouldBlock: WriteResult}) => (s: Stream.Writable | Stream.Transform) => (a: unknown) => () => WriteResult} */
export const writeImpl =
  ({ ok, wouldBlock }) =>
  (s) =>
  (a) =>
  () => {
    if (s.write(a)) {
      return ok;
    } else {
      return wouldBlock;
    }
  };

/** @type {<ReadResult>(o: {just: (_a: unknown) => ReadResult, wouldBlock: ReadResult}) => (s: Stream.Readable | Stream.Transform) => () => ReadResult} */
export const readImpl =
  ({ just, wouldBlock }) =>
  (s) =>
  () => {
    const a = s.read();
    if (a === null) {
      return wouldBlock;
    } else {
      return just(a);
    }
  };
