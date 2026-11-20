// SPDX-License-Identifier: GPL-2.0-or-later
// focus/appstate-live.js: reads what is inside an app's windows from the system, and launches a
// window with it. The rules (which app is which, the command lines, matching windows) are in
// appstate.js; this file asks GNOME, D-Bus, /proc and the browsers' session files.
//
// Everything here is best effort and short: a reader that fails logs one line and its windows are
// saved as before (apps and places only). Nothing here writes outside the workspace file.
//
//   Files      the folder each window shows, from Files' own org.freedesktop.FileManager1
//   terminals  the folder of the shells under the terminal's process, from /proc/<pid>/cwd
//   Firefox    the pages of each window, from the newest sessionstore-backups/recovery.jsonlz4 of the
//   family     browser's profile (the file is read, never written or put back)

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import {kindOf, baseArgv, launchArgv, scopedArgv, pairWindows, firefoxWindows, assignFolders, firefoxRoots} from './appstate.js';
import {mozlz4Text} from './mozlz4.js';

const FILES_BUS = 'org.freedesktop.FileManager1';
const FILES_PATH = '/org/freedesktop/FileManager1';
const SHELLS = new Set(['bash', 'zsh', 'fish', 'sh', 'dash', 'nu', 'xonsh', 'tcsh', 'ksh']);
const D_BUS_TIMEOUT_MS = 1000;
const MAX_SESSION_BYTES = 16 * 1024 * 1024; // a normal session file is 1-5 MB; a bigger one would stall the shell
const MAX_DESCENDANTS = 400; // a terminal's process tree is small; stop before a runaway one costs time

function appIdOf(win) {
    return Shell.WindowTracker.get_default().get_window_app(win)?.get_id() ?? null;
}

function readText(path) {
    try {
        const [ok, bytes] = Gio.File.new_for_path(path).load_contents(null);
        return ok ? new TextDecoder().decode(bytes) : null;
    } catch {
        return null;
    }
}

// ---- Files ----

function filesState(wins) {
    const reply = Gio.DBus.session.call_sync(FILES_BUS, FILES_PATH, 'org.freedesktop.DBus.Properties', 'Get',
        new GLib.Variant('(ss)', [FILES_BUS, 'OpenWindowsWithLocations']), null,
        Gio.DBusCallFlags.NO_AUTO_START, D_BUS_TIMEOUT_MS, null);
    const locations = reply.recursiveUnpack()[0]; // {window object path: [uri, …]}
    const out = new Map();
    const entries = Object.entries(locations);
    for (const w of wins) {
        const path = w.get_gtk_window_object_path?.();
        const hit = entries.find(([p]) => p === path);
        if (hit?.[1]?.length)
            out.set(w, {open: [hit[1][0]]});
    }
    // One Files window and one entry, whatever its path says.
    if (out.size === 0 && wins.length === 1 && entries.length === 1 && entries[0][1].length)
        out.set(wins[0], {open: [entries[0][1][0]]});
    return out;
}

// ---- terminals ----

// The processes `pid` started. The kernel lists them per thread, and a terminal forks from a thread
// that isn't its main one, so every thread's list is read.
function childrenOf(pid) {
    const out = [];
    let en;
    try {
        en = Gio.File.new_for_path(`/proc/${pid}/task`).enumerate_children('standard::name', Gio.FileQueryInfoFlags.NONE, null);
    } catch {
        return out;
    }
    for (let info; (info = en.next_file(null));) {
        const text = readText(`/proc/${pid}/task/${info.get_name()}/children`) ?? '';
        out.push(...text.split(' ').filter(s => /^\d+$/.test(s)).map(Number));
    }
    return out;
}

// The folders of the shells under `pid` (not shells nested in other shells).
function shellFolders(pid) {
    const folders = [];
    const queue = [pid];
    for (let seen = 0; queue.length > 0 && seen < MAX_DESCENDANTS; seen++) {
        const p = queue.shift();
        const comm = (readText(`/proc/${p}/comm`) ?? '').trim();
        if (p !== pid && SHELLS.has(comm)) {
            try {
                folders.push(GLib.file_read_link(`/proc/${p}/cwd`));
            } catch {
                // gone, or not ours to read
            }
            continue;
        }
        queue.push(...childrenOf(p));
    }
    return folders;
}

function terminalState(wins) {
    const out = new Map();
    const byPid = new Map();
    for (const w of wins) {
        const pid = w.get_pid();
        if (!byPid.has(pid))
            byPid.set(pid, []);
        byPid.get(pid).push(w);
    }
    for (const [pid, group] of byPid) {
        if (!(pid > 0))
            continue;
        const folders = assignFolders(group.map(w => w.get_title() ?? ''), shellFolders(pid), GLib.get_home_dir());
        group.forEach((w, i) => {
            if (folders[i])
                out.set(w, {cwd: folders[i]});
        });
    }
    return out;
}

// ---- Firefox and its forks ----

// The newest session file of the browser's profiles, or null.
function newestSession(appId) {
    let best = null, bestTime = 0;
    for (const root of firefoxRoots(appId)) {
        const dir = Gio.File.new_for_path(GLib.build_filenamev([GLib.get_home_dir(), root]));
        let en;
        try {
            en = dir.enumerate_children('standard::name,standard::type', Gio.FileQueryInfoFlags.NONE, null);
        } catch {
            continue;
        }
        for (let info; (info = en.next_file(null));) {
            if (info.get_file_type() !== Gio.FileType.DIRECTORY)
                continue;
            const file = dir.get_child(info.get_name()).get_child('sessionstore-backups').get_child('recovery.jsonlz4');
            try {
                const t = file.query_info('time::modified', Gio.FileQueryInfoFlags.NONE, null).get_modification_date_time().to_unix();
                if (t > bestTime) {
                    best = file;
                    bestTime = t;
                }
            } catch {
                // this profile has no session file
            }
        }
    }
    return best;
}

function firefoxState(wins, appId) {
    const file = newestSession(appId);
    if (!file)
        return new Map();
    const [ok, bytes] = file.load_contents(null);
    if (!ok)
        return new Map();
    if (bytes.length > MAX_SESSION_BYTES) {
        console.warn(`environments: ${appId}'s session file is ${bytes.length} bytes: its pages aren't saved`);
        return new Map();
    }
    const sessionWindows = firefoxWindows(JSON.parse(mozlz4Text(bytes)));
    const pairs = pairWindows(sessionWindows.map(s => s.title), wins.map(w => w.get_title() ?? ''));
    const out = new Map();
    wins.forEach((w, i) => {
        const s = sessionWindows[pairs[i]];
        if (s?.uris.length)
            out.set(w, {open: s.uris});
    });
    return out;
}

const READERS = {files: filesState, terminal: terminalState, firefox: firefoxState};

/**
 * What the windows had open: a Map from window to {open?: string[], cwd?: string}. Windows of apps
 * with nothing readable, and windows a reader couldn't read, are not in it.
 *
 * @param {Meta.Window[]} windows
 */
export function captureState(windows) {
    const out = new Map();
    const byApp = new Map();
    for (const w of windows) {
        const id = appIdOf(w);
        if (!id || !READERS[kindOf(id)])
            continue;
        if (!byApp.has(id))
            byApp.set(id, []);
        byApp.get(id).push(w);
    }
    for (const [id, wins] of byApp) {
        try {
            for (const [w, state] of READERS[kindOf(id)](wins, id))
                out.set(w, state);
        } catch (e) {
            console.warn(`environments: couldn't read what ${id} has open: ${e.message}`);
        }
    }
    return out;
}

/**
 * Opens one window of `app` with its saved state. False when there is nothing to pass or it
 * couldn't be started, so the caller opens the window the plain way.
 *
 * @param {Shell.App} app
 * @param {{open?: string[], cwd?: string}} state
 */
export function launchWithState(app, state) {
    try {
        // A terminal's folder that has gone: the window opens the plain way.
        if (state.cwd && !GLib.file_test(state.cwd, GLib.FileTest.IS_DIR))
            return false;
        const info = app.get_app_info();
        const command = info?.get_commandline();
        if (!command)
            return false;
        const [, words] = GLib.shell_parse_argv(command);
        const argv = launchArgv(kindOf(app.get_id()), baseArgv(words), state);
        if (!argv)
            return false;
        const suffix = GLib.random_int_range(0x100000, 0xffffff).toString(16);
        Gio.Subprocess.new(scopedArgv(app.get_id(), argv, suffix), Gio.SubprocessFlags.NONE);
        return true;
    } catch (e) {
        console.warn(`environments: couldn't open ${app.get_id()} with its saved state: ${e.message}`);
        return false;
    }
}
