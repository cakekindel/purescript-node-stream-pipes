import Stream from 'stream'
import * as CBOR from "cbor-x";
import * as CSVDecode from "csv-parse";
import * as CSVEncode from "csv-stringify";

export const cborDecode = () => new CBOR.DecoderStream({useRecords: false, allowHalfOpen: true});
export const cborEncode = () => new CBOR.EncoderStream({useRecords: false, allowHalfOpen: true});

export const cborDecodeSync = a => () => CBOR.decodeMultiple(a);
export const cborEncodeSync = a => () => CBOR.encode(a, {useRecords: false});

export const csvDecode = () => CSVDecode.parse({columns: true, allowHalfOpen: true})
export const csvEncode = () => CSVEncode.stringify({header: true, allowHalfOpen: true})

export const discardTransform = () => new Stream.Transform({
  transform: function(_ck, _enc, cb) {
    cb()
  },
  objectMode: true
})

export const slowTransform = () => {
  return new Stream.Transform({
  transform: function(ck, _enc, cb) {
    this.push(ck)
    setTimeout(() => cb(), 4)
  },
  objectMode: true
})
}

export const charsTransform = () => new Stream.Transform({
  transform: function(ck, _enc, cb) {
    ck.split('').filter(s => !!s).forEach(s => this.push(s))
    cb()
  },
  objectMode: true,
})

/** @type {(a: Array<unknown>) => Stream.Readable}*/
export const readableFromArray = a => Stream.Readable.from(a)
