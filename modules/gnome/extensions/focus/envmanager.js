// SPDX-License-Identifier: GPL-2.0-or-later
// focus/envmanager.js: saved workspaces in the shell (called "environments" in the code, the files
// and the D-Bus API; the owner renamed them Workspaces on 2026-11-01). The file format and matching
// rules are in environments.js; this file talks to GNOME.
//
//   Save    the windows on the current workspace: their apps, monitors and places, what is inside
//           them (the folder in Files and in terminals, the pages in a Firefox family browser:
//           appstate-live.js), and Ostrich Drawer's top-bar sites
//   Open    a fresh workspace named after it, the apps launched there (with their folders and pages),
//           each window put back in its saved place, then the extras (power mode, focus with an allow-list, Do Not Disturb,
//           drawer sites)
//   Close   saves where you left off (the windows on that workspace now), closes them, removes the
//           workspace and its name, puts back the normal drawer sites, and goes back to where you were
//
// Driven from quick settings and over D-Bus (org.ubuntuostrich.Environments) by `ostrich env`.
// Nothing runs while no environment is opening: window signals are connected only for that, and
// for at most 60 s.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {Signals} from './_lib/signals.js';
import {PROFILES_BUSES} from './_lib/timers.js';
import {captureState, launchWithState} from './appstate-live.js';
import {idFor, capture, validate, placementQueue, takePlace, allPlaced, drawerSet, withLayout, namedAt, withoutIndex} from './environments.js';

const BUS_NAME = 'org.ubuntuostrich.Environments';
const OBJECT_PATH = '/org/ubuntuostrich/Environments';
const OPEN_TIMEOUT_S = 60;
const CLOSE_TIMEOUT_S = 30; // how long Close waits for apps to close before leaving the workspace
const WM_PREFS = 'org.gnome.desktop.wm.preferences';
const DRAWER_APP = 'ubuntu_ostrich.drawer';
const DRAWER_PATH = '/ubuntu_ostrich/drawer';

const IFACE = `<node><interface name="${BUS_NAME}">
  <method name="List"><arg type="s" direction="out" name="json"/></method>
  <method name="Save"><arg type="s" direction="in" name="name"/><arg type="s" direction="out" name="id"/></method>
  <method name="Open"><arg type="s" direction="in" name="id"/></method>
  <method name="Close"><arg type="s" direction="in" name="id"/></method>
  <method name="Delete"><arg type="s" direction="in" name="id"/></method>
  <method name="GetDrawer"><arg type="s" direction="in" name="id"/><arg type="s" direction="out" name="json"/></method>
  <method name="SetDrawer"><arg type="s" direction="in" name="id"/><arg type="s" direction="in" name="json"/></method>
  <method name="State"><arg type="s" direction="out" name="json"/></method>
</interface></node>`;

function envDir() {
    return GLib.build_filenamev([GLib.get_user_config_dir(), 'ubuntu-ostrich', 'environments']);
}

// Every caller's id goes through here; only an id idFor() would make can name a file.
function envFile(id) {
    if (!idFor(id) || idFor(id) !== id)
        throw new Error(`no environment ${id}`);
    return Gio.File.new_for_path(GLib.build_filenamev([envDir(), `${id}.json`]));
}

function readEnv(id) {
    const [, bytes] = envFile(id).load_contents(null);
    return validate(JSON.parse(new TextDecoder().decode(bytes)));
}

function writeEnv(id, env) {
    GLib.mkdir_with_parents(envDir(), 0o755);
    envFile(id).replace_contents(new TextEncoder().encode(JSON.stringify(env, null, 2)), null, false,
        Gio.FileCreateFlags.REPLACE_DESTINATION, null);
}

// Ostrich Drawer's actions (org.gtk.Actions); never starts the drawer.
function drawerAction(name, param) {
    Gio.DBus.session.call(DRAWER_APP, DRAWER_PATH, 'org.gtk.Actions', 'Activate',
        new GLib.Variant('(sava{sv})', [name, [param], {}]),
        null, Gio.DBusCallFlags.NO_AUTO_START, -1, null, (bus, res) => {
            try {
                bus.call_finish(res);
            } catch {
                // the drawer isn't running
            }
        });
}

/** The drawer's top-bar sites now, as a drawer set; null if the drawer isn't running. */
function currentDrawerSet() {
    try {
        const reply = Gio.DBus.session.call_sync(DRAWER_APP, DRAWER_PATH, 'org.gtk.Actions', 'Describe',
            new GLib.Variant('(s)', ['state']), null, Gio.DBusCallFlags.NO_AUTO_START, 1000, null);
        const [[, , [state]]] = reply.recursiveUnpack();
        const s = JSON.parse(state);
        return drawerSet({sites: s.bar, keep: s.sites.filter(x => x.keep).map(x => x.id)});
    } catch {
        return null;
    }
}

function normalWindows(workspace = null) {
    const tracker = Shell.WindowTracker.get_default();
    return global.display.list_all_windows().filter(w =>
        w.get_window_type() === Meta.WindowType.NORMAL && !w.is_skip_taskbar() &&
        (workspace === null || w.get_workspace() === workspace) &&
        (tracker.get_window_app(w)?.get_id() ?? '').endsWith('.desktop') &&
        // not our own windows (the drawer, Ostrich Settings)
        !tracker.get_window_app(w).get_id().startsWith('ubuntu-ostrich.'));
}

/** The windows as saved: where each is, and (unless switched off) what is inside it. */
function describeAll(wins, withContents) {
    const state = withContents ? captureState(wins) : new Map();
    return wins.map(w => ({...describe(w), ...state.get(w)}));
}

function describe(w) {
    const f = w.get_frame_rect();
    return {
        app: Shell.WindowTracker.get_default().get_window_app(w)?.get_id() ?? null,
        workspace: w.get_workspace()?.index() ?? -1,
        monitor: w.get_monitor(),
        x: f.x, y: f.y, width: f.width, height: f.height,
        maximized: w.is_maximized(),
        minimized: w.minimized, // for State; capture() doesn't save it
    };
}

export class EnvironmentManager {
    /**
     * @param {object} focus  {setFocus(on, allowed): void, isOn(): boolean, changed?(): void (one opened or closed)}
     */
    constructor(focus) {
        this._focus = focus;
        this._signals = new Signals();
        this._opening = null; // {queue, signals, timeoutId}
        this._open = new Map(); // id -> {workspace, previous, windows: Set, focusWasOn, banners}
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this);
        this._dbus.export(Gio.DBus.session, OBJECT_PATH);
        this._nameId = Gio.bus_own_name_on_connection(Gio.DBus.session, BUS_NAME,
            Gio.BusNameOwnerFlags.NONE, null, null);
    }

    destroy() {
        this._stopOpening();
        for (const record of this._open.values()) {
            if (record.removedId)
                global.workspace_manager.disconnect(record.removedId);
            if (record.emptyId)
                record.workspace.disconnect(record.emptyId);
        }
        for (const done of [...this._closing ?? []])
            done();
        this._open.clear(); // an idle queued by a closing app then finds nothing to close
        this._signals.disconnectAll();
        Gio.bus_unown_name(this._nameId);
        this._dbus.unexport();
        this._dbus = null;
    }

    // ---- D-Bus (and quick settings) ----

    List() {
        const out = [];
        let en;
        try {
            en = Gio.File.new_for_path(envDir()).enumerate_children('standard::name', 0, null);
        } catch {
            return '[]';
        }
        for (let info; (info = en.next_file(null));) {
            const n = info.get_name();
            if (!n.endsWith('.json'))
                continue;
            const id = n.slice(0, -5);
            try {
                const env = readEnv(id);
                out.push({id, name: env.name, apps: env.apps.length, open: this._open.has(id)});
            } catch (e) {
                console.warn(`environments: skipping ${n}: ${e.message}`);
            }
        }
        out.sort((a, b) => a.name.localeCompare(b.name));
        return JSON.stringify(out);
    }

    Save(name) {
        const id = idFor(name);
        if (!id)
            throw new Error('give the environment a name with letters or numbers');
        const ws = global.workspace_manager.get_active_workspace();
        const windows = describeAll(normalWindows(ws), this._focus.restoreContents?.() ?? true);
        if (windows.length === 0)
            throw new Error('there are no app windows on this workspace to save');
        writeEnv(id, capture(name, windows, {drawer: currentDrawerSet()}));
        return id;
    }

    Open(id) {
        const env = readEnv(id); // throws on a bad file: the caller sees the message
        if (this._open.has(id)) {
            this._open.get(id).workspace.activate(global.get_current_time());
            return;
        }
        this._stopOpening();
        const wm = global.workspace_manager;
        const previous = wm.get_active_workspace();
        // A fresh workspace: the empty one GNOME keeps at the end, or a new one.
        let ws = wm.get_workspace_by_index(wm.n_workspaces - 1);
        if (!ws || ws.list_windows().some(w => w.get_window_type() === Meta.WindowType.NORMAL))
            ws = wm.append_new_workspace(false, global.get_current_time());
        ws.activate(global.get_current_time());

        const record = {
            workspace: ws, previous, windows: new Set(),
            focusWasOn: this._focus.isOn(), banners: null, drawer: false,
        };
        this._open.set(id, record);
        // The workspace bar shows GNOME's own workspace names.
        const prefs = new Gio.Settings({schema_id: WM_PREFS});
        prefs.set_strv('workspace-names', namedAt(prefs.get_strv('workspace-names'), ws.index(), env.name));
        // Gone some other way (its apps closed by hand, so GNOME removed it): its name goes with it,
        // or the next workspace would take it over, and it counts as closed.
        record.removedId = wm.connect('workspace-removed', (_wm, index) => {
            if (this._open.get(id) !== record || [...Array(wm.n_workspaces).keys()].some(i => wm.get_workspace_by_index(i) === ws))
                return;
            wm.disconnect(record.removedId);
            record.removedId = 0;
            this._open.delete(id);
            prefs.set_strv('workspace-names', withoutIndex(prefs.get_strv('workspace-names'), index));
            this._focus.changed?.();
        });
        // Its last app closed by hand (once it has finished opening): that closes it, as Close would,
        // also with a fixed number of workspaces, where GNOME keeps the empty one.
        record.emptyId = ws.connect('window-removed', () => GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
            if (this._open.get(id) === record && this._opening?.record !== record &&
                !ws.list_windows().some(w => w.get_window_type() === Meta.WindowType.NORMAL))
                this.Close(id);
            return GLib.SOURCE_REMOVE;
        }));
        this._placeWindows(env, ws, record);

        const appSys = Shell.AppSystem.get_default();
        const missing = [];
        for (const a of env.apps) {
            const app = appSys.lookup_app(a.app);
            if (!app) {
                missing.push(a.app);
                continue;
            }
            const count = Math.max(1, a.windows.length);
            const contents = this._focus.restoreContents?.() ?? true;
            for (let i = 0; i < count; i++) {
                // A window with something inside (a folder, pages): opened with it.
                const inside = a.windows[i];
                if (contents && (inside?.open || inside?.cwd) && launchWithState(app, inside))
                    continue;
                if (app.get_state() === Shell.AppState.RUNNING || i > 0) {
                    if (app.can_open_new_window())
                        app.open_new_window(ws.index());
                } else {
                    app.launch(0, ws.index(), Shell.AppLaunchGpu.APP_PREF);
                }
            }
        }
        if (missing.length > 0)
            Main.notify(`${env.name}: some apps aren't installed`, missing.join(', '));

        if (env.power)
            this._setPower(env.power);
        if (env.focus.on)
            this._focus.setFocus(true, env.focus.allowed);
        if (env.drawer) {
            drawerAction('use-set', new GLib.Variant('(asas)', [env.drawer.sites, env.drawer.keep]));
            record.drawer = true;
        }
        if (env.dnd) {
            const n = new Gio.Settings({schema_id: 'org.gnome.desktop.notifications'});
            record.banners = n.get_boolean('show-banners');
            n.set_boolean('show-banners', false);
        }
        this._focus.changed?.();
    }

    Close(id) {
        const record = this._open.get(id);
        if (!record)
            return;
        this._open.delete(id);
        if (record.removedId)
            global.workspace_manager.disconnect(record.removedId);
        record.removedId = 0;
        if (record.emptyId)
            record.workspace.disconnect(record.emptyId);
        record.emptyId = 0;
        if (this._opening?.record === record)
            this._stopOpening();
        const ws = record.workspace;
        // Every app window on the workspace, also ones opened after it was: they're its progress.
        const windows = new Set([...record.windows, ...normalWindows(ws)]);
        try {
            writeEnv(id, withLayout(readEnv(id), describeAll(normalWindows(ws), this._focus.restoreContents?.() ?? true)));
        } catch (e) {
            console.warn(`environments: could not save where ${id} was left: ${e.message}`);
        }
        const time = global.get_current_time();
        for (const w of windows) {
            try {
                w.delete(time); // the app may still ask about unsaved work
            } catch {
                // already gone
            }
        }
        this._removeWhenEmpty(ws);
        if (record.banners !== null)
            new Gio.Settings({schema_id: 'org.gnome.desktop.notifications'}).set_boolean('show-banners', record.banners);
        if (record.drawer)
            drawerAction('use-set', new GLib.Variant('(asas)', [[], []]));
        if (!record.focusWasOn && this._focus.isOn())
            this._focus.setFocus(false, []);
        // Back to where you were, if that workspace still exists (activating a removed one doesn't
        // throw: mutter logs a critical and makes it active).
        const wm = global.workspace_manager;
        if ([...Array(wm.n_workspaces).keys()].some(i => wm.get_workspace_by_index(i) === record.previous))
            record.previous.activate(time);
        this._focus.changed?.();
    }

    // The workspace goes (with its name) once its windows have closed; an app still asking about
    // unsaved work keeps it, and after CLOSE_TIMEOUT_S it's left for GNOME (dynamic workspaces
    // remove empty ones anyway).
    _removeWhenEmpty(ws) {
        const wm = global.workspace_manager;
        // Its index without asking a removed workspace (that logs a critical): -1 once it's gone.
        const indexOf = () => {
            for (let i = 0; i < wm.n_workspaces; i++) {
                if (wm.get_workspace_by_index(i) === ws)
                    return i;
            }
            return -1;
        };
        let lastIndex = indexOf();
        const signals = new Signals();
        let timeoutId = 0;
        const done = () => {
            signals.disconnectAll();
            if (timeoutId)
                GLib.source_remove(timeoutId);
            timeoutId = 0;
            this._closing?.delete(done);
        };
        const dropName = index => {
            const prefs = new Gio.Settings({schema_id: WM_PREFS});
            prefs.set_strv('workspace-names', withoutIndex(prefs.get_strv('workspace-names'), index));
        };
        const check = () => {
            const index = indexOf();
            if (index < 0) { // GNOME removed it already (dynamic workspaces): its name goes too
                dropName(lastIndex);
                return done();
            }
            lastIndex = index;
            if (ws.list_windows().some(w => w.get_window_type() === Meta.WindowType.NORMAL))
                return undefined;
            dropName(index);
            if (wm.n_workspaces > 1)
                wm.remove_workspace(ws, global.get_current_time());
            return done();
        };
        signals.connect(ws, 'window-removed', () => {
            lastIndex = indexOf();
            GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                if (timeoutId)
                    check();
                return GLib.SOURCE_REMOVE;
            });
        });
        timeoutId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, CLOSE_TIMEOUT_S, () => {
            timeoutId = 0;
            done();
            return GLib.SOURCE_REMOVE;
        });
        this._closing ??= new Set();
        this._closing.add(done);
        check();
    }

    Delete(id) {
        envFile(id).delete(null);
    }

    GetDrawer(id) {
        return JSON.stringify(readEnv(id).drawer);
    }

    /** Replaces an environment's drawer set ("null" removes it); the file is checked as always. */
    SetDrawer(id, json) {
        const env = readEnv(id);
        env.drawer = drawerSet(JSON.parse(json));
        writeEnv(id, validate(env));
        if (this._open.has(id)) {
            const d = env.drawer ?? {sites: [], keep: []};
            drawerAction('use-set', new GLib.Variant('(asas)', [d.sites, d.keep]));
            this._open.get(id).drawer = !!env.drawer;
        }
    }

    anyOpen() {
        return this._open.size > 0;
    }

    State() {
        return JSON.stringify({
            activeWorkspace: global.workspace_manager.get_active_workspace().index(),
            workspaces: global.workspace_manager.n_workspaces,
            open: [...this._open.keys()],
            windows: normalWindows().map(describe),
        });
    }

    // ---- placing windows as they appear ----

    _placeWindows(env, ws, record) {
        const queue = placementQueue(env);
        const signals = new Signals();
        const tracker = Shell.WindowTracker.get_default();
        const place = win => {
            const app = tracker.get_window_app(win)?.get_id();
            const spot = app ? takePlace(queue, app) : null;
            if (!spot)
                return;
            record.windows.add(win);
            win.change_workspace(ws);
            if (spot.monitor < global.display.get_n_monitors())
                win.move_to_monitor(spot.monitor);
            if (spot.maximized) {
                win.maximize();
            } else {
                if (win.is_maximized())
                    win.unmaximize();
                win.move_resize_frame(true, spot.x, spot.y, spot.width, spot.height);
            }
            if (allPlaced(queue))
                this._stopOpening();
        };
        signals.connect(global.display, 'window-created', (_d, win) => {
            if (win.get_window_type() !== Meta.WindowType.NORMAL)
                return;
            // The app (and its size) are known once the window is shown.
            const id = win.connect('shown', () => {
                win.disconnect(id);
                if (this._opening?.signals === signals)
                    place(win);
            });
        });
        const timeoutId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, OPEN_TIMEOUT_S, () => {
            this._opening.timeoutId = 0;
            this._stopOpening();
            return GLib.SOURCE_REMOVE;
        });
        this._opening = {queue, signals, timeoutId, record};
    }

    _stopOpening() {
        if (!this._opening)
            return;
        this._opening.signals.disconnectAll();
        if (this._opening.timeoutId)
            GLib.source_remove(this._opening.timeoutId);
        this._opening = null;
    }

    _setPower(profile) {
        const tryNext = i => {
            if (i >= PROFILES_BUSES.length)
                return;
            const [name, path] = PROFILES_BUSES[i];
            Gio.DBus.system.call(name, path, 'org.freedesktop.DBus.Properties', 'Set',
                new GLib.Variant('(ssv)', [name, 'ActiveProfile', new GLib.Variant('s', profile)]),
                null, Gio.DBusCallFlags.NONE, -1, null, (bus, res) => {
                    try {
                        bus.call_finish(res);
                    } catch {
                        tryNext(i + 1);
                    }
                });
        };
        tryNext(0);
    }
}
