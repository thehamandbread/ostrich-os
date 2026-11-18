// SPDX-License-Identifier: GPL-2.0-or-later
// _lib/scheme.js: the user's colour scheme for one extension. `ostrich theme scheme apply` writes
// ~/.config/ubuntu-ostrich/scheme/NAME.css from the same template as the extension's stylesheet.css,
// so it is a whole replacement: it's loaded in place of the extension's own stylesheet (St ranks a
// later custom stylesheet below an earlier one, so loading it on top would lose), and reloaded when
// it changes (no logout). No file: the built-in colours. GNOME carries loaded stylesheets over when
// it reloads its theme.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const theme = () => St.ThemeContext.get_for_stage(global.stage).get_theme();

export class SchemeStyle {
    constructor(extension) {
        const dir = GLib.build_filenamev([GLib.get_user_config_dir(), 'ubuntu-ostrich', 'scheme']);
        // The folder is watched, not the file: the tool replaces the file by renaming a new one in.
        GLib.mkdir_with_parents(dir, 0o700);
        this._dir = Gio.File.new_for_path(dir);
        this._file = this._dir.get_child(`${extension.uuid.split('@')[0]}.css`);
        // The extension's own stylesheet, as the extension manager loaded it.
        this._own = Main.extensionManager.lookup(extension.uuid)?.stylesheet ?? null;
        this._loaded = null;
        this._ownOff = false;
        this._monitor = this._dir.monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, null);
        this._monitor.connect('changed', (_m, file, other) => {
            if (file?.equal(this._file) || other?.equal(this._file))
                this._load();
        });
        this._load();
    }

    _load() {
        if (this._loaded) {
            theme().unload_stylesheet(this._loaded);
            this._loaded = null;
        }
        if (this._file.query_exists(null)) {
            try {
                theme().load_stylesheet(this._file);
                this._loaded = this._file;
            } catch (e) {
                console.warn(`scheme: ${this._file.get_path()}: ${e.message}`);
            }
        }
        this._showOwn(!this._loaded);
    }

    _showOwn(show) {
        if (!this._own || show === !this._ownOff)
            return;
        if (show)
            theme().load_stylesheet(this._own);
        else
            theme().unload_stylesheet(this._own);
        this._ownOff = !show;
    }

    destroy() {
        this._monitor.cancel();
        this._monitor = null;
        if (this._loaded)
            theme().unload_stylesheet(this._loaded);
        this._loaded = null;
        // Back for the extension manager, which unloads it after disable().
        this._showOwn(true);
    }
}
