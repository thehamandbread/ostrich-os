// SPDX-License-Identifier: GPL-2.0-or-later
// quiet.js: two switches in the clock menu's right column, under the date: Do Not Disturb and Focus
// (council 2026-11-09). Each is a second handle on a state that already has one source, so the copies
// cannot drift: Do Not Disturb is GNOME's show-banners (inverted), Focus is the focus extension's
// focus-on. The quick-settings tiles stay where they are.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {shellField} from './_lib/patches.js';
import {Signals} from './_lib/signals.js';

const FOCUS = 'focus@ostrich-os';
const FOCUS_SCHEMA = 'org.gnome.shell.extensions.ostrich-os.focus';
const EXTENSION_ACTIVE = 1; // ExtensionState.ACTIVE

const focusRunning = () => Main.extensionManager.lookup(FOCUS)?.state === EXTENSION_ACTIVE;

// The focus extension's own settings, or null when they can't be read or it is too old to have focus-on.
function focusSettings() {
    try {
        const ext = Main.extensionManager.lookup(FOCUS);
        const source = Gio.SettingsSchemaSource.new_from_directory(`${ext.path}/schemas`, Gio.SettingsSchemaSource.get_default(), false);
        const schema = source.lookup(FOCUS_SCHEMA, true);
        return schema.has_key('focus-on') ? new Gio.Settings({settings_schema: schema}) : null; // an older focus extension has no such key
    } catch (e) {
        console.warn(`tweaks: focus settings: ${e.message}`);
        return null;
    }
}

function row(title, onChange) {
    const button = new St.Button({
        style_class: 'ost-quiet-row', toggle_mode: true, can_focus: true, x_expand: true,
        accessible_name: title,
    });
    const box = new St.BoxLayout({x_expand: true});
    box.add_child(new St.Label({text: title, x_expand: true, y_align: Clutter.ActorAlign.CENTER}));
    button.state = new St.Label({style_class: 'ost-quiet-state', y_align: Clutter.ActorAlign.CENTER});
    box.add_child(button.state);
    button.child = box;
    button.connect('clicked', () => onChange(button.checked));
    return button;
}

export class Quiet {
    constructor() {
        this._signals = new Signals();
        this._notifications = new Gio.Settings({schema_id: 'org.gnome.desktop.notifications'});
        const parent = shellField(Main.panel.statusArea.dateMenu, '_eventsItem', 'tweaks')?.get_parent();
        if (!parent)
            return; // the clock menu has changed shape: left as it is
        this._section = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'ost-quiet', x_expand: true});
        this._dnd = row('Do Not Disturb', on => this._notifications.set_boolean('show-banners', !on));
        this._focusRow = row('Focus', on => this._focus?.set_boolean('focus-on', on));
        this._section.add_child(this._dnd);
        this._section.add_child(this._focusRow);
        this._signals.connect(this._notifications, 'changed::show-banners', () => this._sync());
        // The focus extension may start after this one, or stop later, so its switch is checked at each open.
        this._signals.connect(Main.panel.statusArea.dateMenu.menu, 'open-state-changed', (_m, open) => open && this._sync());
        parent.insert_child_at_index(this._section, 0);
        this._sync();
    }

    // Above the other cards again (Today puts its card first when it is switched on later).
    raise() {
        this._section?.get_parent()?.set_child_at_index(this._section, 0);
    }

    _sync() {
        const show = (button, on) => {
            button.checked = on;
            button.state.text = on ? 'On' : 'Off';
        };
        show(this._dnd, !this._notifications.get_boolean('show-banners'));
        const running = focusRunning();
        if (running && !this._focus) {
            this._focus = focusSettings();
            if (this._focus)
                this._signals.connect(this._focus, 'changed::focus-on', () => this._sync());
        }
        this._focusRow.visible = running && Boolean(this._focus);
        if (this._focusRow.visible)
            show(this._focusRow, this._focus.get_boolean('focus-on'));
    }

    destroy() {
        this._signals.disconnectAll();
        this._section?.destroy();
        this._section = null;
    }
}
