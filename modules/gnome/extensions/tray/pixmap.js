// SPDX-License-Identifier: GPL-2.0-or-later
// tray/pixmap.js: StatusNotifierItem IconPixmap helpers. Pure functions, unit-tested with plain gjs.
//
// IconPixmap is an array of (width, height, bytes) with ARGB32 pixels in network byte order
// (A, R, G, B per pixel). GdkPixbuf wants RGBA.

// Picks the pixmap closest to `size` (smallest one at least that big, else the largest).
export function pickPixmap(pixmaps, size) {
    const valid = pixmaps.filter(([w, h, data]) => w > 0 && h > 0 && data.length >= w * h * 4);
    if (valid.length === 0)
        return null;
    const big = valid.filter(([w]) => w >= size).sort((a, b) => a[0] - b[0]);
    return big[0] ?? valid.sort((a, b) => b[0] - a[0])[0];
}

// ARGB (network order) → RGBA, as a new Uint8Array.
export function argbToRgba(data) {
    const out = new Uint8Array(data.length - (data.length % 4));
    for (let i = 0; i < out.length; i += 4) {
        out[i] = data[i + 1];
        out[i + 1] = data[i + 2];
        out[i + 2] = data[i + 3];
        out[i + 3] = data[i];
    }
    return out;
}

// Splits a StatusNotifierItem "service" string into {busName, objectPath}. Items register either a
// bus name (default path /StatusNotifierItem) or an object path (then the sender is the bus name).
export function parseService(service, sender) {
    if (service.startsWith('/'))
        return {busName: sender, objectPath: service};
    const slash = service.indexOf('/');
    if (slash > 0)
        return {busName: service.slice(0, slash), objectPath: service.slice(slash)};
    return {busName: service, objectPath: '/StatusNotifierItem'};
}

// dbusmenu labels use '_' for mnemonics ("__" is a literal underscore).
export function stripMnemonic(label) {
    return (label ?? '').split('__').map(part => part.replace(/_/g, '')).join('_');
}
