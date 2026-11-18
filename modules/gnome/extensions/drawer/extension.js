// SPDX-License-Identifier: GPL-2.0-or-later
// Ostrich Drawer: the shell side of the web-app drawer (DESIGN.md: drawer, drawer-host).
//
// The drawer itself is the ostrich-drawer app. This extension:
//   - shows an icon per site in the top bar (bar.js), from the app's published state, and opens a
//     site with a click or by hovering over its icon; a click on the open site's icon folds it up;
//   - toggles it with a hotkey (Super+Alt+D), starting the app on first use;
//   - places its main window under the site's icon (or top centre, top-left or top-right), at the
//     site's own size, and grows it out of the icon and folds it back; a size the user drags it to is remembered
//     for that site;
//   - keeps it above other windows, on every workspace, out of Alt+Tab, without the shell's
//     minimize/unminimize animation (the slide replaces it);
//   - hides it when another window gets focus, if the setting is on, and, when hovering opened
//     it, once the pointer has left it and the bar (unless the user clicked or typed in it).
// Hidden means minimized, so WebKit throttles the pages and the drawer costs nothing on screen.
// The app's state comes as D-Bus signals; the only timers are the hover delay and, while a drawer
// opened by hovering is shown, a pointer check every 200 ms (400 ms on battery, none while locked).

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Workspace from 'resource:///org/gnome/shell/ui/workspace.js';
import * as WorkspaceThumbnail from 'resource:///org/gnome/shell/ui/workspaceThumbnail.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {animate, stop, QUICK, STANDARD} from './_lib/motion.js';
import {Patches} from './_lib/patches.js';
import {PowerAwareTimer} from './_lib/timers.js';
import {Signals} from './_lib/signals.js';
import {DrawerBar} from './bar.js';
import {siteSize, placeUnder, inside, hoverStep, hoverDelay} from './barlogic.js';

const APP_ID = 'ubuntu_ostrich.drawer';
const APP_PATH = '/ubuntu_ostrich/drawer'; // GApplication turns '.' and '-' into '/' and '_'
// Opening grows the drawer down out of its icon: a little scale and lift, and a fade.
const FROM = {scale_x: 0.96, scale_y: 0.9, opacity: 0, translation_y: -16};
const TO = {scale_x: 1, scale_y: 1, opacity: 255, translation_y: 0};
const EDGE_GAP = 8; // from the screen side in the corner positions
// seconds, as PowerAwareTimer takes them
const HOVER_CHECK = {ac: 0.2, battery: 0.4, saver: 0.4};

function isDrawerApp(win) {
    return win?.get_gtk_application_id?.() === APP_ID || win?.get_wm_class?.() === APP_ID;
}

// The main drawer window: sign-in pop-ups are transient for it and are left alone.
function isDrawer(win) {
    return isDrawerApp(win) && !win.get_transient_for() && win.get_window_type() === Meta.WindowType.NORMAL;
}

function libexec(cmd) {
    const ours = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'libexec', 'ubuntu-ostrich', cmd]);
    return GLib.file_test(ours, GLib.FileTest.IS_EXECUTABLE) ? ours : GLib.find_program_in_path(cmd) ?? ours;
}

export default class DrawerExtension extends Extension {
    enable() {
        this._settings = this.getSettings();
        this._signals = new Signals();
        this._winSignals = new Signals();
        this._hostSignals = new Signals();
        this._patches = new Patches();
        this._win = null;
        this._sliding = false;
        this._pending = new Map(); // new window → its one-shot handler ids
        this._state = null; // the app's published state (null: not running)
        this._group = null;
        this._hoverOpened = false;
        this._hoverOpenId = 0;
        this._hoverCheck = null; // PowerAwareTimer, while a drawer opened by hovering is shown
        this._outsideSince = null;

        // activate() says whether the drawer was there to take it.
        this.host = {
            activate: (name, param = null) => {
                this._group?.activate_action(name, param);
                return Boolean(this._group);
            },
        };
        this._bar = new DrawerBar({
            host: this.host,
            settings: this._settings,
            clicked: id => this._clicked(id),
            open: id => this._open(id, false),
            hoverEnter: id => this._hoverEnter(id),
            hoverLeave: () => this._cancelHoverOpen(),
            hoverMove: id => this._hoverMove(id),
            openSettings: () => this._spawn([libexec('ostrich-setup'), '--step', 'drawer']),
        });

        // Every switcher (Alt+Tab, Super+Tab, the window switcher) goes through get_tab_list.
        this._patches.replace(Meta.Display.prototype, 'get_tab_list', orig => function (type, workspace) {
            return orig.call(this, type, workspace).filter(w => !isDrawerApp(w));
        });
        // Nor in the overview or its workspace thumbnails: there it would be a window anyone could
        // close (GNOME's filter is skip_taskbar, which a Wayland app can't set).
        this._patches.replace(Workspace.Workspace.prototype, '_isOverviewWindow', orig => function (win) {
            return !isDrawerApp(win) && orig.call(this, win);
        });
        this._patches.replace(WorkspaceThumbnail.WorkspaceThumbnail.prototype, '_isOverviewWindow', orig => function (win) {
            return !isDrawerApp(win.get_meta_window?.()) && orig.call(this, win);
        });
        this._patches.replace(Main.wm, '_shouldAnimateActor', orig => function (actor, types) {
            return isDrawer(actor?.meta_window) ? false : orig.call(this, actor, types);
        });

        // A Wayland window's app id isn't known yet at window-created; check once it's shown.
        this._signals.connect(global.display, 'window-created', (_d, win) => this._watchNew(win));
        this._signals.connect(global.display, 'notify::focus-window', () => this._onFocusChanged());
        // The user resized the drawer (grips, or Super+right-drag): remember it for this site.
        // Read once the drag has settled: at grab-op-end the last resize step hasn't reached the
        // window yet, so the size saved was a step short and the site reopened smaller each time.
        this._signals.connect(global.display, 'grab-op-end', (_d, win) => {
            const id = this._state?.active;
            if (win !== this._win || !id)
                return;
            if (this._sizeId)
                GLib.source_remove(this._sizeId);
            this._sizeId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 200, () => {
                this._sizeId = 0;
                if (this._win === win && this._state?.active === id) {
                    const r = win.get_frame_rect();
                    this.host.activate('set-size', new GLib.Variant('(suu)', [id, r.width, r.height]));
                }
                return GLib.SOURCE_REMOVE;
            });
        });
        for (const key of ['position', 'width', 'height'])
            this._signals.connect(this._settings, `changed::${key}`, () => this._replace());
        this._signals.connect(this._settings, 'changed::bar-max', () => this._bar.update(this._state));
        this._signals.connect(Main.layoutManager, 'monitors-changed', () => this._replace());
        global.display.list_all_windows().forEach(w => this._maybeAdopt(w));

        this._nameWatch = Gio.bus_watch_name(Gio.BusType.SESSION, APP_ID, Gio.BusNameWatcherFlags.NONE,
            () => this._hostAppeared(), () => this._hostVanished());

        Main.wm.addKeybinding('toggle-drawer', this._settings, Meta.KeyBindingFlags.NONE,
            Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW, () => this.toggle());
    }

    disable() {
        if (this._sizeId)
            GLib.source_remove(this._sizeId);
        this._sizeId = 0;
        if (this._placeLater)
            global.compositor.get_laters().remove(this._placeLater);
        this._placeLater = 0;
        Main.wm.removeKeybinding('toggle-drawer');
        Gio.bus_unwatch_name(this._nameWatch);
        this._hostVanished();
        this._bar.destroy();
        this._bar = null;
        this._signals.disconnectAll();
        for (const win of [...this._pending.keys()])
            this._unwatch(win);
        this._forget();
        this._patches.restoreAll();
        this._settings = null;
    }

    // ---- the app's published state ----

    _hostAppeared() {
        this._group = Gio.DBusActionGroup.get(Gio.DBus.session, APP_ID, APP_PATH);
        const read = () => {
            const v = this._group?.get_action_state('state');
            if (v)
                this._onState(v.unpack());
        };
        this._hostSignals.connect(this._group, 'action-added', (_g, name) => {
            if (name === 'state')
                read();
        });
        this._hostSignals.connect(this._group, 'action-state-changed', (_g, name, value) => {
            if (name === 'state')
                this._onState(value.unpack());
        });
        this._group.list_actions(); // starts loading the actions; action-added follows
        read();
        if (this._win)
            this._reportVisible();
    }

    _hostVanished() {
        this._hostSignals.disconnectAll();
        this._group = null;
        this._state = null;
        this._stopHover();
        this._bar?.update(null);
    }

    _onState(json) {
        let state;
        try {
            state = JSON.parse(json);
        } catch {
            return;
        }
        const before = this._state;
        this._state = state;
        this._bar.update(state);
        // The app asked to be shown (a click, a notification): only the shell can unminimize it.
        if (before && state.showRequests !== before.showRequests && this._win?.minimized)
            this._win.unminimize();
        // And to be folded up (Esc, Ctrl+W, a close request): with the animation.
        if (before && state.hideRequests !== before.hideRequests)
            this._slideOut();
        // Another site while shown: its own size and place.
        if (before && before.active !== state.active) {
            this._placeTries = 0;
            this._replace();
        }
        if (state.engaged)
            this._stopHover();
    }

    _site(id = this._state?.active) {
        return this._state?.sites?.find(s => s.id === id) ?? null;
    }

    _shown() {
        return !!this._win && !this._win.minimized;
    }

    // ---- opening sites ----

    _spawn(argv) {
        try {
            Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
        } catch (e) {
            console.warn(`drawer: could not start ${argv[0]}: ${e.message}`);
            Main.notifyError('Ostrich Drawer', `${GLib.path_get_basename(argv[0])} isn't installed.`);
        }
    }

    _open(id, byHover) {
        this._hoverOpened = byHover;
        if (!this._group) {
            this._spawn([libexec(this._settings.get_string('host-command')), '--show', id]);
            return;
        }
        this.host.activate('show', new GLib.Variant('s', id));
        if (byHover)
            this._startHoverCheck();
        else
            this._stopHover();
    }

    // A click on a site's icon: open it; on the open site, fold it up. A drawer opened by hovering
    // stays open on the first click instead (the pointer was already there).
    _clicked(id) {
        this._cancelHoverOpen();
        if (this._shown() && this._state?.active === id) {
            if (this._hoverOpened)
                this._stopHover();
            else
                this._slideOut();
            return;
        }
        this._open(id, false);
    }

    // Hovering opens a site only after the pointer rests on its icon (moving restarts the wait), so
    // sweeping the pointer across the bar opens nothing.
    _hoverEnter(id) {
        this._cancelHoverOpen();
        if (!this._settings.get_boolean('open-on-hover') || Main.overview.visible)
            return;
        const shown = this._shown();
        const delay = hoverDelay({
            shown, active: this._state?.active, id,
            delay: this._settings.get_uint('hover-delay-ms'),
            switchDelay: this._settings.get_uint('hover-switch-ms'),
        });
        if (delay === null)
            return;
        this._hoverTarget = id;
        this._hoverOpenId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, delay, () => {
            this._hoverOpenId = 0;
            this._hoverTarget = null;
            this._open(id, shown ? this._hoverOpened : true);
            return GLib.SOURCE_REMOVE;
        });
    }

    _hoverMove(id) {
        if (this._hoverOpenId && this._hoverTarget === id)
            this._hoverEnter(id);
    }

    _cancelHoverOpen() {
        if (this._hoverOpenId) {
            GLib.source_remove(this._hoverOpenId);
            this._hoverOpenId = 0;
        }
    }

    // While a drawer opened by hovering is shown: close it once the pointer has been away from it
    // and the bar for a moment, unless the user clicked or typed in it.
    _startHoverCheck() {
        this._outsideSince = null;
        if (this._hoverCheck)
            return;
        // why: the drawer is another app's window, so the shell gets no pointer events over it;
        // runs only while a drawer opened by hovering is shown, and stops once it's clicked.
        this._hoverCheck = new PowerAwareTimer(HOVER_CHECK, () => {
            if (!this._hoverOpened || this._state?.engaged || !this._win) {
                this._stopHoverCheck();
                this._hoverOpened = this._hoverOpened && !this._state?.engaged;
                return;
            }
            if (this._win.minimized && !this._sliding)
                return; // still opening
            const [x, y] = global.get_pointer();
            const step = hoverStep({
                outsideSince: this._outsideSince,
                engaged: !!this._state?.engaged,
                now: GLib.get_monotonic_time() / 1000,
                pointerInside: inside(this._win.get_frame_rect(), x, y) || this._bar.contains(x, y),
            });
            this._outsideSince = step.outsideSince;
            if (step.close) {
                this._stopHoverCheck();
                this._hoverOpened = false;
                this._slideOut();
            }
        });
        this._hoverCheck.start();
    }

    _stopHoverCheck() {
        this._hoverCheck?.stop();
        this._hoverCheck = null;
    }

    _stopHover() {
        this._cancelHoverOpen();
        this._hoverOpened = false;
        this._stopHoverCheck();
    }

    toggle() {
        const win = this._win;
        this._stopHover();
        if (!win) {
            this._spawn([libexec(this._settings.get_string('host-command'))]);
        } else if (win.minimized) {
            win.unminimize(); // notify::minimized slides it in
        } else if (!win.has_focus()) {
            win.activate(global.get_current_time());
        } else {
            this._slideOut();
        }
    }

    // ---- the window ----

    _watchNew(win) {
        this._pending.set(win, [
            win.connect('shown', () => {
                this._unwatch(win);
                this._maybeAdopt(win);
                this._placePopup(win);
            }),
            win.connect('unmanaged', () => this._unwatch(win)),
        ]);
    }

    // A sign-in pop-up from a site: centred over the drawer and kept above it.
    _placePopup(win) {
        if (!isDrawerApp(win) || !win.get_transient_for() || !this._win)
            return;
        const d = this._win.get_frame_rect();
        const r = win.get_frame_rect();
        win.make_above();
        win.move_frame(true, d.x + Math.round((d.width - r.width) / 2), d.y + Math.max(0, Math.round((d.height - r.height) / 3)));
    }

    _unwatch(win) {
        this._pending.get(win)?.forEach(id => win.disconnect(id));
        this._pending.delete(win);
    }

    _maybeAdopt(win) {
        if (this._win || !isDrawer(win))
            return;
        this._win = win;
        win.make_above();
        win.stick();
        this._winSignals.connect(win, 'unmanaged', () => this._forget());
        this._winSignals.connect(win, 'notify::minimized', () => {
            this._reportVisible();
            if (!win.minimized)
                this._slideIn();
            else
                this._stopHover();
        });
        this._reportVisible();
        if (!win.minimized)
            this._slideIn();
    }

    // Wayland doesn't tell an app it was minimized; the drawer needs to know (power saver keeps the
    // site on screen loaded, and hiding ends "engaged").
    _reportVisible() {
        const shown = !!this._win && !this._win.minimized;
        this.host.activate('visible', GLib.Variant.new_boolean(shown));
        this._watchClicks(shown);
    }

    _forget() {
        this._watchClicks(false);
        this._winSignals.disconnectAll();
        this._stopHover();
        const actor = this._win?.get_compositor_private();
        if (actor) {
            stop(actor);
            actor.set(TO);
        }
        this._win = null;
        this._sliding = false;
    }

    // A site's icon, if it's laid out where it will stay (not mid-rebuild).
    _readyIcon(id) {
        const icon = this._bar.buttonFor(id);
        if (!icon?.visible || !icon.mapped || !icon.has_allocation())
            return null;
        const [iw] = icon.get_transformed_size();
        return iw > 0 ? icon : null;
    }

    _rect() {
        const m = Main.layoutManager.primaryMonitor;
        const top = Main.panel.height;
        const area = {width: m.width, height: m.height - top};
        const site = this._site() ?? {shape: 'wide', width: 0, height: 0};
        const {width, height} = siteSize(site, area, {
            width: this._settings.get_uint('width'),
            height: this._settings.get_uint('height'),
        });
        const gap = width < m.width ? EDGE_GAP : 0;
        const position = this._settings.get_string('position');
        let x = m.x + Math.round((m.width - width) / 2);
        const icon = position === 'under-icon' ? this._readyIcon(site.id) : null;
        if (icon) {
            const [ix] = icon.get_transformed_position();
            const [iw] = icon.get_transformed_size();
            x = placeUnder(ix + iw / 2, width, m, EDGE_GAP);
            this._lastPlace = {id: site.id, x};
            this._placeTries = 0;
        } else if (position === 'under-icon' && site.id) {
            // The icon is being laid out (the bar redraws as the site changes): keep the last good
            // place for this site meanwhile, and place it again once the icon has its spot.
            if (this._lastPlace?.id === site.id)
                x = this._lastPlace.x;
            this._placeWhenReady(site.id);
        } else if (position === 'top-left') {
            x = m.x + gap;
        } else if (position === 'top-right') {
            x = m.x + m.width - width - gap;
        }
        return {x, y: m.y + top, width, height};
    }

    // Places the drawer again just before the next redraw, by when the icon is usually laid out;
    // tries for a few frames, then leaves it where it is.
    _placeWhenReady(id) {
        if (this._placeLater || (this._placeTries ?? 0) >= 10)
            return;
        this._placeTries = (this._placeTries ?? 0) + 1;
        this._placeLater = global.compositor.get_laters().add(Meta.LaterType.BEFORE_REDRAW, () => {
            this._placeLater = 0;
            if (this._state?.active === id)
                this._replace();
            return GLib.SOURCE_REMOVE;
        });
    }

    _replace() {
        if (this._win && !this._win.minimized) {
            const r = this._rect();
            this._win.move_resize_frame(false, r.x, r.y, r.width, r.height);
        }
    }

    // The point the drawer grows from and folds into: under its site's icon, else the top middle.
    _pivot(r) {
        const icon = this._bar.buttonFor(this._state?.active);
        if (!icon?.visible)
            return 0.5;
        const [ix] = icon.get_transformed_position();
        const [iw] = icon.get_transformed_size();
        return Math.min(1, Math.max(0, (ix + iw / 2 - r.x) / r.width));
    }

    _slideIn() {
        const win = this._win;
        const actor = win?.get_compositor_private();
        if (!actor)
            return;
        const r = this._rect();
        win.move_resize_frame(false, r.x, r.y, r.width, r.height);
        win.activate(global.get_current_time());
        this._sliding = true;
        stop(actor); // a slide-out still running is dropped, so it can't minimise the drawer after this
        actor.set_pivot_point(this._pivot(r), 0);
        actor.set(FROM);
        animate(actor, TO, {
            duration: STANDARD,
            onDone: () => {
                this._sliding = false;
            },
        });
    }

    // While the drawer is down: a click anywhere outside it (the wallpaper, the top bar, a menu)
    // folds it up. Clicks on other windows already move the focus away (_onFocusChanged).
    _watchClicks(on) {
        if (!on) {
            if (this._clickId)
                global.stage.disconnect(this._clickId);
            this._clickId = 0;
            return;
        }
        if (this._clickId)
            return;
        this._clickId = global.stage.connect('captured-event', (_s, event) => {
            const type = event.type();
            if (type !== Clutter.EventType.BUTTON_PRESS && type !== Clutter.EventType.TOUCH_BEGIN)
                return Clutter.EVENT_PROPAGATE;
            const [x, y] = event.get_coords();
            const ours = global.display.list_all_windows().filter(w => isDrawerApp(w) && !w.minimized);
            if (!this._sliding && !ours.some(w => inside(w.get_frame_rect(), x, y)) && !this._bar.contains(x, y))
                this._slideOut();
            return Clutter.EVENT_PROPAGATE;
        });
    }

    _slideOut() {
        const win = this._win;
        const actor = win?.get_compositor_private();
        this._stopHover();
        if (!actor || win.minimized)
            return;
        this._sliding = true;
        stop(actor);
        actor.set_pivot_point(this._pivot(win.get_frame_rect()), 0);
        animate(actor, FROM, {
            duration: QUICK,
            mode: Clutter.AnimationMode.EASE_IN_QUAD,
            onDone: () => {
                this._sliding = false;
                if (this._win === win)
                    win.minimize();
                actor.set(TO);
            },
        });
    }

    // Focus went to another window: a click outside the drawer.
    _onFocusChanged() {
        const win = this._win;
        if (!win || win.minimized || this._sliding || !this._settings.get_boolean('hide-on-focus-loss'))
            return;
        const focus = global.display.focus_window;
        if (focus && !isDrawerApp(focus))
            this._slideOut();
    }
}
