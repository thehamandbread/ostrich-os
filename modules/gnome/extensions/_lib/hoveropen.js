// SPDX-License-Identifier: GPL-2.0-or-later
// _lib/hoveropen.js: open a top-bar button's menu by resting the pointer on it, as drawer icons do
//. The pointer has to stop moving for
// DELAY_MS, so passing over the button does nothing. A menu opened this way closes once the pointer
// has been off both the button and the menu for CLOSE_MS. A menu opened with a click, or one the
// user clicked inside, stays open as usual.
// Timers run only while the pointer is on the button or a hover-opened menu is open: nothing at idle.
// Vendored into each extension at build time (see build.sh).

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';

export const CLOSE_MS = 500; // the drawer's HOVER_CLOSE_MS
const CHECK_MS = 100;

function inside(actor, x, y) {
    if (!actor?.mapped)
        return false;
    const [ax, ay] = actor.get_transformed_position();
    const [w, h] = actor.get_transformed_size();
    return x >= ax && x < ax + w && y >= ay && y < ay + h;
}

export class HoverOpen {
    // button: a PanelMenu.Button; delayMs: how long the pointer must rest before the menu opens
    constructor(button, delayMs = 500) {
        this._button = button;
        this._delayMs = delayMs;
        this._openTimer = 0;
        this._closeTimer = 0;
        this._outsideSince = null;
        this._ids = [
            [button, button.connect('notify::hover', () => (button.hover ? this._arm() : this._disarm()))],
            [button, button.connect('motion-event', () => {
                if (this._openTimer)
                    this._arm(); // moving restarts the wait: only a real pause opens it
                return Clutter.EVENT_PROPAGATE;
            })],
            [button.menu, button.menu.connect('open-state-changed', (_m, open) => {
                if (!open)
                    this._stopClose();
            })],
            // A click inside the menu means it's in use: it stays until closed the usual way.
            [button.menu.actor, button.menu.actor.connect('button-press-event', () => {
                this._stopClose();
                return Clutter.EVENT_PROPAGATE;
            })],
        ];
        // A button destroyed first (its owner went away) takes this with it: no timer outlives it.
        this._destroyId = button.connect('destroy', () => {
            this._ids = []; // its signals went with it
            this.destroy();
        });
    }

    _arm() {
        this._disarm();
        if (this._button.menu.isOpen)
            return;
        this._openTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, this._delayMs, () => {
            this._openTimer = 0;
            if (this._button.hover && !this._button.menu.isOpen) {
                this._button.menu.toggle();
                this._startClose();
            }
            return GLib.SOURCE_REMOVE;
        });
    }

    _disarm() {
        if (this._openTimer)
            GLib.source_remove(this._openTimer);
        this._openTimer = 0;
    }

    _startClose() {
        this._outsideSince = null;
        // why: repeats only while a menu opened by hovering is open (stopped when it closes); GNOME
        // has no signal for the pointer leaving the menu and its button together.
        this._closeTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, CHECK_MS, () => {
            const [x, y] = global.get_pointer();
            if (inside(this._button, x, y) || inside(this._button.menu.actor, x, y)) {
                this._outsideSince = null;
                return GLib.SOURCE_CONTINUE;
            }
            const now = GLib.get_monotonic_time() / 1000;
            this._outsideSince ??= now;
            if (now - this._outsideSince < CLOSE_MS)
                return GLib.SOURCE_CONTINUE;
            this._closeTimer = 0;
            if (this._button.menu.isOpen)
                this._button.menu.toggle(); // closes with the same animation as a click
            return GLib.SOURCE_REMOVE;
        });
    }

    _stopClose() {
        if (this._closeTimer)
            GLib.source_remove(this._closeTimer);
        this._closeTimer = 0;
    }

    destroy() {
        this._disarm();
        this._stopClose();
        for (const [obj, id] of this._ids)
            obj.disconnect(id);
        this._ids = [];
        if (this._destroyId)
            this._button.disconnect(this._destroyId);
        this._destroyId = 0;
    }
}
