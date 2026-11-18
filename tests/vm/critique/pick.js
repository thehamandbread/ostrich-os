// SPDX-License-Identifier: GPL-2.0-or-later
// critique/pick.js: what was boxed, in plain words, and which extension owns it. No GNOME calls,
// so the gjs unit tests run it; extension.js gathers the facts from the live stage.
//
// `chain` is the picked actor and its parents, innermost first:
//   [{type, name, styleClass, role, text, app}]   role: the panel status-area role, if any;
//                                                  text: a label's text; app: an app's name
// `win` is the window under the box, if no shell UI was picked: {appId, appName, title}.

const OURS = '@ubuntu-ostrich';

const ROLES = [
    [/^drawer@ubuntu-ostrich--add$/, () => ['Ostrich Drawer', '+ (add a site)']],
    [/^drawer@ubuntu-ostrich--more$/, () => ['Ostrich Drawer', '⌄ menu']],
    [/^drawer@ubuntu-ostrich-(.+)$/, m => ['Ostrich Drawer', `${m[1]} icon`]],
    [/^workspaces@ubuntu-ostrich$/, () => ['Workspace bar']],
    [/^monitor@ubuntu-ostrich$/, () => ['System monitor']],
    [/^tray@ubuntu-ostrich-(.+)$/, m => ['Tray', m[1]]],
    [/^quickSettings$/, () => ['Quick settings']],
    [/^dateMenu$/, () => ['Clock and calendar']],
    [/^activities$/, () => ['Activities button']],
];

// The extension a role or actor name belongs to ("dock@ubuntu-ostrich"), or null.
export function ownerOf(chain) {
    for (const a of chain) {
        if (a.name === 'ost-dock')
            return `dock${OURS}`;
        if (a.name?.startsWith('ost-blur'))
            return `blur${OURS}`;
        const m = /^([a-z-]+)@ubuntu-ostrich/.exec(a.role ?? '');
        if (m)
            return `${m[1]}${OURS}`;
        if ((a.styleClass ?? '').includes('ost-ws-'))
            return `workspaces${OURS}`;
        if ((a.styleClass ?? '').includes('ost-drawer'))
            return `drawer${OURS}`;
    }
    return null;
}

/**
 * A readable name for what was boxed: "Dock › Firefox", "Ostrich Drawer › claude icon",
 * "Workspace bar › mail", "Quick settings menu", "Window: Files — Home".
 *
 * @returns {{label: string, owner: string|null}}
 */
export function describe(chain, win = null) {
    const owner = ownerOf(chain);
    const parts = [];
    const roleOf = chain.find(a => a.role);
    if (chain.some(a => a.name === 'ost-dock')) {
        parts.push('Dock');
        const app = chain.find(a => a.app)?.app;
        if (app)
            parts.push(app);
        else if (chain.some(a => (a.styleClass ?? '').includes('show-apps')))
            parts.push('app grid button');
    } else if (roleOf) {
        const r = ROLES.find(([re]) => re.test(roleOf.role));
        parts.push(...(r ? r[1](roleOf.role.match(r[0])) : [roleOf.role]));
        // A workspace pill: its name.
        const text = chain.find(a => a.text)?.text;
        if (roleOf.role.startsWith('workspaces') && text)
            parts.push(text);
    } else if (chain.some(a => (a.styleClass ?? '').includes('quick-settings'))) {
        parts.push('Quick settings menu');
    } else if (chain.some(a => (a.styleClass ?? '').includes('popup-menu'))) {
        parts.push('Menu');
    } else if (chain.some(a => (a.styleClass ?? '').includes('app-folder-dialog'))) {
        parts.push('App folder');
    } else if (chain.some(a => a.name === 'ost-dock-previews' || (a.styleClass ?? '').includes('ost-dock-preview'))) {
        parts.push('Dock', 'window previews');
    } else if (chain.some(a => a.type === 'Gjs_ui_panel_Panel' || a.name === 'panel')) {
        parts.push('Top bar');
    } else if (chain.some(a => ['Gjs_ui_overviewControls_ControlsManager', 'Gjs_ui_workspace_Workspace'].includes(a.type))) {
        parts.push('Overview');
    } else if (win) {
        if (win.appId?.startsWith('ubuntu_ostrich.drawer'))
            return {label: `Ostrich Drawer window${win.site ? ` (${win.site})` : ''}`, owner: `drawer${OURS}`};
        return {label: `Window: ${win.appName || win.appId || 'unknown app'} — ${win.title ?? ''}`.trim(), owner: win.appId ?? null};
    } else {
        parts.push(chain[0]?.type ?? 'the desktop');
    }
    return {label: parts.join(' › '), owner};
}

/** A short, file-name-safe slug from a note's text: "dock-icons-too-far-apart". */
export function slug(text) {
    const s = String(text ?? '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
    return s.slice(0, 40).replace(/-+$/, '') || 'note';
}

/** The box's crop, grown by `margin` and kept on the screen. */
export function cropRect(box, margin, screen) {
    const x0 = Math.max(0, Math.round(box.x - margin));
    const y0 = Math.max(0, Math.round(box.y - margin));
    const x1 = Math.min(screen.width, Math.round(box.x + box.width + margin));
    const y1 = Math.min(screen.height, Math.round(box.y + box.height + margin));
    return {x: x0, y: y0, width: Math.max(1, x1 - x0), height: Math.max(1, y1 - y0)};
}

/** A drag from (x0, y0) to (x1, y1) as a box; a click (a tiny drag) is a point. */
export function boxFromDrag(x0, y0, x1, y1) {
    const box = {x: Math.min(x0, x1), y: Math.min(y0, y1), width: Math.abs(x1 - x0), height: Math.abs(y1 - y0)};
    return {...box, click: box.width < 6 && box.height < 6};
}
