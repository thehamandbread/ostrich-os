// SPDX-License-Identifier: GPL-2.0-or-later
// drawer/barlogic.js: the parts of Ostrich Drawer's top bar with no GNOME calls, so the gjs unit
// tests can run them: badges, which sites get an icon, where and how big the drawer opens, and when
// a drawer opened by hovering closes again.

export const HOVER_CLOSE_MS = 500;
const MIN_SIZE = 240;

/** "3", "9+", or '' (no badge). */
export function badgeText(n) {
    if (!Number.isFinite(n) || n <= 0)
        return '';
    return n > 9 ? '9+' : String(Math.floor(n));
}

/** The pinned apps with `id` added once (a new list), or without it. */
export function pinnedWith(list, id) {
    return list.includes(id) ? [...list] : [...list, id];
}

export function pinnedWithout(list, id) {
    return list.filter(x => x !== id);
}

/** "260 MB" or "1.1 GB": a site's memory rounded to what the measurement can claim. */
export function memoryText(mb) {
    return mb >= 1000 ? `${(mb / 1024).toFixed(1)} GB` : `${Math.max(10, Math.round(mb / 10) * 10)} MB`;
}

/**
 * Splits the bar's sites into the icons shown and the ones in the ⌄ menu.
 *
 * @param {string[]} bar  site ids with a top-bar icon, in order
 * @param {number} max    how many icons fit (0: none, all in the menu)
 */
export function splitBar(bar, max) {
    const n = Math.max(0, Math.floor(max));
    return {shown: bar.slice(0, n), overflow: bar.slice(n)};
}

/**
 * The site a next/previous shortcut goes to: the one after (or before) the open one in the bar's
 * order, wrapping round; the first (or last) when none is open. Null when the bar is empty.
 *
 * @param {string[]} bar  site ids in the bar, in order
 * @param {string|null} active  the open (or last open) site
 * @param {number} dir  1 for next, -1 for previous
 */
export function stepSite(bar, active, dir) {
    if (bar.length === 0)
        return null;
    const at = bar.indexOf(active);
    if (at < 0)
        return dir > 0 ? bar[0] : bar[bar.length - 1];
    return bar[(at + dir + bar.length) % bar.length];
}

/**
 * The drawer's size before placing: one size for every site (owner, 2026-11-19), so switching
 * sites never resizes it. The size the user dragged it to (px), else percents of the area.
 *
 * @param {{width: number, height: number}} area  the monitor below the top bar
 * @param {{width: number, height: number}} percent  the settings' default size
 * @param {[number, number]} dragged  the size the user chose, [0, 0] when they never did
 */
export function drawerSize(area, percent, dragged) {
    let [width, height] = dragged;
    if (!(width > 0 && height > 0)) {
        width = Math.round(area.width * percent.width / 100);
        height = Math.round(area.height * percent.height / 100);
    }
    return {
        width: Math.min(area.width, Math.max(MIN_SIZE, width)),
        height: Math.min(area.height, Math.max(MIN_SIZE, height)),
    };
}

/**
 * Where the drawer's left edge goes: centred under the icon, kept `gap` px inside the monitor.
 *
 * @param {number} iconCenter  x of the icon's centre
 * @param {number} width       the drawer's width
 * @param {{x: number, width: number}} monitor
 * @param {number} gap
 */
export function placeUnder(iconCenter, width, monitor, gap) {
    const min = monitor.x + (width < monitor.width ? gap : 0);
    const max = monitor.x + monitor.width - width - (width < monitor.width ? gap : 0);
    return Math.round(Math.min(max, Math.max(min, iconCenter - width / 2)));
}

/**
 * How long the pointer must rest on an icon before its site opens (ms), or null for nothing to do.
 * Closed: the hover delay. Open on another site: the (shorter) switch delay. Open on this one: null.
 */
export function hoverDelay({shown, active, id, delay, switchDelay}) {
    if (!shown)
        return delay;
    return active === id ? null : switchDelay;
}

/** Is a point inside a rectangle {x, y, width, height}? */
export function inside(rect, x, y) {
    return !!rect && x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height;
}

/**
 * Hover-to-close for a drawer opened by hovering: called on each check with the pointer's
 * whereabouts. Returns the new "outside since" time (null while inside) and whether to close.
 * A drawer the user clicked or typed in (engaged) never closes this way.
 *
 * @param {{outsideSince: number|null, engaged: boolean, now: number, pointerInside: boolean}} s
 */
export function hoverStep({outsideSince, engaged, now, pointerInside}) {
    if (engaged || pointerInside)
        return {outsideSince: null, close: false};
    const since = outsideSince ?? now;
    return {outsideSince: since, close: now - since >= HOVER_CLOSE_MS};
}
