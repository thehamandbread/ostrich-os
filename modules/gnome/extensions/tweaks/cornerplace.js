// SPDX-License-Identifier: GPL-2.0-or-later
// tweaks/cornerplace.js: where the quick-settings hot corner goes. Pure, so tests/js can feed it fake monitors.

// The top-right corner of the right-most monitor whose top edge lines up with the primary's, or null
// when something sits right of that point (the pointer would cross over instead of pushing into it).
// shortcut: monitors that only touch the primary's top edge by an offset get no corner, upgrade if a layout asks for one.
export function cornerFor(monitors, primary) {
    if (!primary)
        return null;
    const row = monitors.filter(m => m.y === primary.y);
    const last = row.reduce((a, b) => (b.x + b.width > a.x + a.width ? b : a), primary);
    const x = last.x + last.width;
    const y = primary.y;
    const beside = monitors.some(o => o !== last && x >= o.x && x < o.x + o.width && y >= o.y && y < o.y + o.height);
    return beside ? null : {x, y};
}
