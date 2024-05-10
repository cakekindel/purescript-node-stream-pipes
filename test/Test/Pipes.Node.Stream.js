import Stream from 'stream'

export const discardTransform = () => new Stream.Transform({
  transform: function(_ck, _enc, cb) {
    cb()
  },
  objectMode: true
})

export const charsTransform = () => new Stream.Transform({
  transform: function(ck, _enc, cb) {
    ck.split('').filter(s => !!s).forEach(s => this.push(s))
    cb()
  },
  objectMode: true,
})

/** @type {(a: Array<unknown>) => Stream.Readable}*/
export const readableFromArray = a => Stream.Readable.from(a)
