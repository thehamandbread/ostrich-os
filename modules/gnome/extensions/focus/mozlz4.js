// SPDX-License-Identifier: GPL-2.0-or-later
// focus/mozlz4.js: Mozilla's session files (sessionstore-backups/recovery.jsonlz4) are "mozLz40\0",
// the length as a little-endian u32, then one LZ4 block. No GNOME calls, so the gjs tests run it.

const MAGIC = [0x6d, 0x6f, 0x7a, 0x4c, 0x7a, 0x34, 0x30, 0x00]; // "mozLz40\0"
const MAX_OUTPUT = 64 * 1024 * 1024; // a session file is a few MB; refuse anything absurd

/**
 * Decodes one LZ4 block.
 *
 * @param {Uint8Array} src
 * @param {number} size  the decoded length
 * @returns {Uint8Array}
 */
export function lz4Block(src, size) {
    if (!(size >= 0 && size <= MAX_OUTPUT))
        throw new Error(`bad LZ4 size ${size}`);
    const out = new Uint8Array(size);
    let i = 0, o = 0;
    const length = first => {
        let n = first;
        if (first === 15) {
            let b;
            do {
                if (i >= src.length)
                    throw new Error('LZ4 data ends inside a length');
                b = src[i++];
                n += b;
            } while (b === 255);
        }
        return n;
    };
    while (i < src.length) {
        const token = src[i++];
        const literals = length(token >> 4);
        if (i + literals > src.length || o + literals > size)
            throw new Error('LZ4 literals run past the data');
        out.set(src.subarray(i, i + literals), o);
        i += literals;
        o += literals;
        if (i >= src.length)
            break; // the last sequence has literals only
        if (i + 2 > src.length)
            throw new Error('LZ4 data ends inside an offset');
        const offset = src[i] | (src[i + 1] << 8);
        i += 2;
        const match = length(token & 15) + 4;
        if (offset === 0 || offset > o || o + match > size)
            throw new Error('bad LZ4 match');
        for (let k = 0; k < match; k++, o++)
            out[o] = out[o - offset]; // may overlap: byte by byte
    }
    if (o !== size)
        throw new Error('LZ4 data is shorter than its size');
    return out;
}

/** The text inside a mozlz4 file's bytes; throws if it isn't one. */
export function mozlz4Text(bytes) {
    if (bytes.length < 12 || MAGIC.some((b, k) => bytes[k] !== b))
        throw new Error('not a mozlz4 file');
    const size = (bytes[8] | (bytes[9] << 8) | (bytes[10] << 16) | (bytes[11] << 24)) >>> 0;
    return new TextDecoder().decode(lz4Block(bytes.subarray(12), size));
}

/** A valid mozlz4 file holding `text`, using no matches (for the tests: it is LZ4 without the saving). */
export function mozlz4Literal(text) {
    const data = new TextEncoder().encode(text);
    const head = [];
    if (data.length < 15) {
        head.push(data.length << 4);
    } else {
        head.push(0xf0);
        let rest = data.length - 15;
        while (rest >= 255) {
            head.push(255);
            rest -= 255;
        }
        head.push(rest);
    }
    const out = new Uint8Array(12 + head.length + data.length);
    out.set(MAGIC, 0);
    new DataView(out.buffer).setUint32(8, data.length, true);
    out.set(head, 12);
    out.set(data, 12 + head.length);
    return out;
}
