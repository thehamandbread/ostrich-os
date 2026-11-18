// SPDX-License-Identifier: GPL-2.0-or-later
// _lib/patches.js: replace methods on GNOME Shell objects and restore them all on disable, and reach
// GNOME's private fields safely.
// Vendored into each extension at build time (see build.sh); never shared at runtime.

const warned = new Set();

// A private field of a GNOME Shell object (Main.panel._leftBox, dateMenu._calendar…), or null when
// GNOME has renamed or removed it; logged once per field, so that one feature goes quiet instead
// of the extension failing to enable. owner names the extension in the log.
export function shellField(obj, name, owner = 'ubuntu-ostrich') {
    const value = obj?.[name];
    if (value !== undefined && value !== null)
        return value;
    if (!warned.has(name)) {
        warned.add(name);
        console.warn(`${owner}: GNOME no longer has ${name}; that part is switched off`);
    }
    return null;
}

// Hides one of GNOME's own quick-settings tiles (the indicator in field, e.g. '_powerProfiles') while
// ours stands in for it, and returns the function that shows it again (call it from disable()), or
// null when nothing was hidden. A renamed field (undefined) is logged once and the stock tile stays;
// a field GNOME leaves null on purpose (no Bluetooth on this machine) is skipped quietly.
// GNOME sets these tiles' visibility itself on every sync (powerProfiles.js: visible while the daemon
// runs), so each item is held hidden, and restore puts back the value GNOME last asked for.
// shortcut: GNOME hiding an item we already hide sends no notify, so restore can show a tile GNOME
// had just hidden, until its next sync; read GNOME's own condition if that ever shows up.
export function hideStockTile(quickSettings, field, owner = 'ubuntu-ostrich') {
    const indicator = quickSettings?.[field];
    if (indicator === undefined) {
        shellField(quickSettings, field, owner);
        return null;
    }
    const items = indicator?.quickSettingsItems ?? [];
    if (items.length === 0)
        return null;
    const held = items.map(item => {
        const h = {item, wanted: item.visible, ours: false};
        const hide = () => {
            h.ours = true;
            item.visible = false;
            h.ours = false;
        };
        h.id = item.connect('notify::visible', () => {
            if (h.ours)
                return;
            h.wanted = item.visible;
            if (h.wanted)
                hide();
        });
        hide();
        return h;
    });
    return () => {
        for (const h of held) {
            h.item.disconnect(h.id);
            h.item.visible = h.wanted;
        }
    };
}

export class Patches {
    constructor() {
        this._restore = [];
    }

    // Replaces obj[name] with make(original). The original is restored by restoreAll(). When GNOME
    // has renamed or removed the target, nothing is patched: that one feature goes quiet (logged
    // once) and the extension keeps working, rather than the whole extension failing to enable.
    // Returns the original, or null when it wasn't there.
    replace(obj, name, make) {
        const original = obj?.[name];
        if (typeof original !== 'function') {
            console.warn(`${this._owner()}: GNOME no longer has ${name}; that part is switched off`);
            return null;
        }
        obj[name] = make(original);
        this._restore.push(() => {
            obj[name] = original;
        });
        return original;
    }

    // The extension's name for the log, from the caller's file path (…/extensions/<uuid>/…).
    _owner() {
        const m = /extensions\/([^/]+)\//.exec(new Error().stack ?? '');
        return m ? m[1] : 'ubuntu-ostrich';
    }

    // Restores in reverse order, so stacked patches on one method unwind correctly.
    restoreAll() {
        while (this._restore.length > 0)
            this._restore.pop()();
    }
}
