// SPDX-License-Identifier: GPL-2.0-or-later
// _lib/timers.js: a repeating timer that follows the power state and stops while the screen is locked.
//
//   const t = new PowerAwareTimer({ac: 2, battery: 5, saver: 10}, () => update());
//   t.start(); ... t.stop();     (a stopped timer is done: make a new one to start again)
//
// Intervals under a second (pointer checks, which the user feels) are millisecond timers at default
// priority; whole seconds use the seconds clock, which lets GLib batch wake-ups.
//
// Power state comes from UPower (OnBattery) and power-profiles-daemon (ActiveProfile) over D-Bus,
// using property-change signals: nothing here polls.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {Signals} from './signals.js';

// power-profiles-daemon's bus name and path, newest first (its name is also its interface).
export const PROFILES_BUSES = [
    ['org.freedesktop.UPower.PowerProfiles', '/org/freedesktop/UPower/PowerProfiles'],
    ['net.hadess.PowerProfiles', '/net/hadess/PowerProfiles'],
];

// A proxy for a system service that is running, or null. `start`: start it if it isn't yet (D-Bus
// activation), for a service that only runs on demand.
export function proxy(name, path, iface, cancellable, {start = false} = {}) {
    return new Promise(resolve => {
        Gio.DBusProxy.new_for_bus(Gio.BusType.SYSTEM, start ? Gio.DBusProxyFlags.NONE : Gio.DBusProxyFlags.DO_NOT_AUTO_START, null,
            name, path, iface, cancellable, (_o, res) => {
                try {
                    const p = Gio.DBusProxy.new_for_bus_finish(res);
                    resolve(p.get_name_owner() ? p : null);
                } catch {
                    resolve(null);
                }
            });
    });
}

// power-profiles-daemon under whichever name it runs, or null. Started if it isn't running yet: on
// some systems it starts only on demand, and a proxy made before that never saw power saver (GNOME's
// own power menu starts it the same way).
export async function profilesProxy(cancellable) {
    for (const [name, path] of PROFILES_BUSES) {
        const p = await proxy(name, path, name, cancellable, {start: true});
        if (p)
            return p;
    }
    return null;
}

function addTimeout(interval, fn) {
    if (Number.isInteger(interval))
        return GLib.timeout_add_seconds(GLib.PRIORITY_LOW, interval, fn);
    return GLib.timeout_add(GLib.PRIORITY_DEFAULT, Math.round(interval * 1000), fn);
}

export class PowerAwareTimer {
    // intervals in seconds, fractions allowed: {ac, battery, saver}
    constructor(intervals, callback) {
        this._intervals = intervals;
        this._callback = callback;
        this._signals = new Signals();
        this._cancellable = new Gio.Cancellable();
        this._source = 0;
        this._onBattery = false;
        this._saver = false;
        this._locked = false;
        this._running = false;
        this._current = 0;
    }

    get state() {
        return {onBattery: this._onBattery, saver: this._saver, locked: this._locked, interval: this._current};
    }

    async start() {
        this._running = true;
        if (Main.screenShield) {
            this._locked = Main.screenShield.active;
            this._signals.connect(Main.screenShield, 'active-changed', () => {
                this._locked = Main.screenShield.active;
                this._reschedule(!this._locked);
            });
        }
        this._reschedule(true);

        const upower = await proxy('org.freedesktop.UPower', '/org/freedesktop/UPower', 'org.freedesktop.UPower', this._cancellable);
        if (!this._running)
            return;
        if (upower) {
            this._upower = upower;
            this._readUpower();
            this._signals.connect(upower, 'g-properties-changed', () => this._readUpower());
        }
        const p = await profilesProxy(this._cancellable);
        if (!this._running)
            return;
        if (p) {
            this._profiles = p;
            this._readProfile();
            this._signals.connect(p, 'g-properties-changed', () => this._readProfile());
        }
    }

    stop() {
        this._running = false;
        this._cancellable.cancel();
        this._signals.disconnectAll();
        this._clear();
        this._upower = this._profiles = null;
    }

    _readUpower() {
        const v = this._upower?.get_cached_property('OnBattery');
        const onBattery = v ? v.unpack() : false;
        if (onBattery !== this._onBattery) {
            this._onBattery = onBattery;
            this._reschedule(false);
        }
    }

    _readProfile() {
        const v = this._profiles?.get_cached_property('ActiveProfile');
        const saver = v ? v.unpack() === 'power-saver' : false;
        if (saver !== this._saver) {
            this._saver = saver;
            this._reschedule(false);
        }
    }

    _interval() {
        if (this._saver)
            return this._intervals.saver;
        return this._onBattery ? this._intervals.battery : this._intervals.ac;
    }

    _clear() {
        if (this._source) {
            GLib.source_remove(this._source);
            this._source = 0;
        }
        this._current = 0;
    }

    // Restarts the timer at the current interval; `fireNow` runs the callback straight away.
    _reschedule(fireNow) {
        if (!this._running)
            return;
        const interval = this._locked ? 0 : this._interval();
        if (this._source && interval === this._current)
            return;
        this._clear();
        if (interval === 0)
            return; // locked: no timer at all
        this._current = interval;
        // why: what the callback checks changes without any signal to wait on; the interval follows
        // the power mode and the screen lock stops it (above).
        this._source = addTimeout(interval, () => {
            this._safeCall();
            return GLib.SOURCE_CONTINUE;
        });
        if (fireNow)
            this._safeCall(); // after scheduling, so a callback that stops the timer stops it for good
    }

    _safeCall() {
        try {
            const r = this._callback();
            r?.catch?.(e => console.warn(`timer callback failed: ${e.message}`));
        } catch (e) {
            console.warn(`timer callback failed: ${e.message}`);
        }
    }
}

// Geometry that follows another actor's allocation, done just before the next frame is drawn (and
// once, however many changes came): moving or resizing from inside a 'notify::allocation' handler
// happens during GNOME's layout pass, which then logs "Can't update stage views actor … because it
// needs an allocation" and lays the actor out a frame late.
export class BeforeRedraw {
    constructor(fn) {
        this._fn = fn;
        this._id = 0;
    }

    queue() {
        if (this._id)
            return;
        this._id = global.compositor.get_laters().add(Meta.LaterType.BEFORE_REDRAW, () => {
            this._id = 0;
            this._fn();
            return GLib.SOURCE_REMOVE;
        });
    }

    cancel() {
        if (this._id)
            global.compositor.get_laters().remove(this._id);
        this._id = 0;
    }
}
