// SPDX-License-Identifier: GPL-2.0-or-later
// drawer/barlogic.js: the parts of Ostrich Drawer's top bar with no GNOME calls, so the gjs unit
// tests can run them: badges, which sites get an icon, where and how big a site opens, and when
// a drawer opened by hovering closes again.

export const NARROW_WIDTH = 420; // px: chat sites open like a phone
export const NARROW_HEIGHT_PCT = 75;
export const HOVER_CLOSE_MS = 500;
const MIN_SIZE = 240;

/** "3", "9+", or '' (no badge). */
export function badgeText(n) {
    if (!Number.isFinite(n) || n <= 0)
        return '';
    return n > 9 ? '9+' : String(Math.floor(n));
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
 * A site's size before placing: the size the user resized it to, else from its shape.
 *
 * @param {{shape: string, width: number, height: number}} site
 * @param {{width: number, height: number}} area  the monitor below the top bar
 * @param {{width: number, height: number}} wide  percent of the area for wide sites (settings)
 */
export function siteSize(site, area, wide) {
    let width, height;
    if (site.width > 0 && site.height > 0) {
        ({width, height} = site);
    } else if (site.shape === 'narrow') {
        width = NARROW_WIDTH;
        height = Math.round(area.height * NARROW_HEIGHT_PCT / 100);
    } else {
        width = Math.round(area.width * wide.width / 100);
        height = Math.round(area.height * wide.height / 100);
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
