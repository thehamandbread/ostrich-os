// SPDX-License-Identifier: GPL-2.0-or-later
// workspaces/names.js: "smart" workspace names (compatible with space-bar's workspace-names-map).
// Pure functions, no GNOME Shell imports, so they can be unit-tested with plain gjs.
//
// The map is {wmClass: [name, ...]}: when the user names a workspace, every app on it is associated
// with that name. When an unnamed workspace gains an app with an associated name that isn't in use
// on another workspace, the workspace takes that name.

// The name to give an unnamed workspace holding these window classes, or null.
export function smartName(map, wmClasses, namesInUse) {
    for (const cls of wmClasses) {
        const candidates = map[cls] ?? [];
        const free = candidates.find(n => n && !namesInUse.includes(n));
        if (free)
            return free;
    }
    return null;
}

// A new map after the user names a workspace holding these window classes. Each class keeps only
// associations with names still in use elsewhere, plus the new name (last = most recent).
export function associate(map, wmClasses, newName, namesInUse) {
    const next = {...map};
    for (const cls of wmClasses) {
        const kept = (next[cls] ?? []).filter(n => n !== newName && namesInUse.includes(n));
        next[cls] = [...kept, newName];
    }
    return next;
}

// Label for a workspace: its name, or its 1-based number.
export function label(names, index) {
    return names[index] || `${index + 1}`;
}

// What a screen reader says for a pill: "Workspace 2: mail, current".
export function accessibleName(names, index, current) {
    const name = names[index] ? `Workspace ${index + 1}: ${names[index]}` : `Workspace ${index + 1}`;
    return current ? `${name}, current` : name;
}

// Parses the JSON map setting; bad or empty input gives an empty map.
export function parseMap(text) {
    try {
        const v = JSON.parse(text || '{}');
        return v && typeof v === 'object' && !Array.isArray(v) ? v : {};
    } catch {
        return {};
    }
}

// The names list after a workspace moves from one place to another (names travel with it).
export function moveName(names, from, to) {
    const n = Math.max(names.length, from + 1, to + 1);
    const list = Array.from({length: n}, (_, i) => names[i] ?? '');
    const [moved] = list.splice(from, 1);
    list.splice(to, 0, moved);
    while (list.length > 0 && list.at(-1) === '')
        list.pop();
    return list;
}

// The names list after a workspace is removed (the ones after it move up).
export function removeName(names, index) {
    const list = names.filter((_, i) => i !== index);
    while (list.length > 0 && list.at(-1) === '')
        list.pop();
    return list;
}

// Which workspaces get a pill: all of them, or only the active one ('current'); empty ones
// (no windows) can be left out, except the active one.
export function visibleIndexes({count, active, empty, style, showEmpty}) {
    const out = [];
    for (let i = 0; i < count; i++) {
        if (style === 'current' && i !== active)
            continue;
        if (!showEmpty && empty[i] && i !== active)
            continue;
        out.push(i);
    }
    return out;
}
