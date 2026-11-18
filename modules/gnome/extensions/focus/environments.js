// SPDX-License-Identifier: GPL-2.0-or-later
// focus/environments.js: saved desktops ("environments"), the parts with no GNOME calls so the gjs
// unit tests can run them: the file format, names, and which saved window a new window takes.
//
// An environment file (~/.config/ubuntu-ostrich/environments/<id>.json):
//   {"version": 1, "name": "Video editing",
//    "apps": [{"app": "org.gnome.Nautilus.desktop",
//              "windows": [{"monitor": 0, "x": 0, "y": 32, "width": 960, "height": 1048,
//                           "maximized": false}]}],
//    "focus": {"on": false, "allowed": []},     // optional: focus with these apps only
//    "power": "",                              // optional: power-saver | balanced | performance
//    "dnd": false,                              // optional: Do Not Disturb
//    "drawer": {"sites": ["claude", "gmail"],  // optional: Ostrich Drawer's top-bar sites, in order,
//               "keep": ["gmail"]}}             //   and the ones kept loaded (null: the normal set)

export const FORMAT_VERSION = 1;
const POWER = ['', 'power-saver', 'balanced', 'performance'];
const SITE_ID = /^[A-Za-z0-9-]{1,40}$/; // drawer site ids (drawer-host's config::valid_id)

/** File name for a display name: "Video editing" -> "video-editing". Null if nothing usable. */
export function idFor(name) {
    const id = String(name ?? '').trim().toLowerCase()
        .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
    return id === '' ? null : id;
}

function num(v, min, max) {
    return Number.isFinite(v) && v >= min && v <= max ? Math.round(v) : null;
}

/**
 * Builds an environment from the current windows.
 *
 * @param {string} name
 * @param {Array<{app: string, monitor: number, x: number, y: number, width: number, height: number, maximized: boolean}>} windows
 * @param {object} [extras] focus / power / dnd
 */
export function capture(name, windows, extras = {}) {
    const apps = new Map();
    for (const w of windows) {
        if (!w.app)
            continue;
        if (!apps.has(w.app))
            apps.set(w.app, []);
        apps.get(w.app).push({
            monitor: w.monitor, x: w.x, y: w.y, width: w.width, height: w.height, maximized: !!w.maximized,
        });
    }
    return validate({
        version: FORMAT_VERSION,
        name,
        apps: [...apps].map(([app, ws]) => ({app, windows: ws})),
        focus: extras.focus ?? {on: false, allowed: []},
        power: extras.power ?? '',
        dnd: !!extras.dnd,
        drawer: extras.drawer ?? null,
    });
}

/**
 * A saved workspace with its windows as they are now and everything else kept (focus, power, Do Not
 * Disturb, drawer): closing it saves where you left off, so opening it again resumes there. With no
 * windows left it's unchanged (closing an emptied workspace never wipes what was saved).
 */
export function withLayout(env, windows) {
    if (!windows.some(w => w.app))
        return env;
    return capture(env.name, windows, {focus: env.focus, power: env.power, dnd: env.dnd, drawer: env.drawer});
}

/** GNOME's workspace-names list with `index` named `name` (padded with empty names). */
export function namedAt(names, index, name) {
    const list = [...names];
    while (list.length <= index)
        list.push('');
    list[index] = name;
    return list;
}

/** The names after the workspace at `index` is removed: the later ones move down with theirs. */
export function withoutIndex(names, index) {
    const list = names.filter((_, i) => i !== index);
    while (list.length > 0 && list.at(-1) === '')
        list.pop();
    return list;
}

/** An environment's drawer set, with bad or repeated ids dropped; null if there isn't one. */
export function drawerSet(d) {
    if (typeof d !== 'object' || d === null)
        return null;
    const clean = list => [...new Set((Array.isArray(list) ? list : []).filter(x => typeof x === 'string' && SITE_ID.test(x)))];
    const sites = clean(d.sites);
    return {sites, keep: clean(d.keep).filter(k => sites.includes(k))};
}

/**
 * Checks and normalises an environment read from disk. Throws on anything unusable, so a broken or
 * hand-edited file can't make the shell do something odd.
 */
export function validate(env) {
    if (typeof env !== 'object' || env === null)
        throw new Error('not an environment');
    if (env.version !== FORMAT_VERSION)
        throw new Error(`unknown format version ${env.version}`);
    if (!idFor(env.name))
        throw new Error('environment has no name');
    const appId = /^[A-Za-z0-9._-]+\.desktop$/;
    const apps = (Array.isArray(env.apps) ? env.apps : []).map(a => {
        if (!appId.test(a?.app ?? ''))
            throw new Error(`bad app id ${a?.app}`);
        const windows = (Array.isArray(a.windows) ? a.windows : []).map(w => {
            const g = {
                monitor: num(w.monitor, 0, 16), x: num(w.x, -100000, 100000), y: num(w.y, -100000, 100000),
                width: num(w.width, 1, 100000), height: num(w.height, 1, 100000),
            };
            if (Object.values(g).includes(null))
                throw new Error(`bad window geometry for ${a.app}`);
            return {...g, maximized: !!w.maximized};
        });
        return {app: a.app, windows};
    });
    const allowed = Array.isArray(env.focus?.allowed) ? env.focus.allowed.filter(x => appId.test(x)) : [];
    if (!POWER.includes(env.power ?? ''))
        throw new Error(`bad power mode ${env.power}`);
    return {
        version: FORMAT_VERSION,
        name: String(env.name).slice(0, 60),
        apps,
        focus: {on: !!env.focus?.on, allowed},
        power: env.power ?? '',
        dnd: !!env.dnd,
        drawer: drawerSet(env.drawer),
    };
}

/**
 * While an environment opens, new windows take the saved places of their app in order.
 * Returns a queue: app id -> remaining saved windows.
 */
export function placementQueue(env) {
    const q = new Map();
    for (const a of env.apps)
        q.set(a.app, [...a.windows]);
    return q;
}

/** The saved place for a new window of `app`, or null (more windows than were saved). */
export function takePlace(queue, app) {
    const list = queue.get(app);
    if (!list || list.length === 0)
        return null;
    return list.shift();
}

/** True once every saved window has been placed. */
export function allPlaced(queue) {
    return [...queue.values()].every(l => l.length === 0);
}

/** Is an app allowed in focus? An empty list allows everything (focus without an allow-list). */
export function isAllowed(allowed, appId) {
    return allowed.length === 0 || allowed.includes(appId);
}
