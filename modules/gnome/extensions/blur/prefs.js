// SPDX-License-Identifier: GPL-2.0-or-later
// blur/prefs.js: the Blur extension's preferences window.

import Adw from 'gi://Adw';
import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

import {group, page, spinRow, switchRow} from './_lib/prefs.js';

// [switch key, strength key, brightness key, title]
const SURFACES = [
    ['panel', 'panel-radius', 'panel-brightness', 'Top bar'],
    ['dock', 'dock-radius', 'dock-brightness', 'Dock (Ostrich Dock only)'],
    ['menus', 'menus-radius', 'menus-brightness', 'Menus and quick settings'],
    ['notifications', 'notifications-radius', 'notifications-brightness', 'Notification banners'],
    ['app-folders', 'folders-radius', 'folders-brightness', 'App folders'],
    ['overview', 'overview-radius', 'overview-brightness', 'Overview'],
];

export default class BlurPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();
        const where = group('Where to blur', 'Off means a solid colour instead of the blur.');
        const strength = group('Strength', 'How blurred and how bright each surface is.');
        for (const [on, radius, brightness, title] of SURFACES) {
            where.add(switchRow(settings, on, title));
            const expander = new Adw.ExpanderRow({title});
            expander.add_row(spinRow(settings, radius, 'Blur radius (pixels)', [1, 150, 1]));
            expander.add_row(spinRow(settings, brightness, 'Brightness', [0.3, 1.0, 0.05], 2));
            strength.add(expander);
        }
        where.add(switchRow(settings, 'lock-screen', 'Lock screen', "Blurred wallpaper on GNOME's own lock screen"));
        const other = group('Other');
        other.add(switchRow(settings, 'static-on-battery-saver', 'Lighter blur in power saver',
            'The top bar and dock blur only the wallpaper; the rest are solid black'));
        other.add(switchRow(settings, 'high-contrast', 'High contrast', 'Every surface solid, whatever the switches above say'));
        window.add(page('Blur', 'preferences-desktop-wallpaper-symbolic', [where, strength, other]));
    }
}
