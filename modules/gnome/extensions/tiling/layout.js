// SPDX-License-Identifier: GPL-2.0-or-later
// tiling/layout.js: tile geometry, drag zones and keyboard moves. Pure (no GNOME imports), so the
// gjs unit tests can run it.
//
// Tiles: 'left' and 'right' halves, 'tl' 'tr' 'bl' 'br' quarters, 'max' (the whole work area).

// [x, y, width, height] as fractions of the work area.
export const TILES = {
    left: [0, 0, 0.5, 1],
    right: [0.5, 0, 0.5, 1],
    tl: [0, 0, 0.5, 0.5],
    tr: [0.5, 0, 0.5, 0.5],
    bl: [0, 0.5, 0.5, 0.5],
    br: [0.5, 0.5, 0.5, 0.5],
    max: [0, 0, 1, 1],
};

// The rectangle for a tile. Gaps: the full gap at the screen edges, half on each side between tiles,
// so neighbouring tiles end up one gap apart.
export function rectFor(tile, wa, gap = 0) {
    const [fx, fy, fw, fh] = TILES[tile];
    const half = Math.floor(gap / 2);
    const x = wa.x + Math.round(wa.width * fx) + (fx === 0 ? gap : half);
    const y = wa.y + Math.round(wa.height * fy) + (fy === 0 ? gap : half);
    const x2 = wa.x + Math.round(wa.width * (fx + fw)) - (fx + fw === 1 ? gap : half);
    const y2 = wa.y + Math.round(wa.height * (fy + fh)) - (fy + fh === 1 ? gap : half);
    return {x, y, width: x2 - x, height: y2 - y};
}

// Where a window dropped at the pointer would tile, or null. Edges of the monitor (the pointer
// can't go further); the ends of each edge are the quarter corners. `wa` is the work area.
export function zoneAt(px, py, mon, wa, edge = 4) {
    const cw = Math.min(mon.width / 4, 320);
    const ch = Math.min(mon.height / 4, 320);
    const nearTop = py < wa.y + ch;
    const nearBottom = py > wa.y + wa.height - ch;
    const nearLeft = px < mon.x + cw;
    const nearRight = px > mon.x + mon.width - cw;
    if (px <= mon.x + edge)
        return nearTop ? 'tl' : nearBottom ? 'bl' : 'left';
    if (px >= mon.x + mon.width - 1 - edge)
        return nearTop ? 'tr' : nearBottom ? 'br' : 'right';
    if (py <= mon.y + edge)
        return nearLeft ? 'tl' : nearRight ? 'tr' : 'max';
    if (py >= mon.y + mon.height - 1 - edge)
        return nearLeft ? 'bl' : nearRight ? 'br' : null;
    return null;
}

// Keyboard moves: Super+arrow from the current tile ('none' when untiled). 'restore' puts the
// window back to its size from before tiling (or unmaximizes it).
const MOVES = {
    left: {none: 'left', left: 'left', right: 'restore', tl: 'tl', tr: 'tl', bl: 'bl', br: 'bl', max: 'left'},
    right: {none: 'right', right: 'right', left: 'restore', tr: 'tr', tl: 'tr', br: 'br', bl: 'br', max: 'right'},
    up: {none: 'max', left: 'tl', right: 'tr', bl: 'left', br: 'right', tl: 'tl', tr: 'tr', max: 'max'},
    down: {none: 'restore', max: 'restore', left: 'bl', right: 'br', tl: 'left', tr: 'right', bl: 'bl', br: 'br'},
};

export function nextTile(current, direction) {
    return MOVES[direction]?.[current ?? 'none'] ?? null;
}

function overlap(a, b) {
    const w = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
    const h = Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y);
    return w > 0 && h > 0 ? w * h : 0;
}

// The tile to offer for filling the rest of the screen, given the rectangles already tiled there:
// a free half first, else a free quarter, else null. "Free" allows a sliver of overlap (gaps,
// rounding, a window nudged by hand).
export function freeTile(occupied, wa) {
    for (const tile of ['left', 'right', 'tl', 'tr', 'bl', 'br']) {
        const cell = rectFor(tile, wa);
        const area = cell.width * cell.height;
        if (occupied.every(r => overlap(r, cell) < area * 0.05))
            return tile;
    }
    return null;
}

// Neighbours that share an edge with `before` follow it to `after` (resizing tiled windows
// together). Returns the new rectangles for the neighbours that changed, by index.
export function followEdges(before, after, neighbours, tolerance = 12) {
    const near = (a, b) => Math.abs(a - b) <= tolerance;
    const out = new Map();
    const bR = before.x + before.width, aR = after.x + after.width;
    const bB = before.y + before.height, aB = after.y + after.height;
    neighbours.forEach((n, i) => {
        let {x, y, width, height} = n;
        const r = x + width, b = y + height;
        const vOverlap = Math.min(b, bB) > Math.max(y, before.y);
        const hOverlap = Math.min(r, bR) > Math.max(x, before.x);
        if (vOverlap && aR !== bR && near(x, bR)) { // neighbour on the right
            width = r - aR + (x - bR);
            x = aR + (x - bR);
        }
        if (vOverlap && after.x !== before.x && near(r, before.x)) // on the left
            width = after.x - (before.x - r) - x;
        if (hOverlap && aB !== bB && near(y, bB)) { // below
            height = b - aB + (y - bB);
            y = aB + (y - bB);
        }
        if (hOverlap && after.y !== before.y && near(b, before.y)) // above
            height = after.y - (before.y - b) - y;
        if (x !== n.x || y !== n.y || width !== n.width || height !== n.height)
            out.set(i, {x, y, width, height});
    });
    return out;
}
