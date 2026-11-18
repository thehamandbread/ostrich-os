// SPDX-License-Identifier: GPL-2.0-or-later
// powerrow.js: on a machine with three power modes, one full-width "Power Saver | Balanced |
// Performance" row in quick settings in place of GNOME's Power Mode tile (whose body only toggles
// Balanced and the last-used mode, and which takes open, arrow, item to pick one: council 2026-11-09).
// With two modes GNOME's tile is already one click, so nothing here is shown. The tile comes back
// whenever the row goes (fewer than three modes, the daemon leaves, the extension is disabled).

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';

import {hideStockTile} from './_lib/patches.js';
import {profilesProxy} from './_lib/timers.js';

const MODES = [
    ['power-saver', 'Power Saver', 'power-profile-power-saver-symbolic'],
    ['balanced', 'Balanced', 'power-profile-balanced-symbolic'],
    ['performance', 'Performance', 'power-profile-performance-symbolic'],
];

// The profile names the daemon offers, from its Profiles property (a{sv} per profile).
export function offered(variant) {
    return (variant?.deepUnpack() ?? []).map(p => p.Profile?.unpack()).filter(Boolean);
}

const Row = GObject.registerClass({
    Signals: {picked: {param_types: [GObject.TYPE_STRING]}},
}, class OstrichPowerRow extends St.BoxLayout {
    _init() {
        super._init({style_class: 'ost-power-row', x_expand: true, visible: false});
        this._buttons = new Map();
        for (const [id, label, icon] of MODES) {
            const button = new St.Button({
                style_class: 'ost-power-segment', can_focus: true, reactive: true, x_expand: true,
                accessible_name: `Power mode: ${label}`,
                child: new St.BoxLayout({style_class: 'ost-power-segment-box', x_align: Clutter.ActorAlign.CENTER}),
            });
            button.child.add_child(new St.Icon({icon_name: icon, style_class: 'ost-power-segment-icon'}));
            button.child.add_child(new St.Label({text: label, y_align: Clutter.ActorAlign.CENTER}));
            button.connect('clicked', () => this.emit('picked', id));
            this._buttons.set(id, button);
            this.add_child(button);
        }
    }

    update(offeredIds, active) {
        for (const [id, button] of this._buttons) {
            button.visible = offeredIds.includes(id);
            button.checked = id === active;
        }
    }
});

export class PowerRow {
    constructor() {
        this._cancellable = new Gio.Cancellable();
        this._restore = null;
        this._row = new Row();
        this._indicator = new QuickSettings.SystemIndicator();
        this._indicator.quickSettingsItems.push(this._row);
        this._row.connect('picked', (_r, id) => this._set(id));
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator, 2);
        this._start();
    }

    async _start() {
        const p = await profilesProxy(this._cancellable);
        if (!p || this._cancellable.is_cancelled())
            return;
        this._proxy = p;
        this._id = p.connect('g-properties-changed', () => this._sync());
        this._sync();
    }

    _sync() {
        const ids = offered(this._proxy.get_cached_property('Profiles'));
        const three = MODES.every(([id]) => ids.includes(id));
        if (three && !this._restore) {
            const qs = Main.panel.statusArea.quickSettings;
            this._restore = hideStockTile(qs, '_powerProfiles', 'tweaks');
            // Where the tile was, not at the end of the grid.
            const stock = qs._powerProfiles?.quickSettingsItems?.[0];
            if (stock?.get_parent() === this._row.get_parent())
                this._row.get_parent().set_child_above_sibling(this._row, stock);
        } else if (!three && this._restore) {
            this._restore();
            this._restore = null;
        }
        this._row.visible = three && !!this._restore;
        this._row.update(ids, this._proxy.get_cached_property('ActiveProfile')?.unpack());
    }

    _set(id) {
        this._proxy?.call('org.freedesktop.DBus.Properties.Set',
            new GLib.Variant('(ssv)', [this._proxy.get_interface_name(), 'ActiveProfile', new GLib.Variant('s', id)]),
            Gio.DBusCallFlags.NONE, -1, this._cancellable, (p, res) => {
                try {
                    p.call_finish(res);
                } catch (e) {
                    if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                        Main.notifyError('Power mode', `Could not switch power mode: ${e.message}`);
                }
            });
    }

    destroy() {
        this._cancellable.cancel();
        if (this._proxy && this._id)
            this._proxy.disconnect(this._id);
        this._restore?.();
        this._restore = null;
        this._indicator.quickSettingsItems.forEach(i => i.destroy());
        this._indicator.destroy();
    }
}
