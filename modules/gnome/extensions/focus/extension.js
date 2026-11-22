// SPDX-License-Identifier: GPL-2.0-or-later
// Focus & environments.
//
// Focus: one toggle turns on Do Not Disturb, mutes and hides the web-app drawer, and hides our
// dock, tray, monitor and workspace bar. With an allow-list (setting `allowed-apps`, or an
// environment's own list) it also hides every other app: their windows are minimised and stay
// minimised, and the app grid and search show only the allowed apps. Turning focus off brings
// everything back exactly as it was.
//
// Environments (envmanager.js): saved desktops (apps and their window places) opened on a fresh
// workspace with one click, from the same quick-settings menu or `ostrich env`.
//
// The other extensions don't need to know about focus mode: it finds their actors by name
// (top-bar roles and the dock actor) and keeps them hidden while it's on, including items that
// appear meanwhile. Only what focus itself hid is shown again. The clock and quick settings stay,
// so focus can always be turned off. The banner setting from before is saved, so a shell restart
// in the middle of focus mode can't leave Do Not Disturb stuck on.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as ParentalControlsManager from 'resource:///org/gnome/shell/misc/parentalControlsManager.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {Patches, shellField} from './_lib/patches.js';
import {Signals} from './_lib/signals.js';
import {EnvironmentManager} from './envmanager.js';
import {isAllowed} from './environments.js';

const OURS = '@ostrich-os';
// Top-bar roles hidden in focus mode: monitor, workspaces, every tray item and drawer icon.
const HIDDEN_ROLE_PREFIXES = [`monitor${OURS}`, `workspaces${OURS}`, `tray${OURS}-`, `drawer${OURS}-`];
const DOCK_ACTOR = 'ost-dock';
const DRAWER_APP = 'ostrich_os.drawer';
const DRAWER_PATH = '/ostrich_os/drawer'; // GApplication turns '-' into '_'

// Mutes the drawer's notifications through its app.mute action. Never starts the drawer.
function muteDrawer(on) {
    Gio.DBus.session.call(DRAWER_APP, DRAWER_PATH, 'org.gtk.Actions', 'Activate',
        new GLib.Variant('(sava{sv})', ['mute', [GLib.Variant.new_boolean(on)], {}]),
        null, Gio.DBusCallFlags.NO_AUTO_START, -1, null, (bus, res) => {
            try {
                bus.call_finish(res);
            } catch {
                // the drawer isn't running: nothing to mute
            }
        });
}

function drawerWindows() {
    return global.display.list_all_windows().filter(w =>
        w.get_gtk_application_id?.() === DRAWER_APP || w.get_wm_class?.() === DRAWER_APP);
}

function appIdOf(win) {
    return Shell.WindowTracker.get_default().get_window_app(win)?.get_id() ?? '';
}

// Focus quiets the whole desktop; saved workspaces are their own tile (owner, 2026-11-02, note
// 014340: they are two different things).
const FocusToggle = GObject.registerClass(
class FocusToggle extends QuickSettings.QuickToggle {
    _init() {
        super._init({title: 'Focus', iconName: 'weather-clear-night-symbolic', toggleMode: true});
        this.accessible_name = 'Focus'; // GNOME 50's tiles don't name themselves for screen readers
    }
});

// Saved workspaces: the tile opens its list (open or close each, save this one); lit while one is open.
const WorkspacesToggle = GObject.registerClass(
class WorkspacesToggle extends QuickSettings.QuickMenuToggle {
    _init() {
        super._init({title: 'Workspaces', iconName: 'view-grid-symbolic', toggleMode: false});
        this.accessible_name = 'Saved workspaces';
        const inner = this._box?.get_first_child();
        if (inner)
            inner.accessible_name = 'Saved workspaces';
        if (this._menuButton)
            this._menuButton.accessible_name = 'Saved workspaces list';
        this.menu.setHeader('view-grid-symbolic', 'Saved workspaces');
        this.envSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this.envSection);
        this.connect('clicked', () => this.menu.open());
    }
});

const FocusIndicator = GObject.registerClass(
class FocusIndicator extends QuickSettings.SystemIndicator {
    _init() {
        super._init();
        this.toggle = new FocusToggle();
        this.workspaces = new WorkspacesToggle();
        this.quickSettingsItems.push(this.toggle, this.workspaces);
    }
});

export default class FocusExtension extends Extension {
    enable() {
        this._settings = this.getSettings();
        this._notifications = new Gio.Settings({schema_id: 'org.gnome.desktop.notifications'});
        this._signals = new Signals();
        this._hideSignals = new Signals();
        this._allowSignals = new Signals();
        this._patches = new Patches();
        this._hidden = new Map(); // actor → was it visible before focus
        this._drawerShown = []; // drawer windows focus minimized
        this._minimized = new Set(); // windows the allow-list minimized
        this._dashHidden = new Set(); // overview dash items the allow-list hid
        this._allowed = []; // the allow-list in force (empty: none)
        this._active = false;

        // A restart while focus was on: put the banner setting back.
        const saved = this._settings.get_string('saved-show-banners');
        if (saved !== '') {
            this._notifications.set_boolean('show-banners', saved === 'true');
            this._settings.set_string('saved-show-banners', '');
        }

        this._indicator = new FocusIndicator();
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
        // One state, in focus-on: the tile, the clock menu's switch and `ostrich config` all set it.
        this._settings.set_boolean('focus-on', false);
        this._indicator.toggle.subtitle = 'Off';
        this._signals.connect(this._indicator.toggle, 'notify::checked', () => {
            this._set(this._indicator.toggle.checked);
            this._indicator.toggle.subtitle = this._active ? 'On' : 'Off'; // state in words, not only colour
            this._settings.set_boolean('focus-on', this._active);
        });
        this._signals.connect(this._settings, 'changed::focus-on', () => {
            this._indicator.toggle.checked = this._settings.get_boolean('focus-on');
        });
        // Focus stays on through a screen lock (session-modes in metadata.json), but isn't toggled
        // from the lock screen.
        const lockShown = () => {
            this._indicator.toggle.visible = !Main.sessionMode.isLocked;
            this._indicator.workspaces.visible = !Main.sessionMode.isLocked;
        };
        this._signals.connect(Main.sessionMode, 'updated', lockShown);
        lockShown();
        this._signals.connect(this._indicator.workspaces.menu, 'open-state-changed', (_m, open) => {
            if (open)
                this._fillMenu();
        });

        this._envs = new EnvironmentManager({
            setFocus: (on, allowed) => this.setFocus(on, allowed),
            isOn: () => this._active,
            // Saving and opening a workspace includes what is inside its apps (the setting).
            restoreContents: () => this._settings.get_boolean('restore-app-contents'),
            // The Workspaces tile is lit while a saved workspace is open, and is named after it
            // (owner, 2026-11-06).
            changed: () => this._syncWorkspacesTile(),
        });

        Main.wm.addKeybinding('toggle-focus', this._settings, Meta.KeyBindingFlags.NONE,
            Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW,
            () => {
                this._indicator.toggle.checked = !this._indicator.toggle.checked;
            });
    }

    _syncWorkspacesTile() {
        const tile = this._indicator?.workspaces;
        if (!tile || !this._envs)
            return;
        let open = [];
        try {
            open = JSON.parse(this._envs.List()).filter(e => e.open).map(e => e.name);
        } catch (e) {
            console.warn(`focus: reading the open workspaces: ${e.message}`);
        }
        tile.checked = this._envs.anyOpen();
        tile.title = open.length === 0 ? 'Workspaces' : open.length === 1 ? open[0] : `${open.length} workspaces`;
        tile.accessible_name = open.length === 0 ? 'Saved workspaces' : `Saved workspaces: ${tile.title}`;
        tile.subtitle = open.length === 0 ? 'None open' : `${open.length} open`; // state in words, as Focus does
    }

    disable() {
        this._set(false);
        this._settings.set_boolean('focus-on', false);
        Main.wm.removeKeybinding('toggle-focus');
        this._envs.destroy();
        this._envs = null;
        this._signals.disconnectAll();
        this._indicator.quickSettingsItems.forEach(i => i.destroy());
        this._indicator.destroy();
        this._indicator = this._settings = this._notifications = null;
    }

    /** Focus on or off; `allowed` replaces the saved allow-list (an environment's own). */
    setFocus(on, allowed = null) {
        this._override = on ? allowed : null;
        if (on && this._active) {
            // Already on: switch to the new allow-list.
            this._clearAllowList();
            this._applyAllowList();
        }
        this._indicator.toggle.checked = on; // notify::checked calls _set
    }

    // ---- the quick-settings menu: environments ----

    _fillMenu() {
        const section = this._indicator.workspaces.envSection;
        section.removeAll();
        let envs;
        try {
            envs = JSON.parse(this._envs.List());
        } catch {
            envs = [];
        }
        for (const env of envs) {
            const label = env.open ? `Close ${env.name}` : `Open ${env.name}`;
            section.addAction(label, () => {
                try {
                    if (env.open)
                        this._envs.Close(env.id);
                    else
                        this._envs.Open(env.id);
                } catch (e) {
                    Main.notifyError('Saved workspaces', e.message);
                }
            });
        }
        if (envs.length === 0)
            section.addMenuItem(new PopupMenu.PopupMenuItem('No saved workspaces yet', {reactive: false}));
        section.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        section.addAction('Save this workspace', () => {
            const name = `Desktop ${new Date().toLocaleString([], {month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'})}`;
            try {
                this._envs.Save(name);
                Main.notify('Workspace saved', `“${name}”: rename it or add focus and power settings in Ostrich Settings or with \`ostrich workspace\`.`);
            } catch (e) {
                Main.notifyError('Environments', e.message);
            }
        });
    }

    // ---- focus ----

    _set(on) {
        if (on === this._active)
            return;
        this._active = on;
        if (on) {
            this._settings.set_string('saved-show-banners', `${this._notifications.get_boolean('show-banners')}`);
            this._notifications.set_boolean('show-banners', false);
            this._hideAll();
            muteDrawer(true);
            this._drawerShown = drawerWindows().filter(w => !w.minimized);
            this._drawerShown.forEach(w => w.minimize());
            // Keep things hidden: new tray items, or a component re-showing itself (the dock does).
            for (const box of ['_leftBox', '_centerBox', '_rightBox'].map(b => shellField(Main.panel, b, 'focus')).filter(Boolean))
                this._hideSignals.connect(box, 'child-added', () => this._hideAll());
            this._hideSignals.connect(Main.layoutManager.uiGroup, 'child-added', () => this._hideAll());
            this._applyAllowList();
        } else {
            this._clearAllowList();
            this._override = null;
            this._hideSignals.disconnectAll();
            for (const [actor, wasVisible] of this._hidden)
                actor.visible = wasVisible;
            this._hidden.clear();
            muteDrawer(false);
            // Only windows that still exist (the drawer may have quit meanwhile).
            drawerWindows().filter(w => this._drawerShown.includes(w)).forEach(w => w.unminimize());
            this._drawerShown = [];
            const saved = this._settings.get_string('saved-show-banners');
            if (saved !== '')
                this._notifications.set_boolean('show-banners', saved === 'true');
            this._settings.set_string('saved-show-banners', '');
        }
    }

    // ---- focus with an allow-list ----

    _applyAllowList() {
        this._allowed = this._override ?? this._settings.get_strv('allowed-apps');
        if (this._allowed.length === 0)
            return;
        // The app grid and search both ask GNOME's parental controls whether to show an app.
        const pcm = ParentalControlsManager.getDefault();
        const allowed = this._allowed;
        this._patches.replace(pcm, 'shouldShowApp', orig => function (appInfo) {
            return orig.call(this, appInfo) && isAllowed(allowed, appInfo.get_id());
        });
        // GNOME 50 destroys an app folder the filter leaves empty, then asks the grid to remove it,
        // which throws ("not part of the IconGrid") and stops the grid redrawing. Skip the grid
        // for an item it no longer holds.
        const appDisplay = Main.overview._overview?.controls?.appDisplay;
        if (appDisplay?._removeItem) {
            // Folders GNOME destroys as they empty: asking the grid about one ("contains") touched a
            // disposed object and logged a warning, so they're remembered as they go.
            const gone = new WeakSet();
            for (const item of appDisplay._orderedItems ?? [])
                this._allowSignals.connect(item, 'destroy', () => gone.add(item));
            this._patches.replace(appDisplay, '_removeItem', orig => function (item) {
                if (!gone.has(item) && this._grid.contains(item)) {
                    orig.call(this, item);
                    return;
                }
                const i = this._orderedItems.indexOf(item);
                if (i >= 0)
                    this._orderedItems.splice(i, 1);
                this._items.delete(item.id);
            });
        }
        pcm.emit('app-filter-changed');

        // The overview's dash lists favourites and running apps itself: hide the others there.
        const dash = Main.overview.dash;
        if (dash?._redisplay) {
            const hidden = this._dashHidden;
            const hideOthers = () => {
                for (const item of dash._box.get_children()) {
                    const app = item.child?._delegate?.app;
                    if (app && item.visible && !isAllowed(allowed, app.get_id())) {
                        item.hide();
                        hidden.add(item);
                        this._allowSignals.connect(item, 'destroy', () => hidden.delete(item));
                    }
                }
            };
            this._patches.replace(dash, '_redisplay', orig => function () {
                orig.call(this);
                hideOthers();
            });
            hideOthers();
        }

        for (const w of global.display.list_all_windows())
            this._keepAway(w);
        this._allowSignals.connect(global.display, 'window-created', (_d, win) => {
            const id = win.connect('shown', () => {
                win.disconnect(id);
                if (this._allowed.length > 0 && this._keepAway(win))
                    Main.notify('Not in this focus', 'Turn focus off to use it.');
            });
        });
    }

    /** Minimises a window of an app that isn't allowed; true if it did. */
    _keepAway(win) {
        if (win.get_window_type() !== Meta.WindowType.NORMAL || win.minimized)
            return false;
        const app = appIdOf(win);
        if (app === '' || app.startsWith(DRAWER_APP) || isAllowed(this._allowed, app))
            return false;
        win.minimize();
        this._minimized.add(win);
        this._allowSignals.connect(win, 'notify::minimized', () => {
            if (this._active && this._allowed.length > 0 && !win.minimized && !isAllowed(this._allowed, appIdOf(win)))
                win.minimize();
        });
        this._allowSignals.connect(win, 'unmanaged', () => this._minimized.delete(win));
        return true;
    }

    _clearAllowList() {
        this._allowSignals.disconnectAll();
        const hadList = this._allowed.length > 0;
        this._patches.restoreAll();
        if (hadList)
            ParentalControlsManager.getDefault().emit('app-filter-changed');
        for (const item of this._dashHidden)
            item.show();
        this._dashHidden.clear();
        for (const w of this._minimized)
            w.unminimize();
        this._minimized.clear();
        this._allowed = [];
    }

    _targets() {
        const actors = [];
        for (const [role, indicator] of Object.entries(Main.panel.statusArea)) {
            if (HIDDEN_ROLE_PREFIXES.some(p => role.startsWith(p)) && indicator?.container)
                actors.push(indicator.container);
        }
        const dock = Main.layoutManager.uiGroup.get_children().find(a => a.name === DOCK_ACTOR);
        if (dock)
            actors.push(dock);
        return actors;
    }

    _hideAll() {
        for (const actor of this._targets()) {
            if (this._hidden.has(actor))
                continue;
            this._hidden.set(actor, actor.visible);
            actor.hide();
            this._hideSignals.connect(actor, 'notify::visible', () => {
                if (this._active && actor.visible)
                    actor.hide();
            });
            this._hideSignals.connect(actor, 'destroy', () => this._hidden.delete(actor));
        }
    }
}
