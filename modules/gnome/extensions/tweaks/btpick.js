// SPDX-License-Identifier: GPL-2.0-or-later
// btpick.js: which Bluetooth devices btdevices.js shows. No GNOME imports, so tests/js can run it.

export const SHOWN = 3;

// Which paired devices to show: connected ones first, then the ones you connected most recently
// (recent: addresses, newest first), then the rest by name. Pure, so tests/js can run it.
export function pickRecent(devices, recent, limit = SHOWN) {
    const rank = d => {
        const i = recent.indexOf(d.address);
        return i < 0 ? recent.length : i;
    };
    return devices
        .filter(d => d.paired)
        .sort((a, b) => (b.connected - a.connected) || (rank(a) - rank(b)) || a.alias.localeCompare(b.alias))
        .slice(0, limit);
}
