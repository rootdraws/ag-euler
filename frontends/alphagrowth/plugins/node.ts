import { Buffer } from 'buffer'
import { defineNuxtPlugin } from '#app'

globalThis.Buffer = Buffer
if (!(Buffer.alloc(1).subarray(0, 1) instanceof Buffer)) {
  Buffer.prototype.subarray = function subarray(...args: [begin: number | undefined, end: number | undefined]) {
    const result = Uint8Array.prototype.subarray.apply(this, args)
    Object.setPrototypeOf(result, Buffer.prototype)
    return result
  }
}

export default defineNuxtPlugin(() => {})
