// SPDX-License-Identifier: GPL-2.0-or-later
// monitor/prefs.js: the Monitor extension's preferences window.

import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

import {group, page, spinRow, switchRow} from './_lib/prefs.js';

export default class MonitorPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();
        const popup = group('The popup');
        popup.add(switchRow(settings, 'hide-zeros', 'Hide zero readings', 'Leave out idle fans and quiet networks in the popup and the top bar'));
        popup.add(spinRow(settings, 'section-rows', 'Rows an open section shows', [3, 40, 1], 0, 'Then it scrolls (6 is compact, 12 is tall)'));
        const speed = group('How often it reads', 'Seconds between updates. In power saver only the memory check still runs.');
        speed.add(spinRow(settings, 'interval-ac', 'On AC power', [1, 60, 1]));
        speed.add(spinRow(settings, 'interval-battery', 'On battery', [1, 120, 1]));
        speed.add(spinRow(settings, 'interval-saver', 'In power saver', [1, 300, 1]));
        const power = group('Power');
        power.add(spinRow(settings, 'auto-saver-percent', 'Switch to power saver at', [0, 50, 1], 0,
            'Percent charge on battery; 0 never. It goes back to the previous mode when you plug in, and leaves a saver you or GNOME already chose alone.'));
        power.add(switchRow(settings, 'saver-desktop', 'Dim the screen sooner in power saver'));
        power.add(switchRow(settings, 'memory-warning', 'Warn when memory is nearly full', 'Once, naming the app using the most'));
        window.add(page('Monitor', 'utilities-system-monitor-symbolic', [popup, speed, power]));
    }
}
