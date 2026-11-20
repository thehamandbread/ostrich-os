// SPDX-License-Identifier: GPL-2.0-or-later
// dock/docklogic.js: the dock's decisions with no GNOME calls, so the gjs unit tests run them.

/**
 * What a left click on an app's icon does.
 *
 * @param {{running: boolean, focused: boolean, windows: number}} app  windows: on this workspace
 * @param {string} setting  'focus-or-minimize' | 'focus-or-cycle' | 'focus'
 * @returns {'launch'|'activate'|'minimize'|'cycle'}
 */
export function clickAction(app, setting) {
    if (!app.running || app.windows === 0)
        return app.running ? 'activate' : 'launch';
    if (!app.focused || setting === 'focus')
        return 'activate';
    if (app.windows > 1)
        return 'cycle';
    return setting === 'focus-or-minimize' ? 'minimize' : 'activate';
}

/**
 * Whether a running app belongs in the dock: it has a window of its own. An app that only sits in
 * the tray (a chat client, a sync tool) has none, and a new icon would widen the dock and move it
 * (owner, 2026-11-19).
 */
export function hasDockWindow(windows) {
    return windows.some(w => !w.skip_taskbar);
}

/** The window after `current` in a list (wrapping); the first if `current` isn't in it. */
export function nextWindow(windows, current, step = 1) {
    if (windows.length === 0)
        return null;
    const i = windows.indexOf(current);
    if (i < 0)
        return windows[0];
    return windows[(i + step + windows.length) % windows.length];
}

/** How many running dots to draw: one per window, at most `max`; none when not running. */
export function dotCount(windows, max = 4) {
    return Math.max(0, Math.min(max, Math.floor(windows)));
}

/**
 * The Unity LauncherEntry properties an app last sent (count, progress, urgent), merged.
 * Apps send only what changed.
 */
export function mergeLauncherEntry(prev, props) {
    const e = {count: 0, countVisible: false, progress: 0, progressVisible: false, urgent: false, ...prev};
    if ('count' in props)
        e.count = Math.max(0, Math.floor(Number(props.count) || 0));
    if ('count-visible' in props)
        e.countVisible = !!props['count-visible'];
    if ('progress' in props)
        e.progress = Math.min(1, Math.max(0, Number(props.progress) || 0));
    if ('progress-visible' in props)
        e.progressVisible = !!props['progress-visible'];
    if ('urgent' in props)
        e.urgent = !!props.urgent;
    return e;
}

/** "application://firefox_firefox.desktop" -> "firefox_firefox.desktop" (null if not an app URI). */
export function appIdFromUri(uri) {
    const m = /^application:\/\/(.+\.desktop)$/.exec(uri ?? '');
    return m ? m[1] : null;
}

/** The badge text for a launcher count: "3", "99+", or '' (no badge). */
export function countText(entry) {
    if (!entry?.countVisible || entry.count <= 0)
        return '';
    return entry.count > 99 ? '99+' : String(entry.count);
}
