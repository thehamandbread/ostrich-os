// SPDX-License-Identifier: GPL-2.0-or-later
// _lib/prefs.js: rows for an extension's own preferences window (prefs.js), bound straight to its
// GSettings so a change applies at once and the window keeps no copy.
// Vendored into each extension at build time (see build.sh).

import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';

export function group(title, description = '') {
    return new Adw.PreferencesGroup({title, description});
}

export function switchRow(settings, key, title, subtitle = '') {
    const row = new Adw.SwitchRow({title, subtitle});
    settings.bind(key, row, 'active', Gio.SettingsBindFlags.DEFAULT);
    return row;
}

// range: [min, max, step]; digits: decimals shown
export function spinRow(settings, key, title, range, digits = 0, subtitle = '') {
    const [lower, upper, step] = range;
    const row = new Adw.SpinRow({
        title, subtitle, digits,
        adjustment: new Gtk.Adjustment({lower, upper, step_increment: step, page_increment: step * 5}),
    });
    settings.bind(key, row, 'value', Gio.SettingsBindFlags.DEFAULT);
    return row;
}

// choices: [[value, label], ...] for a string key
export function choiceRow(settings, key, title, choices, subtitle = '') {
    const row = new Adw.ComboRow({title, subtitle, model: Gtk.StringList.new(choices.map(c => c[1]))});
    const sync = () => {
        const i = choices.findIndex(c => c[0] === settings.get_string(key));
        if (i >= 0 && row.selected !== i)
            row.selected = i;
    };
    sync();
    row.connect('notify::selected', () => settings.set_string(key, choices[row.selected][0]));
    const id = settings.connect(`changed::${key}`, sync);
    row.connect('destroy', () => settings.disconnect(id));
    return row;
}

export function page(title, iconName, groups) {
    const p = new Adw.PreferencesPage({title, icon_name: iconName});
    groups.forEach(g => p.add(g));
    return p;
}
