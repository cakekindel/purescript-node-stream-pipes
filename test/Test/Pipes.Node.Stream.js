import Stream from 'stream'

/** @type {(a: Array<unknown>) => Stream.Readable}*/
export const readableFromArray = a => Stream.Readable.from(a)
