// SPDX-License-Identifier: GPL-2.0-or-later
// _lib/place.js: where a pop-out alert (alert.js) goes. No GNOME calls, so the gjs tests run it.

export const GAP = 8; // between the top bar and the card, and the card and the screen's edge

/**
 * Where the card goes: centred under the source, kept inside its monitor.
 *
 * @param {{x: number, y: number, width: number, height: number}} source  the top-bar item
 * @param {{x: number, width: number}} monitor
 * @param {number} barBottom
 * @param {number} width  the card's
 * @returns {{x: number, y: number}}
 */
export function placeUnder(source, monitor, barBottom, width) {
    const centred = source.x + source.width / 2 - width / 2;
    const x = Math.max(monitor.x + GAP, Math.min(centred, monitor.x + monitor.width - width - GAP));
    return {x: Math.round(x), y: Math.round(barBottom + GAP)};
}

