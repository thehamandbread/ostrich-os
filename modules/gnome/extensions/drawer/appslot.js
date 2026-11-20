// SPDX-License-Identifier: GPL-2.0-or-later
// drawer/appslot.js: an app pinned to the drawer opens in the same small floating window as a site
// (owner, 2026-11-19): above other windows, on every workspace, kept out of Alt+Tab and the
// overview, placed under its top-bar icon at the drawer's size. One app is out at a time; its icon
// again, a click on another window, or opening a site puts it away (it is minimised, not closed).
//
// The window is the app's own: nothing is embedded. Only the first normal window of the app is
// taken, and it is let go (back to a normal window) when the app is unpinned or the window closes.

import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

const LAUNCH_WAIT_S = 15; // a window that hasn't come by then isn't coming

export class AppSlot {
    /**
     * @param {object} o
     * @param {Gio.Settings} o.settings
     * @param {(id: string) => {x: number, y: number, width: number, height: number}} o.rectFor
     * @param {() => void} o.onChange  the slot's app or visibility changed (the icon's highlight)
     */
    constructor({settings, rectFor, onChange}) {
        this._settings = settings;
        this._rectFor = rectFor;
        this._onChange = onChange;
        this._win = null;
        this._id = null;
        this._winIds = [];
        this._waitApp = null;
        this._waitId = 0;
        this._waitTimer = 0;
        this._focusId = global.display.connect('notify::focus-window', () => this._onFocus());
    }

    /** The desktop id of the app that is out (shown), else null. */
    shownId() {
        return this._win && !this._win.minimized ? this._id : null;
    }

    has(win) {
        return !!win && win === this._win;
    }

    hide() {
        if (this._win && !this._win.minimized)
            this._win.minimize();
        this._onChange();
    }

    // Its icon was clicked: put it away if it is out, else bring it out (launching it if needed).
    toggle(id) {
        if (this._id === id && this.shownId()) {
            this.hide();
            return;
        }
        const app = Shell.AppSystem.get_default().lookup_app(id);
        if (!app)
            return;
        const win = this._windowOf(app);
        if (win) {
            this._adopt(win, id);
            return;
        }
        this._launch(app, id);
    }

    // Apps no longer in the pinned list: let their window go (it stays open as a normal window).
    keepOnly(ids) {
        if (this._id && !ids.includes(this._id))
            this._release();
        if (this._waitApp && !ids.includes(this._waitApp.get_id()))
            this._stopWaiting();
    }

    destroy() {
        global.display.disconnect(this._focusId);
        this._stopWaiting();
        this._release();
    }

    _windowOf(app) {
        return app.get_windows().find(w => w.get_window_type() === Meta.WindowType.NORMAL && !w.get_transient_for()) ?? null;
    }

    _launch(app, id) {
        this._stopWaiting();
        this._waitApp = app;
        this._waitId = app.connect('windows-changed', () => {
            const win = this._windowOf(app);
            if (win) {
                this._stopWaiting();
                this._adopt(win, id);
            }
        });
        this._waitTimer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, LAUNCH_WAIT_S, () => {
            this._waitTimer = 0;
            this._stopWaiting();
            return GLib.SOURCE_REMOVE;
        });
        // Running without a window (a tray app): ask it for one; else start it.
        if (app.state === Shell.AppState.RUNNING)
            app.open_new_window(-1);
        else
            app.activate();
    }

    _stopWaiting() {
        if (this._waitId)
            this._waitApp?.disconnect(this._waitId);
        if (this._waitTimer)
            GLib.source_remove(this._waitTimer);
        this._waitId = this._waitTimer = 0;
        this._waitApp = null;
    }

    _adopt(win, id) {
        if (this._win !== win) {
            this._win?.minimize(); // the app that was out goes away, not just loose
            this._release();
            this._win = win;
            this._winIds = [win.connect('unmanaged', () => this._release(true))];
            win.make_above();
            win.stick();
        }
        this._id = id;
        this._hadFocus = false;
        // Placed now and again as the app maps the window: mutter puts a new window in the middle of
        // the screen after our first move, so a launching app is placed a few times.
        this._place();
        for (const ms of [150, 500, 1200]) {
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
                if (this._win === win && !win.minimized)
                    this._place();
                return GLib.SOURCE_REMOVE;
            });
        }
        win.unminimize();
        win.activate(global.get_current_time());
        this._onChange();
    }

    _place() {
        const r = this._rectFor(this._id);
        this._win?.move_resize_frame(false, r.x, r.y, r.width, r.height);
    }

    // `gone`: the window was closed, so there is nothing to give back.
    _release(gone = false) {
        const win = this._win;
        if (win) {
            this._winIds.forEach(i => win.disconnect(i));
            if (!gone) {
                win.unmake_above();
                win.unstick();
            }
        }
        this._win = null;
        this._id = null;
        this._winIds = [];
        this._onChange();
    }

    // Another window got the focus (a click outside it): put it away, once it had the focus itself.
    _onFocus() {
        const win = this._win;
        if (!win || win.minimized)
            return;
        const focus = global.display.focus_window;
        if (focus === win) {
            this._hadFocus = true;
        } else if (this._hadFocus && focus && focus.get_transient_for() !== win &&
                this._settings.get_boolean('hide-on-focus-loss')) {
            this.hide();
        }
    }
}
