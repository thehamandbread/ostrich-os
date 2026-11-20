// SPDX-License-Identifier: GPL-2.0-or-later
// Dock: an auto-hiding, floating bottom dock, only as wide as its icons, coloured to match the theme.
//
// On top of GNOME's own dash it adds what Dash to Dock users expect: a dot per open window, click
// to minimize or cycle windows, scroll to cycle, window previews on hover, unread badges and
// progress (the Unity launcher API), the Show Apps button at either end, and the monitor choice.
// Middle-click (a new window) and the discrete-GPU launch item come with GNOME's own icons.
// Show Apps and Help wear our own icons (tools/icons/), in this dock only.
//
// Built on GNOME Shell's own Dash (favourites, running apps, drag and drop, app menus), so it
// behaves like the overview's dash. Cost rules (DESIGN.md):
//   - showing is triggered by a pressure barrier on the bottom edge: no pointer polling;
//   - the only timer is the one-shot hide delay, and it only exists while the dock is visible;
//   - intellihide (optional) reacts to window events, it doesn't poll geometry;
//   - fullscreen windows hide it (trackFullscreen).

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Dash from 'resource:///org/gnome/shell/ui/dash.js';
import * as Layout from 'resource:///org/gnome/shell/ui/layout.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {animate, stop, QUICK, SLOW, STANDARD} from './_lib/motion.js';
import {Players, playingApps} from './_lib/mpris.js';
import {readPalette} from './_lib/palette.js';
import {SchemeStyle} from './_lib/scheme.js';
import {Signals} from './_lib/signals.js';
import {BeforeRedraw} from './_lib/timers.js';
import {clickAction, nextWindow, dotCount, hasDockWindow, showAppsAction, mergeLauncherEntry, appIdFromUri, countText} from './docklogic.js';
import {WindowPreviews} from './previews.js';

const PRESSURE_TIMEOUT = 1000; // ms: pressure has to build up within this window
// The gap between the dock and the screen edge (setting edge-gap) is transparent padding *inside*
// the hover area, so the pointer at the very edge (where the pressure barrier shows the dock) counts
// as over the dock.
const PREVIEW_DELAY = 600; // ms of hovering an icon before its window previews show
const LAUNCHER_IFACE = 'com.canonical.Unity.LauncherEntry';

// Running apps whose id starts with one of these are left out of the dock (e.g. the web-app drawer),
// and so are running apps with no window (tray-only apps): they'd widen the dock and move it.
function filteredAppSystem(real, prefixes) {
    // By the app's id, or by its windows' application id: a window GNOME couldn't match to a desktop
    // entry gets a placeholder app ("window:N", a gear icon) that only its window names.
    const named = (app, p) => (app.get_id() ?? '').startsWith(p) ||
        app.get_windows().some(w => (w.get_gtk_application_id() ?? w.get_wm_class() ?? '').startsWith(p));
    const hidden = app => prefixes.some(p => named(app, p)) || !hasDockWindow(app.get_windows());
    return new Proxy(real, {
        get(target, prop) {
            if (prop === 'get_running')
                return () => target.get_running().filter(app => !hidden(app));
            const v = target[prop];
            return typeof v === 'function' ? v.bind(target) : v;
        },
    });
}

// Help's desktop id: Ubuntu's older name and upstream's.
const HELP_IDS = ['yelp.desktop', 'org.gnome.Yelp.desktop'];

// Draws `name` (one of our icons) on a dash BaseIcon, in this dock only; the original if ours isn't
// installed.
function useOwnIcon(baseIcon, name) {
    const create = baseIcon.createIcon;
    baseIcon.createIcon = size => {
        const icon = create(size);
        icon.fallback_gicon = icon.gicon;
        icon.icon_name = name;
        return icon;
    };
    baseIcon._createIconTexture(baseIcon.iconSize);
}

// "#rrggbb" as "r, g, b", or null.
function hexRgb(hex) {
    const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex ?? '');
    return m ? m.slice(1).map(h => parseInt(h, 16)).join(', ') : null;
}

export default class DockExtension extends Extension {
    enable() {
        this._scheme = new SchemeStyle(this); // the user's colour scheme, if one is applied
        this._settings = this.getSettings();
        this._signals = new Signals();
        this._shown = false;
        this._hideId = 0;

        this._dash = new Dash.Dash();
        this._dash._appSystem = filteredAppSystem(Shell.AppSystem.get_default(),
            this._settings.get_strv('hidden-app-prefixes'));
        this._launcher = new Map(); // app id -> LauncherEntry state
        this._previews = new WindowPreviews();
        // The pointer left the dock by way of the previews: hide now, as leaving the dock would.
        this._previews.onHidden = () => this._onHover();
        // Which apps are playing sound (their media players say so): a speaker on their icon.
        this._players = new Players(() => this._queueRefresh());
        this._previewId = 0;
        // Every icon the dash makes gets our clicks, scroll, indicators, badges and previews.
        const dash = this._dash;
        const createAppItem = Dash.Dash.prototype._createAppItem;
        dash._createAppItem = app => {
            const item = createAppItem.call(dash, app);
            this._decorate(item.child);
            if (HELP_IDS.includes(app.get_id()))
                useOwnIcon(item.child.icon, 'ostrich-help');
            return item;
        };
        useOwnIcon(dash._showAppsIcon.icon, 'ostrich-apps');
        this._fixIconSize();

        // The dock container. Reactive + track_hover so leaving it can start the hide delay.
        this._box = new St.Bin({
            name: 'ost-dock',
            style_class: 'ost-dock',
            accessible_name: 'Dock',
            style: `padding-bottom: ${this._settings.get_uint('edge-gap')}px;`,
            reactive: true,
            track_hover: true,
            child: this._dash,
        });
        Main.layoutManager.addChrome(this._box, {affectsStruts: false, trackFullscreen: true});

        // "Show Apps" in the dock opens the app grid, like the overview's dash.
        this._signals.connect(this._dash.showAppsButton, 'notify::checked', () => {
            if (!this._dash.showAppsButton.checked)
                return;
            this._dash.showAppsButton.checked = false;
            // GNOME's own dash button (hidden, still wired into the overview) says which page shows.
            // Closed: the app grid. In the app grid: the overview closes, back to the window the user
            // was in (GNOME's dash only went to the window picker, since it couldn't be pressed with
            // the overview closed). In the window picker, after Super: on to the app grid; showApps()
            // does nothing there, the overview is already open (owner, 2026-11-20).
            const grid = Main.overview.dash?.showAppsButton;
            const action = showAppsAction({
                target: Main.overview.visibleTarget,
                animating: Main.overview.animationInProgress,
                appGrid: !!grid?.checked,
            });
            if (action === 'show')
                Main.overview.showApps();
            else if (action === 'hide')
                Main.overview.hide();
            else if (action === 'grid' && grid)
                grid.checked = true;
        });

        this._signals.connect(this._box, 'notify::hover', () => this._onHover());
        // Placed just before the next frame, not inside the layout pass that changed its size.
        this._placeLater = new BeforeRedraw(() => this._place());
        this._signals.connect(this._box, 'notify::allocation', () => this._placeLater.queue());
        this._signals.connect(Main.layoutManager, 'monitors-changed', () => this._rebuildBarrier());
        // One dock everywhere (owner, 2026-11-18): ours stays in the overview, and GNOME's own dash
        // there (up to 64 px icons on solid grey) is hidden, keeping our dock's height free for it.
        this._overviewDash = Main.overview.dash;
        this._overviewDash?.hide();
        // Hidden, its icons never get styled, and the overview's setMaxSize then threw in
        // _adjustIconSize (firstIcon.icon is null): it only needs its fixed height, set in _place.
        if (this._overviewDash)
            this._overviewDash.setMaxSize = () => {};
        this._signals.connect(Main.overview, 'showing', () => this._show());
        this._signals.connect(Main.overview, 'hidden', () => this._sync());

        const style = Gio.Settings.new('org.gnome.desktop.interface');
        this._signals.connect(style, 'changed::color-scheme', () => this._applyStyle());
        for (const key of ['background', 'background-color', 'background-opacity'])
            this._signals.connect(this._settings, `changed::${key}`, () => this._applyStyle());
        this._signals.connect(this._settings, 'changed::icon-size', () => this._fixIconSize());
        this._signals.connect(this._box, 'style-changed', () => this._applyStyle());
        for (const key of ['autohide', 'intellihide'])
            this._signals.connect(this._settings, `changed::${key}`, () => this._sync());
        this._signals.connect(this._settings, 'changed::pressure-threshold', () => this._rebuildBarrier());
        this._signals.connect(this._settings, 'changed::monitor', () => this._rebuildBarrier());
        this._signals.connect(this._settings, 'changed::edge-gap', () => {
            this._box.style = `padding-bottom: ${this._settings.get_uint('edge-gap')}px;`;
        });
        for (const key of ['indicator', 'badges'])
            this._signals.connect(this._settings, `changed::${key}`, () => this._refreshIcons());
        this._signals.connect(this._settings, 'changed::show-apps-at-start', () => this._placeShowApps());
        // Windows opening and closing, apps starting and stopping, focus: one refresh for every icon
        // (per-icon signals on the apps kept old docks alive across disable/enable).
        this._refreshId = 0;
        const refresh = () => this._queueRefresh();
        this._signals.connect(global.display, 'notify::focus-window', refresh);
        this._signals.connect(Shell.AppSystem.get_default(), 'app-state-changed', refresh);
        this._signals.connect(Shell.WindowTracker.get_default(), 'tracked-windows-changed', refresh);
        this._signals.connect(global.workspace_manager, 'active-workspace-changed', refresh);
        this._placeShowApps();
        this._launcherId = Gio.DBus.session.signal_subscribe(null, LAUNCHER_IFACE, 'Update', null, null,
            Gio.DBusSignalFlags.NONE, (_c, _sender, _path, _iface, _signal, params) => this._onLauncherUpdate(params));
        this._interfaceSettings = style;

        this._watchWindows();
        this._applyStyle();
        this._rebuildBarrier();
        if (this._settings.get_boolean('autohide'))
            this._hide(true); // start hidden; the first push on the edge shows it
        this._sync();
    }

    disable() {
        this._scheme.destroy();
        this._scheme = null;
        if (this._refreshId) {
            GLib.source_remove(this._refreshId);
            this._refreshId = 0;
        }
        this._clearHideTimer();
        this._cancelPreview();
        this._previews.hide(true);
        this._placeLater?.cancel();
        this._players.destroy();
        this._players = null;
        Gio.DBus.session.signal_unsubscribe(this._launcherId);
        this._signals.disconnectAll();
        this._destroyBarrier();
        // Dash registers itself with Ctrl+Alt+Tab and doesn't unregister on destroy.
        Main.ctrlAltTabManager.removeGroup(this._dash);
        if (this._overviewDash)
            delete this._overviewDash.setMaxSize; // back to the class's own
        this._overviewDash?.set_height(-1);
        this._overviewDash?.show();
        this._overviewDash = null;
        Main.layoutManager.removeChrome(this._box);
        this._box.destroy();
        this._box = this._dash = this._settings = this._interfaceSettings = null;
    }

    // ---- size and style ----

    // Dash only chooses between fixed sizes; use the configured one on this instance.
    _fixIconSize() {
        const size = this._settings.get_uint('icon-size');
        const dash = this._dash;
        dash._adjustIconSize = function () {
            if (this.iconSize === size)
                return;
            this.iconSize = size;
            this.emit('icon-size-changed');
            for (const c of this._box.get_children())
                c.child?._delegate?.icon?.setIconSize(size);
            this._showAppsIcon.icon.setIconSize(size);
        };
        dash._adjustIconSize();
        dash._queueRedisplay();
    }

    _applyStyle() {
        // With the blur extension behind it (it tags us 'ost-blurred'), a lighter tint lets the blur
        // show; without it, the solid opacity setting applies.
        const blurred = this._box.has_style_class_name('ost-blurred');
        const opacity = this._settings.get_double('background-opacity') * (blurred ? 0.3 : 1);
        const dark = this._interfaceSettings.get_string('color-scheme') === 'prefer-dark';
        // 'palette': the palette tool's accent; 'custom': background-color. Black or white otherwise,
        // or while that colour isn't there or isn't #rrggbb.
        const background = this._settings.get_string('background');
        const rgb = (background === 'palette' && hexRgb(readPalette()?.accent)) ||
            (background === 'custom' && hexRgb(this._settings.get_string('background-color'))) ||
            (dark ? '0, 0, 0' : '255, 255, 255');
        this._dash._background.set_style(
            `background-color: rgba(${rgb}, ${opacity}); border-radius: 18px; border: none;`);
    }

    _monitor() {
        const i = this._settings.get_int('monitor');
        return Main.layoutManager.monitors[i] ?? Main.layoutManager.primaryMonitor;
    }

    _placeShowApps() {
        const container = this._dash._dashContainer;
        const icon = this._dash._showAppsIcon;
        container.set_child_at_index(icon, this._settings.get_boolean('show-apps-at-start') ? 0 : -1);
    }

    // ---- icons: clicks, scroll, indicators, badges, previews ----

    // The app's normal windows on this workspace, in a stable order.
    _appWindows(app) {
        const ws = global.workspace_manager.get_active_workspace();
        return app.get_windows()
            .filter(w => w.get_workspace() === ws && !w.skip_taskbar && w.get_window_type() === Meta.WindowType.NORMAL)
            .sort((a, b) => a.get_stable_sequence() - b.get_stable_sequence());
    }

    _decorate(icon) {
        if (!icon?.app || icon._ostDecorated)
            return;
        icon._ostDecorated = true;
        const app = icon.app;
        const activate = icon.activate.bind(icon);
        icon.activate = button => {
            this._cancelPreview();
            this._previews.hide();
            const event = Clutter.get_current_event();
            const ctrl = event && (event.get_state() & Clutter.ModifierType.CONTROL_MASK) !== 0;
            if (button === Clutter.BUTTON_MIDDLE || ctrl) {
                activate(button); // GNOME's own: a new window
                return;
            }
            const windows = this._appWindows(app);
            const focused = Shell.WindowTracker.get_default().focus_app === app;
            const action = clickAction({running: app.state !== Shell.AppState.STOPPED, focused, windows: windows.length},
                this._settings.get_string('click-action'));
            if (action === 'minimize') {
                windows.forEach(w => w.minimize());
            } else if (action === 'cycle') {
                const next = nextWindow(windows, global.display.focus_window);
                if (next)
                    Main.activateWindow(next);
            } else {
                if (app.state === Shell.AppState.STOPPED)
                    this._bounce(icon); // starting: one bounce, so the click shows it was heard
                activate(button);
            }
        };
        // Scroll over a running app's icon: through its windows.
        icon.connect('scroll-event', (_a, event) => {
            const dir = event.get_scroll_direction();
            const step = dir === Clutter.ScrollDirection.UP || dir === Clutter.ScrollDirection.LEFT ? -1
                : dir === Clutter.ScrollDirection.DOWN || dir === Clutter.ScrollDirection.RIGHT ? 1 : 0;
            const windows = this._appWindows(app);
            if (step === 0 || windows.length === 0)
                return Clutter.EVENT_PROPAGATE;
            const next = nextWindow(windows, global.display.focus_window, step);
            if (next)
                Main.activateWindow(next);
            return Clutter.EVENT_STOP;
        });
        // Our overlays, in the icon's own container (a bin layout).
        icon._ostDots = new St.BoxLayout({style_class: 'ost-dock-dots', x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.END, x_expand: true, y_expand: true});
        icon._ostBadge = new St.Label({style_class: 'ost-dock-badge', x_align: Clutter.ActorAlign.END, y_align: Clutter.ActorAlign.START, x_expand: true, y_expand: true, visible: false});
        icon._ostProgress = new St.Widget({style_class: 'ost-dock-progress', x_align: Clutter.ActorAlign.FILL, y_align: Clutter.ActorAlign.END, x_expand: true, y_expand: true, visible: false});
        icon._ostProgressBar = new St.Widget({style_class: 'ost-dock-progress-bar', x_align: Clutter.ActorAlign.START});
        icon._ostProgress.add_child(icon._ostProgressBar);
        // Playing sound: a speaker in the top-left corner; a click pauses it, again plays it.
        icon._ostPlaying = new St.Button({
            style_class: 'ost-dock-playing', visible: false, can_focus: true,
            x_align: Clutter.ActorAlign.START, y_align: Clutter.ActorAlign.START, x_expand: true, y_expand: true,
            child: new St.Icon({icon_name: 'audio-volume-high-symbolic'}),
            accessible_name: `${app.get_name()} is playing: pause`,
        });
        icon._ostPlaying.connect('clicked', () => this._playerFor(app)?.proxy.PlayPauseRemote());
        for (const a of [icon._ostDots, icon._ostProgress, icon._ostBadge, icon._ostPlaying])
            icon._iconContainer.add_child(a);
        icon.connect('notify::hover', () => {
            // A small lift under the pointer (the icon's picture only; the layout doesn't move).
            if (!icon._ostBouncing)
                animate(icon._iconContainer, {translation_y: icon.hover ? -4 : 0}, {duration: QUICK});
            this._onIconHover(icon);
        });
        this._updateIcon(icon);
    }

    _bounce(icon) {
        const c = icon._iconContainer;
        icon._ostBouncing = true;
        animate(c, {translation_y: -12}, {
            duration: STANDARD,
            onDone: () => animate(c, {translation_y: icon.hover ? -4 : 0}, {
                duration: STANDARD, mode: Clutter.AnimationMode.EASE_OUT_BOUNCE,
                onDone: () => (icon._ostBouncing = false),
            }),
        });
    }

    _icons() {
        return this._dash._box.get_children().map(c => c.child).filter(c => c?._ostDecorated);
    }

    // At most once per frame, however many signals came.
    _queueRefresh() {
        if (this._refreshId)
            return;
        this._refreshId = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            this._refreshId = 0;
            this._refreshIcons();
            return GLib.SOURCE_REMOVE;
        });
    }

    _refreshIcons() {
        for (const icon of this._icons())
            this._updateIcon(icon);
    }

    // The playing player of `app` (by its DesktopEntry), for the speaker's click.
    _playerFor(app) {
        const id = app.get_id().replace(/\.desktop$/, '');
        return this._players?.list().find(p => p.status === 'Playing' && p.desktopEntry.replace(/\.desktop$/, '') === id) ?? null;
    }

    _updateIcon(icon) {
        const app = icon.app;
        // Indicators.
        const style = this._settings.get_string('indicator');
        const running = app.state !== Shell.AppState.STOPPED;
        const n = style === 'dots' && running ? dotCount(Math.max(1, this._appWindows(app).length)) : 0;
        icon._dot.visible = style === 'dot' && running;
        if (icon._ostDots.get_n_children() !== n) {
            icon._ostDots.destroy_all_children();
            for (let i = 0; i < n; i++)
                icon._ostDots.add_child(new St.Widget({style_class: 'ost-dock-dot'}));
        }
        const focused = Shell.WindowTracker.get_default().focus_app === app;
        for (const d of icon._ostDots.get_children()) {
            if (focused)
                d.add_style_class_name('ost-focused');
            else
                d.remove_style_class_name('ost-focused');
        }
        icon._ostPlaying.visible = playingApps(this._players?.list() ?? []).has(app.get_id());
        // Badges and progress.
        const entry = this._settings.get_boolean('badges') ? this._launcher.get(app.get_id()) : null;
        const text = countText(entry);
        icon._ostBadge.text = text;
        icon._ostBadge.visible = text !== '';
        icon._ostProgress.visible = !!entry?.progressVisible;
        if (entry?.progressVisible) {
            const w = Math.max(0, icon._ostProgress.width - 12);
            icon._ostProgressBar.width = Math.round(w * entry.progress);
        }
    }

    _onLauncherUpdate(params) {
        const [uri, props] = params.recursiveUnpack();
        const id = appIdFromUri(uri);
        if (!id)
            return;
        this._launcher.set(id, mergeLauncherEntry(this._launcher.get(id), props));
        const icon = this._icons().find(i => i.app.get_id() === id);
        if (icon)
            this._updateIcon(icon);
    }

    // Hovering an icon for a moment shows its windows; leaving hides them (unless onto them).
    _onIconHover(icon) {
        this._cancelPreview();
        if (!icon.hover) {
            this._previews.iconLeft();
            return;
        }
        if (!this._settings.get_boolean('previews') || this._appWindows(icon.app).length === 0)
            return;
        // From one icon's preview straight to the next one's (it glides across): no wait.
        this._previewId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, this._previews.visible ? 0 : PREVIEW_DELAY, () => {
            this._previewId = 0;
            if (icon.hover && this._box?.visible)
                this._previews.show(icon, this._appWindows(icon.app));
            return GLib.SOURCE_REMOVE;
        });
    }

    _cancelPreview() {
        if (this._previewId) {
            GLib.source_remove(this._previewId);
            this._previewId = 0;
        }
    }

    // Centred on the bottom edge of the primary monitor (hidden = moved down by its own height).
    _place() {
        const m = this._monitor();
        if (!m || !this._box)
            return;
        const [w, h] = this._box.get_size();
        const x = Math.round(m.x + (m.width - w) / 2), y = m.y + m.height - h;
        // Only move when needed: this runs on allocation changes, which moving itself triggers.
        if (this._box.x !== x || this._box.y !== y)
            this._box.set_position(x, y);
        this._dash.setMaxSize(Math.round(m.width * 0.9), h);
        if (this._overviewDash && this._overviewDash.height !== h)
            this._overviewDash.set_height(h); // the overview lays its windows out above our dock
    }

    // ---- show / hide ----

    _hiddenOffset() {
        return this._box.height + 2;
    }

    _show() {
        this._clearHideTimer();
        // Check the actor too: something else (focus mode) may have hidden it while we thought it shown.
        if (this._shown && this._box.visible)
            return;
        this._shown = true;
        this._box.visible = true;
        animate(this._box, {translation_y: 0}, {duration: STANDARD});
    }

    _hide(immediate = false) {
        this._clearHideTimer();
        if (!this._shown && !immediate)
            return;
        this._shown = false;
        const done = () => {
            // Unmapped while hidden: nothing of the dock is painted or picked.
            this._box.visible = false;
        };
        if (immediate) {
            stop(this._box);
            this._box.translation_y = this._hiddenOffset();
            done();
            return;
        }
        animate(this._box, {translation_y: this._hiddenOffset()}, {
            duration: SLOW,
            mode: Clutter.AnimationMode.EASE_IN_QUAD,
            onDone: finished => finished && done(),
        });
    }

    _clearHideTimer() {
        if (this._hideId) {
            GLib.source_remove(this._hideId);
            this._hideId = 0;
        }
    }

    _onHover() {
        if (this._box.hover || this._previews.visible) {
            this._clearHideTimer();
            return;
        }
        if (!this._settings.get_boolean('autohide') || this._dash._dragPlaceholder)
            return;
        // One-shot, and only ever while the dock is visible.
        this._clearHideTimer();
        this._hideId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, this._settings.get_uint('hide-delay'), () => {
            this._hideId = 0;
            this._sync();
            return GLib.SOURCE_REMOVE;
        });
    }

    // Decides visibility from the settings, the overview, the pointer and (intellihide) windows.
    _sync() {
        if (!this._box)
            return;
        if (Main.overview.visible || !this._settings.get_boolean('autohide')) {
            this._show();
            return;
        }
        if (this._box.hover)
            return;
        if (this._settings.get_boolean('intellihide') && !this._windowOverlaps())
            this._show();
        else
            this._hide();
    }

    // ---- bottom-edge pressure barrier ----

    _rebuildBarrier() {
        this._destroyBarrier();
        const m = this._monitor();
        if (!m)
            return;
        this._pressure = new Layout.PressureBarrier(this._settings.get_uint('pressure-threshold'),
            PRESSURE_TIMEOUT, Shell.ActionMode.NORMAL);
        this._pressureId = this._pressure.connect('trigger', () => this._show());
        // A horizontal barrier along the bottom edge that lets the pointer move up (NEGATIVE_Y)
        // but stops it going further down, so pushing down builds pressure.
        this._barrier = new Meta.Barrier({
            backend: global.backend,
            x1: m.x, x2: m.x + m.width,
            y1: m.y + m.height, y2: m.y + m.height,
            directions: Meta.BarrierDirection.NEGATIVE_Y,
        });
        this._pressure.addBarrier(this._barrier);
        this._place();
    }

    _destroyBarrier() {
        if (this._pressure) {
            this._pressure.disconnect(this._pressureId);
            this._pressure.destroy(); // only disconnects from the barriers...
            this._pressure = null;
        }
        this._barrier?.destroy(); // ...so the barrier itself is destroyed here
        this._barrier = null;
    }

    // ---- intellihide ----

    _watchWindows() {
        const resync = () => this._sync();
        // Shell.WM's size-changed covers every window, so no per-window connections pile up.
        this._signals.connect(global.window_manager, 'size-changed', () => {
            if (this._settings.get_boolean('intellihide'))
                resync();
        });
        this._signals.connect(global.display, 'restacked', resync);
        this._signals.connect(global.display, 'grab-op-end', resync);
        this._signals.connect(global.workspace_manager, 'active-workspace-changed', resync);
    }

    _windowOverlaps() {
        const m = this._monitor();
        const [w, h] = this._box.get_size();
        const dock = {x: m.x + (m.width - w) / 2, y: m.y + m.height - h, w, h};
        const ws = global.workspace_manager.get_active_workspace();
        return ws.list_windows().some(win => {
            if (win.minimized || !win.showing_on_its_workspace() || win.get_monitor() !== m.index)
                return false;
            if (win.get_window_type() !== Meta.WindowType.NORMAL)
                return false;
            const r = win.get_frame_rect();
            return r.x < dock.x + dock.w && r.x + r.width > dock.x && r.y < dock.y + dock.h && r.y + r.height > dock.y;
        });
    }
}
