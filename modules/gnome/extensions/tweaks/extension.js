// SPDX-License-Identifier: GPL-2.0-or-later
// Tweaks: animation speed, hiding top-bar items, the accent following the wallpaper, the Touchscreen
// quick-settings tile, and Today in the clock menu (today.js).
// Everything is restored on disable.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {readPalette} from './_lib/palette.js';
import {shellField} from './_lib/patches.js';
import {Signals} from './_lib/signals.js';
import {NowPlayingPill} from './nowplaying.js';
import {EventsCard, Today} from './today.js';
import {folderTheme} from './folders.js';
import {PowerRow} from './powerrow.js';
import {Quiet} from './quiet.js';
import {BluetoothDevices} from './btdevices.js';

const HELPER = '/usr/libexec/ostrich-os/system-helper';
const WALLPAPER_SETTLE_MS = 2000; // the wallpaper's light and dark URIs change one after the other

// Ubuntu's Yaru icon themes come in pairs (Yaru-sage, Yaru-sage-dark), and nothing switches them when
// the style changes from quick settings; this does. Other icon themes are left alone.
export function yaruFor(theme, dark) {
    if (!/^Yaru(-[a-z]+)?$/.test(theme.replace(/-dark$/, '')))
        return theme;
    const base = theme.replace(/-dark$/, '');
    return dark ? `${base}-dark` : base;
}

function run(argv) {
    return new Promise(resolve => {
        try {
            const proc = Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
            proc.communicate_utf8_async(null, null, (pr, res) => {
                try {
                    const [, out, err] = pr.communicate_utf8_finish(res);
                    resolve({ok: pr.get_successful(), out: (out ?? '').trim(), err: (err ?? '').trim()});
                } catch (e) {
                    resolve({ok: false, out: '', err: e.message});
                }
            });
        } catch (e) {
            resolve({ok: false, out: '', err: e.message});
        }
    });
}

// Touchscreen on/off through the privileged system helper (pkexec; polkit lets the local user do it
// without a password). Only shown when the helper is installed and reports a touchscreen.
const TouchscreenIndicator = GObject.registerClass(
class TouchscreenIndicator extends QuickSettings.SystemIndicator {
    _init() {
        super._init();
        this.toggle = new QuickSettings.QuickToggle({title: 'Touchscreen', iconName: 'input-touchpad-symbolic', toggleMode: true});
        this.toggle.accessible_name = 'Touchscreen'; // GNOME 50's tiles don't name themselves
        this.toggle.visible = false;
        this.quickSettingsItems.push(this.toggle);
        this._busy = false;
        this.toggle.connect('clicked', () => this._flip());
        this.refresh();
    }

    async refresh() {
        const r = await run([HELPER, 'touchscreen', 'status']);
        const status = r.ok ? r.out : 'none';
        this.toggle.visible = status === 'on' || status === 'off';
        this.toggle.checked = status === 'on';
        this.toggle.subtitle = status === 'off' ? 'Off' : null;
    }

    async _flip() {
        if (this._busy)
            return;
        this._busy = true;
        // toggleMode already flipped `checked`: it now holds the wanted state.
        const want = this.toggle.checked;
        const r = await run(['pkexec', HELPER, 'touchscreen', ...(want ? ['on'] : ['off', '--persist'])]);
        if (!r.ok)
            Main.notifyError('Touchscreen', r.err || 'Could not switch the touchscreen');
        await this.refresh();
        this._busy = false;
    }
});

export default class TweaksExtension extends Extension {
    enable() {
        this._settings = this.getSettings();
        this._signals = new Signals();
        this._wallpaperId = 0;
        this._background = new Gio.Settings({schema_id: 'org.gnome.desktop.background'});
        for (const key of ['picture-uri', 'picture-uri-dark'])
            this._signals.connect(this._background, `changed::${key}`, () => this._onWallpaperChanged());
        this._originalFactor = St.Settings.get().slow_down_factor;
        this._hidden = new Map(); // status-area name → container we hid

        this._signals.connect(this._settings, 'changed::animation-speed', () => this._applyAnimation());
        this._signals.connect(this._settings, 'changed::hidden-panel-items', () => this._applyHidden());
        // Indicators added later (other extensions, late-starting services) are hidden too.
        for (const box of ['_leftBox', '_centerBox', '_rightBox'].map(b => shellField(Main.panel, b, 'tweaks')).filter(Boolean))
            this._signals.connect(box, 'child-added', () => this._applyHidden());

        this._applyAnimation();
        this._applyHidden();
        this._interface = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
        for (const key of ['color-scheme', 'accent-color'])
            this._signals.connect(this._interface, `changed::${key}`, () => this._followStyle());
        this._signals.connect(this._settings, 'changed::folder-colour', () => this._followStyle());
        this._signals.connect(this._settings, 'changed::today-panel', () => this._applyToday());
        this._applyToday();
        this._signals.connect(this._settings, 'changed::clock-menu-quiet', () => this._applyQuiet());
        this._applyQuiet();
        this._events = new EventsCard(this._settings);
        this._events.enable();
        this._signals.connect(this._settings, 'changed::now-playing-pill', () => this._applyNowPlaying());
        this._applyNowPlaying();
        this._signals.connect(this._settings, 'changed::quick-settings-style', () => this._applyStyle());
        this._applyStyle();

        if (GLib.file_test(HELPER, GLib.FileTest.IS_EXECUTABLE)) {
            this._touch = new TouchscreenIndicator();
            Main.panel.statusArea.quickSettings.addExternalIndicator(this._touch);
        }
    }

    disable() {
        if (this._wallpaperId) {
            GLib.source_remove(this._wallpaperId);
            this._wallpaperId = 0;
        }
        this._quiet?.destroy();
        this._quiet = null;
        this._today?.disable();
        this._today = null;
        this._events?.disable();
        this._events = null;
        if (this._nowPlaying) { // the shortcut is bound only while the pill exists
            Main.wm.removeKeybinding('now-playing-play-pause');
            this._nowPlaying.destroy();
            this._nowPlaying = null;
        }
        this._powerRow?.destroy();
        this._powerRow = null;
        this._bluetooth?.destroy();
        this._bluetooth = null;
        this._background = null;
        this._interface = null;
        if (this._touch) {
            this._touch.quickSettingsItems.forEach(i => i.destroy());
            this._touch.destroy();
            this._touch = null;
        }
        this._signals.disconnectAll();
        St.Settings.get().slow_down_factor = this._originalFactor;
        for (const container of this._hidden.values())
            container.show();
        this._hidden.clear();
        this._settings = null;
    }

    // Folder colour (folders.js) and Yaru's light/dark pair (yaruFor), on any of their changes.
    _followStyle() {
        const theme = this._interface.get_string('icon-theme');
        const dark = this._interface.get_string('color-scheme') === 'prefer-dark';
        let scheme = null;
        try {
            const [, bytes] = GLib.file_get_contents(GLib.build_filenamev([GLib.get_user_config_dir(), 'ostrich-os', 'scheme', 'current']));
            scheme = new TextDecoder().decode(bytes).trim();
        } catch {
            // no scheme applied
        }
        const next = folderTheme({
            current: theme, choice: this._settings.get_string('folder-colour'),
            accent: this._interface.get_string('accent-color'), dark, scheme,
        }) ?? yaruFor(theme, dark);
        if (next !== theme)
            this._interface.set_string('icon-theme', next);
    }

    _applyNowPlaying() {
        const on = this._settings.get_boolean('now-playing-pill');
        if (on && !this._nowPlaying) {
            this._nowPlaying = new NowPlayingPill();
            Main.wm.addKeybinding('now-playing-play-pause', this._settings, Meta.KeyBindingFlags.NONE,
                Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW, () => this._nowPlaying?.playPause());
        } else if (!on && this._nowPlaying) {
            Main.wm.removeKeybinding('now-playing-play-pause');
            this._nowPlaying.destroy();
            this._nowPlaying = null;
        }
    }

    // 'stock' puts GNOME's quick settings back as they were (the row goes, its tile returns).
    _applyStyle() {
        const ostrich = this._settings.get_string('quick-settings-style') === 'ostrich';
        if (ostrich && !this._powerRow) {
            this._powerRow = new PowerRow();
        } else if (!ostrich && this._powerRow) {
            this._powerRow.destroy();
            this._powerRow = null;
        }
        if (ostrich && !this._bluetooth) {
            this._bluetooth = new BluetoothDevices(this._settings);
        } else if (!ostrich && this._bluetooth) {
            this._bluetooth.destroy();
            this._bluetooth = null;
        }
    }

    _applyQuiet() {
        const on = this._settings.get_boolean('clock-menu-quiet');
        if (on && !this._quiet) {
            try {
                this._quiet = new Quiet();
            } catch (e) { // a clock menu that changed shape must not stop the rest of tweaks
                console.warn(`tweaks: the clock menu's switches: ${e.message}`);
            }
        } else if (!on && this._quiet) {
            this._quiet.destroy();
            this._quiet = null;
        }
    }

    _applyToday() {
        const on = this._settings.get_boolean('today-panel');
        if (on && !this._today) {
            this._today = new Today(this._settings, argv => {
                const ours = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'libexec', 'ostrich-os', argv[0]]);
                const cmd = GLib.file_test(ours, GLib.FileTest.IS_EXECUTABLE) ? ours : argv[0];
                try {
                    Gio.Subprocess.new([cmd, ...argv.slice(1)], Gio.SubprocessFlags.NONE);
                } catch (e) {
                    console.warn(`tweaks: could not start ${cmd}: ${e.message}`);
                }
            });
            this._today.enable();
            this._quiet?.raise();
        } else if (!on && this._today) {
            this._today.disable();
            this._today = null;
        }
    }

    // A new wallpaper: if the accent was picked from the old one, pick again from the new one.
    _onWallpaperChanged() {
        if (!this._settings.get_boolean('accent-follows-wallpaper'))
            return;
        if (this._wallpaperId)
            GLib.source_remove(this._wallpaperId);
        this._wallpaperId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, WALLPAPER_SETTLE_MS, () => {
            this._wallpaperId = 0;
            const palette = readPalette();
            const fromWallpaper = palette && (palette.candidates ?? []).includes(palette.accent);
            if (fromWallpaper) {
                const theme = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'libexec', 'ostrich-os', 'ostrich-theme']);
                if (GLib.file_test(theme, GLib.FileTest.IS_EXECUTABLE))
                    run([theme, 'apply', '1']);
            }
            return GLib.SOURCE_REMOVE;
        });
    }

    _applyAnimation() {
        St.Settings.get().slow_down_factor = this._settings.get_double('animation-speed');
    }

    _applyHidden() {
        const wanted = new Set(this._settings.get_strv('hidden-panel-items'));
        // Show what's no longer listed.
        for (const [name, container] of this._hidden) {
            if (!wanted.has(name)) {
                container.show();
                this._hidden.delete(name);
            }
        }
        // Hide what's listed and present.
        for (const name of wanted) {
            const container = Main.panel.statusArea[name]?.container;
            if (container && !this._hidden.has(name)) {
                container.hide();
                this._hidden.set(name, container);
            }
        }
    }
}
