// SPDX-License-Identifier: GPL-2.0-or-later
// _lib/palette.js: palette.json from the palette tool: {accent, candidates (the wallpaper's picks), ...}.

import GLib from 'gi://GLib';

// The parsed file, or null when it's missing or broken.
export function readPalette() {
    try {
        const path = GLib.build_filenamev([GLib.get_user_config_dir(), 'ubuntu-ostrich', 'palette.json']);
        const [ok, bytes] = GLib.file_get_contents(path);
        return ok ? JSON.parse(new TextDecoder().decode(bytes)) : null;
    } catch {
        return null;
    }
}
