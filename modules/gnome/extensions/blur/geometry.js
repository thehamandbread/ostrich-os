// SPDX-License-Identifier: GPL-2.0-or-later
// blur/geometry.js: the area blurred behind a surface (no GNOME calls, so the gjs tests run it).

/**
 * The surface grown by `margin` on every side, kept on the stage: the blur mixes real content
 * at the surface's edges instead of a clipped strip.
 *
 * @param {{x: number, y: number, width: number, height: number}} r  the surface
 * @param {number} margin  usually the blur radius
 * @param {{width: number, height: number}} stage
 * @param {{below?: number}} [opts]  a smaller margin below (the top bar: the windows under it)
 */
export function paddedRect(r, margin, stage, {below = margin} = {}) {
    const x0 = Math.max(0, r.x - margin);
    const y0 = Math.max(0, r.y - margin);
    const x1 = Math.min(stage.width, r.x + r.width + margin);
    const y1 = Math.min(stage.height, r.y + r.height + below);
    return {x: x0, y: y0, width: Math.max(0, x1 - x0), height: Math.max(0, y1 - y0)};
}

/**
 * Whether two rectangles overlap (touching edges don't): a window counts for a backdrop only if
 * it's under the area being blurred.
 *
 * @param {{x: number, y: number, width: number, height: number}} a
 * @param {{x: number, y: number, width: number, height: number}} b
 */
export function overlaps(a, b) {
    return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
}
