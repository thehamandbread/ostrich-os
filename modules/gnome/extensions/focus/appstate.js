// SPDX-License-Identifier: GPL-2.0-or-later
// focus/appstate.js: what a saved workspace remembers about what was inside its apps, the parts with
// no GNOME calls so the gjs tests can run them: which kind of app is which, how a window with saved
// state is launched, and how browser windows are matched to the windows in their session file.
// The parts that read the system (windows, D-Bus, /proc, session files) are in appstate-live.js.

/**
 * The kind of an app, by its desktop id: 'files', 'terminal', 'firefox' (Firefox and its forks),
 * 'chromium' (Chrome and its kin) or null (nothing inside it is saved).
 */
export function kindOf(appId) {
    const id = String(appId ?? '').toLowerCase();
    if (id === 'org.gnome.nautilus.desktop')
        return 'files';
    if (/^(com\.mitchellh\.ghostty|org\.gnome\.ptyxis|org\.gnome\.terminal|org\.kde\.konsole|kitty|alacritty|foot|org\.wezfurlong\.wezterm)\.desktop$/.test(id))
        return 'terminal';
    if (/(^|[._-])(firefox|zen|librewolf|waterfox|floorp)([._-]|\.desktop$)/.test(id))
        return 'firefox';
    if (/(chrome|chromium|brave|vivaldi|microsoft-edge|opera)/.test(id))
        return 'chromium';
    return null;
}

// Where each Firefox family browser keeps its profiles, under the home folder (snap, Flatpak, deb).
const FIREFOX_ROOTS = {
    firefox: ['.mozilla/firefox', 'snap/firefox/common/.mozilla/firefox', '.var/app/org.mozilla.firefox/.mozilla/firefox'],
    zen: ['.zen', '.var/app/app.zen_browser.zen/.zen'],
    librewolf: ['.librewolf', '.var/app/io.gitlab.librewolf-community/.librewolf'],
    waterfox: ['.waterfox', '.var/app/net.waterfox.waterfox/.waterfox'],
    floorp: ['.floorp', '.var/app/one.ablaze.floorp/.floorp'],
};

/** The profile folders (relative to home) to look in for a Firefox family app, by its desktop id. */
export function firefoxRoots(appId) {
    const id = String(appId ?? '').toLowerCase();
    const family = Object.keys(FIREFOX_ROOTS).find(k => id.includes(k));
    return family ? FIREFOX_ROOTS[family] : [];
}

/**
 * The program and fixed arguments from a desktop file's Exec line: field codes (%u %U %f %F …) and
 * Flatpak's file-forwarding markers (@@u … @@) removed.
 *
 * @param {string[]} argv  the Exec line already split into words
 */
export function baseArgv(argv) {
    const out = [];
    let forwarding = false;
    for (const word of argv) {
        if (word === '@@u' || word === '@@f' || word === '@@') {
            forwarding = word !== '@@';
            continue;
        }
        if (forwarding && /^%[a-zA-Z]$/.test(word))
            continue;
        if (/^%[a-zA-Z%]$/.test(word) && word !== '%%')
            continue;
        out.push(word);
    }
    return out;
}

const TERMINAL_CWD_FLAG = {
    ghostty: dir => [`--working-directory=${dir}`],
    ptyxis: dir => ['--new-window', `--working-directory=${dir}`],
    'gnome-terminal': dir => [`--working-directory=${dir}`],
    konsole: dir => ['--workdir', dir],
    kitty: dir => [`--directory=${dir}`],
    alacritty: dir => ['--working-directory', dir],
    foot: dir => [`--working-directory=${dir}`],
    wezterm: dir => ['start', '--cwd', dir],
};

/**
 * The command that opens one window with its saved state, or null when there is nothing to pass
 * (the app is then launched as before). `base` is baseArgv() of the app's Exec line.
 *
 * @param {string|null} kind  kindOf()
 * @param {string[]} base
 * @param {{open?: string[], cwd?: string}} state
 */
export function launchArgv(kind, base, state) {
    if (base.length === 0)
        return null;
    const program = base.find(w => !w.startsWith('-') && !w.includes('=')) ?? base[0];
    const name = program.split('/').pop();
    if (kind === 'terminal' && state.cwd) {
        const flags = TERMINAL_CWD_FLAG[Object.keys(TERMINAL_CWD_FLAG).find(k => name.includes(k) || base.some(w => w.includes(k)))];
        return flags ? [...base, ...flags(state.cwd)] : null;
    }
    if (kind === 'files' && state.open?.length)
        return [...base, '--new-window', state.open[0]];
    // Firefox's flags each take one address: the first opens the window, the rest are tabs in it
    // (`--new-window A B` opened B in a window of its own). Chrome takes the pages as plain arguments.
    if (kind === 'firefox' && state.open?.length)
        return [...base, '--new-window', state.open[0], ...state.open.slice(1).flatMap(u => ['--new-tab', u])];
    if (kind === 'chromium' && state.open?.length)
        return [...base, '--new-window', ...state.open];
    return null;
}

/**
 * The command wrapped to run in a scope of its own, as GNOME does for an app it launches
 * (`app-gnome-<app id>-<suffix>.scope`). Started straight from the shell, an app would sit in the
 * shell's own unit: its memory counted as the shell's, hidden from the monitor's per-app alerts, and
 * ended with the shell. Flatpak makes its own scope, so its command is left as it is.
 *
 * @param {string} appId  the desktop id
 * @param {string[]} argv
 * @param {string} suffix  random hex, so two windows of one app get two scopes
 */
export function scopedArgv(appId, argv, suffix) {
    if ((argv[0] ?? '').split('/').pop() === 'flatpak')
        return argv;
    const name = String(appId).replace(/\.desktop$/, '').replace(/[^A-Za-z0-9._-]/g, '_');
    return ['systemd-run', '--user', '--scope', '--quiet', '--collect', `--unit=app-gnome-${name}-${suffix}.scope`, ...argv];
}

/** Strips the browser's name from a window title: "A page — Mozilla Firefox" -> "A page". */
function pageTitle(title) {
    return String(title ?? '').replace(/\s+[—–-]\s+[^—–-]*$/, '').trim();
}

/**
 * Which session window each browser window is. Matching is by title: a window's title starts with
 * its selected tab's title. Then, if one window and one session window are left, they pair
 * (a title that changed since the file was written). More than one left is not guessed at: those
 * windows get nothing, since the extra session windows may be on other workspaces.
 *
 * @param {string[]} sessionTitles  the selected tab's title of each window in the session file
 * @param {string[]} windowTitles   the titles of the browser windows on the workspace
 * @returns {Array<number|null>}  per window, the index into sessionTitles, or null
 */
export function pairWindows(sessionTitles, windowTitles) {
    const taken = new Set();
    const result = windowTitles.map(() => null);
    windowTitles.forEach((title, w) => {
        let best = -1, bestLen = 0;
        sessionTitles.forEach((s, k) => {
            const t = String(s ?? '').trim();
            if (taken.has(k) || t.length === 0)
                return;
            if (String(title).startsWith(t) || pageTitle(title) === t) {
                if (t.length > bestLen) {
                    best = k;
                    bestLen = t.length;
                }
            }
        });
        if (best >= 0) {
            result[w] = best;
            taken.add(best);
        }
    });
    const lostWindows = result.flatMap((r, w) => (r === null ? [w] : []));
    const lostSession = sessionTitles.flatMap((_, k) => (taken.has(k) ? [] : [k]));
    if (lostWindows.length === 1 && lostSession.length === 1)
        result[lostWindows[0]] = lostSession[0];
    return result;
}

/**
 * The windows of a Firefox session file (parsed JSON): each with the title of its selected tab and
 * the page addresses of its tabs in order, pinned first. Only http(s) pages; blank, about: and
 * internal pages are left out.
 *
 * @returns {Array<{title: string, uris: string[]}>}
 */
export function firefoxWindows(session) {
    const windows = Array.isArray(session?.windows) ? session.windows : [];
    return windows.map(w => {
        const tabs = (Array.isArray(w?.tabs) ? w.tabs : []).map(t => {
            const entries = Array.isArray(t?.entries) ? t.entries : [];
            const entry = entries[Math.min(Math.max((t?.index ?? entries.length) - 1, 0), entries.length - 1)];
            return {url: String(entry?.url ?? ''), title: String(entry?.title ?? ''), pinned: !!t?.pinned};
        });
        const selected = tabs[Math.min(Math.max((w?.selected ?? 1) - 1, 0), tabs.length - 1)];
        const web = tabs.filter(t => /^https?:\/\//.test(t.url));
        return {
            title: selected?.title ?? '',
            uris: [...web.filter(t => t.pinned), ...web.filter(t => !t.pinned)].map(t => t.url),
        };
    }).filter(w => w.uris.length > 0 || w.title !== '');
}

/**
 * Which folder each terminal window was in. Windows are matched to folders by title (a shell's
 * title usually names its folder); the windows left take the folders left, in order, but only when
 * there are as many shells as windows (more shells: some are on other workspaces, and a leftover
 * folder may be theirs). A guess when several terminals are open and their titles don't say.
 *
 * @param {string[]} titles  the terminal windows' titles
 * @param {string[]} cwds    the folders of the shells (absolute paths)
 * @param {string} home      the home folder, for "~" in a title
 * @returns {Array<string|null>}
 */
export function assignFolders(titles, cwds, home) {
    const used = new Set();
    const out = titles.map(() => null);
    const names = cwds.map(c => (c === home ? '~' : c.split('/').filter(Boolean).pop() ?? '/'));
    titles.forEach((t, i) => {
        const k = cwds.findIndex((c, j) => !used.has(j) &&
            (t.includes(c) || (c === home ? /(^|[\s:])~(\s|$|\/)/.test(t) : t.includes(names[j]))));
        if (k >= 0) {
            out[i] = cwds[k];
            used.add(k);
        }
    });
    if (cwds.length !== titles.length)
        return out;
    const left = cwds.filter((_, j) => !used.has(j));
    out.forEach((v, i) => {
        if (v === null && left.length > 0)
            out[i] = left.shift();
    });
    return out;
}
