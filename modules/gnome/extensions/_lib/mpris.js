// SPDX-License-Identifier: GPL-2.0-or-later
// _lib/mpris.js: the media players on the session bus (MPRIS), followed by signals, no timers. Used
// by the now-playing pill (tweaks) and the dock's speaker badge. GNOME's mixer (Gvc) can't tell a
// playing stream from an open one in GNOME 50 (its state reads INVALID), and often has no app id;
// players say both: PlaybackStatus and DesktopEntry.
// Vendored into each extension at build time (see build.sh). No GNOME Shell imports: the gjs tests
// load it.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const PREFIX = 'org.mpris.MediaPlayer2.';
const PATH = '/org/mpris/MediaPlayer2';

const PlayerProxy = Gio.DBusProxy.makeProxyWrapper(`<node>
<interface name="org.mpris.MediaPlayer2.Player">
  <method name="PlayPause"/><method name="Next"/><method name="Previous"/>
  <property name="PlaybackStatus" type="s" access="read"/>
  <property name="Metadata" type="a{sv}" access="read"/>
  <property name="CanGoNext" type="b" access="read"/><property name="CanGoPrevious" type="b" access="read"/>
</interface></node>`);

// title and artist from an MPRIS Metadata a{sv} (already unpacked one level).
export function fromMetadata(md) {
    const s = v => (typeof v === 'string' ? v : '');
    const artists = Array.isArray(md?.['xesam:artist']) ? md['xesam:artist'].filter(a => typeof a === 'string') : [];
    return {title: s(md?.['xesam:title']).trim(), artist: artists.join(', ')};
}

/**
 * The apps playing now, as desktop-file ids ("firefox.desktop"), from players' DesktopEntry.
 *
 * @param {Array<{status: string, desktopEntry: string}>} players
 * @returns {Set<string>}
 */
export function playingApps(players) {
    return new Set(players.filter(p => p.status === 'Playing' && p.desktopEntry)
        .map(p => (p.desktopEntry.endsWith('.desktop') ? p.desktopEntry : `${p.desktopEntry}.desktop`)));
}

export class Players {
    /** @param {() => void} onChange  any player came, went, or changed its state or track */
    constructor(onChange) {
        this._onChange = onChange;
        this._players = new Map(); // bus name -> {proxy, changedId, desktopEntry} (null while connecting)
        this._cancellable = new Gio.Cancellable();
        this._ownerId = Gio.DBus.session.signal_subscribe('org.freedesktop.DBus', 'org.freedesktop.DBus',
            'NameOwnerChanged', '/org/freedesktop/DBus', null, Gio.DBusSignalFlags.NONE,
            (_c, _s, _p, _i, _sig, params) => {
                const [name, , owner] = params.deep_unpack();
                if (!name.startsWith(PREFIX))
                    return;
                if (owner)
                    this._add(name);
                else
                    this._remove(name);
            });
        Gio.DBus.session.call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
            'ListNames', null, null, Gio.DBusCallFlags.NONE, -1, this._cancellable, (c, res) => {
                try {
                    const [names] = c.call_finish(res).deep_unpack();
                    names.filter(n => n.startsWith(PREFIX)).forEach(n => this._add(n));
                } catch (e) {
                    if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                        console.warn(`mpris: ${e.message}`);
                }
            });
    }

    /** [{name, proxy, status, title, artist, desktopEntry}] for every connected player. */
    list() {
        return [...this._players].filter(([, p]) => p).map(([name, {proxy, desktopEntry}]) => ({
            name, proxy, desktopEntry, status: proxy.PlaybackStatus ?? '',
            ...fromMetadata(proxy.Metadata ? Object.fromEntries(Object.entries(proxy.Metadata).map(([k, v]) => [k, v.deep_unpack()])) : {}),
        }));
    }

    _add(name) {
        if (this._players.has(name))
            return;
        this._players.set(name, null);
        PlayerProxy(Gio.DBus.session, name, PATH, (proxy, error) => {
            if (error || !this._players.has(name)) // gone already, or destroyed
                return;
            const changedId = proxy.connect('g-properties-changed', () => this._onChange());
            const entry = {proxy, changedId, desktopEntry: ''};
            this._players.set(name, entry);
            this._onChange();
            // Which app it is: the root interface's DesktopEntry, read once.
            Gio.DBus.session.call(name, PATH, 'org.freedesktop.DBus.Properties', 'Get',
                new GLib.Variant('(ss)', ['org.mpris.MediaPlayer2', 'DesktopEntry']), null,
                Gio.DBusCallFlags.NONE, -1, this._cancellable, (c, res) => {
                    try {
                        entry.desktopEntry = c.call_finish(res).deep_unpack()[0].deep_unpack();
                        this._onChange();
                    } catch {
                        // a player without DesktopEntry: not tied to an app
                    }
                });
        }, this._cancellable);
    }

    _remove(name) {
        const p = this._players.get(name);
        p?.proxy.disconnect(p.changedId);
        this._players.delete(name);
        this._onChange();
    }

    destroy() {
        this._cancellable.cancel();
        Gio.DBus.session.signal_unsubscribe(this._ownerId);
        for (const p of this._players.values())
            p?.proxy.disconnect(p.changedId);
        this._players.clear();
    }
}
