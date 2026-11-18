// SPDX-License-Identifier: GPL-2.0-or-later
// btdevices.js: up to three of your paired Bluetooth devices as tiles in quick settings, right below
// GNOME's Bluetooth tile, so connecting earbuds is two clicks (open quick settings, press the tile).
// GNOME's own tile stays: it has the full list and is the way to pair (council 2026-11-09, owner's choice).
// Lazy: a GnomeBluetooth.Client exists only while the quick-settings menu is open, and is freed the
// moment it closes. Nothing watches BlueZ otherwise. Nothing shows without an adapter that is on, or
// without a paired device. No scanning, no pairing.

import Gio from 'gi://Gio';
import GnomeBluetooth from 'gi://GnomeBluetooth?version=3.0';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';

import {Signals} from './_lib/signals.js';
import {pickRecent, SHOWN} from './btpick.js';

const KEPT = 8; // addresses remembered, most recent first
const FAILED = "Couldn't connect"; // the tile is narrow; the full hint is its accessible description
const FAILED_HINT = "Couldn't connect. Is it on and in range?";

export class BluetoothDevices {
    constructor(settings) {
        this._settings = settings;
        this._qs = Main.panel.statusArea.quickSettings;
        this._tiles = [];
        this._indicator = new QuickSettings.SystemIndicator();
        for (let i = 0; i < SHOWN; i++) {
            const tile = new QuickSettings.QuickToggle({title: '', iconName: 'bluetooth-active-symbolic', visible: false});
            tile.connect('clicked', () => this._press(tile));
            this._tiles.push(tile);
            this._indicator.quickSettingsItems.push(tile);
        }
        this._qs.addExternalIndicator(this._indicator);
        // Directly below GNOME's Bluetooth tile, not at the end of the grid.
        const stock = this._qs._bluetooth?.quickSettingsItems?.[0];
        let after = stock;
        for (const tile of this._tiles) {
            if (after && after.get_parent() === tile.get_parent())
                tile.get_parent().set_child_above_sibling(tile, after);
            after = tile;
        }
        this._menuSignals = new Signals();
        this._menuSignals.connect(this._qs.menu, 'open-state-changed', (_m, open) => (open ? this._open() : this._close()));
        if (this._qs.menu.isOpen)
            this._open();
    }

    _open() {
        this._close();
        this._cancellable = new Gio.Cancellable();
        this._failed = new Set();
        this._connecting = new Set();
        this._client = new GnomeBluetooth.Client();
        this._clientSignals = new Signals();
        this._watched = new Set();
        for (const name of ['notify::default-adapter-powered', 'notify::num-adapters'])
            this._clientSignals.connect(this._client, name, () => this._refresh());
        this._clientSignals.connect(this._client.get_devices(), 'items-changed', () => this._refresh());
        this._refresh();
    }

    _close() {
        this._cancellable?.cancel();
        this._cancellable = null;
        this._clientSignals?.disconnectAll();
        this._clientSignals = null;
        this._watched = null;
        this._client?.run_dispose(); // freed now, not at the next garbage collection
        this._client = null;
        this._shown = [];
        this._tiles.forEach(t => (t.visible = false));
    }

    _refresh() {
        const client = this._client;
        if (!client)
            return;
        const list = client.get_devices();
        const devices = [];
        for (let i = 0; i < list.get_n_items(); i++) {
            const d = list.get_item(i);
            if (!this._watched.has(d)) {
                this._watched.add(d);
                this._clientSignals.connect(d, 'notify::connected', () => this._refresh());
            }
            devices.push({device: d, path: d.get_object_path(), address: d.address, alias: d.alias, paired: d.paired, connected: d.connected});
        }
        const live = client.default_adapter && client.default_adapter_powered;
        this._shown = live ? pickRecent(devices, this._settings.get_strv('bluetooth-recent')) : [];
        this._tiles.forEach((tile, i) => {
            const d = this._shown[i];
            tile.visible = !!d;
            if (!d)
                return;
            tile.title = d.alias;
            tile.accessible_name = d.alias;
            tile.get_accessible().accessible_description = this._failed.has(d.path) ? FAILED_HINT : '';
            tile.iconName = d.device.icon ? `${d.device.icon}-symbolic` : 'bluetooth-active-symbolic';
            tile.checked = d.connected;
            tile.subtitle = this._connecting.has(d.path) ? 'Connecting…'
                : this._failed.has(d.path) ? FAILED
                    : d.connected ? 'Connected' : 'Not connected';
        });
        // What is connected right now counts as recent (BlueZ keeps no connection history of its own).
        this._remember(devices.filter(d => d.connected).map(d => d.address));
    }

    // Addresses we haven't stored go to the front; known ones keep their place (GnomeBluetooth's list order varies).
    _remember(addresses, promote = false) {
        const now = this._settings.get_strv('bluetooth-recent');
        const fresh = addresses.filter(a => promote || !now.includes(a));
        const next = [...fresh, ...now.filter(a => !fresh.includes(a))].slice(0, KEPT);
        if (next.join() !== now.join())
            this._settings.set_strv('bluetooth-recent', next);
    }

    _press(tile) {
        const d = this._shown?.[this._tiles.indexOf(tile)];
        if (!d || !this._client || this._connecting.has(d.path))
            return;
        const connect = !d.connected;
        this._failed.delete(d.path);
        this._connecting.add(d.path);
        this._refresh();
        this._client.connect_service(d.path, connect, this._cancellable, (client, res) => {
            try {
                client.connect_service_finish(res);
            } catch (e) {
                if (e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                    return; // the menu closed; the client is gone
                this._failed.add(d.path);
            }
            if (connect && !this._failed.has(d.path))
                this._remember([d.address], true);
            this._connecting.delete(d.path);
            this._refresh();
        });
    }

    destroy() {
        this._menuSignals.disconnectAll();
        this._close();
        this._indicator.quickSettingsItems.forEach(i => i.destroy());
        this._indicator.destroy();
    }
}
