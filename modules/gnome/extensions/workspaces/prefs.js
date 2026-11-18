// SPDX-License-Identifier: GPL-2.0-or-later
// workspaces/prefs.js: the Workspaces extension's preferences window.

import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

import {choiceRow, group, page, switchRow} from './_lib/prefs.js';

export default class WorkspacesPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();
        const look = group('The top-bar workspace bar');
        look.add(choiceRow(settings, 'indicator-style', 'Show', [['all', 'A pill for every workspace'], ['current', 'Only the current workspace']]));
        look.add(choiceRow(settings, 'active-style', 'Current workspace', [['accent', 'In the accent colour'], ['contrast', 'White on the dark top bar']]));
        look.add(switchRow(settings, 'show-empty', 'Show empty workspaces', 'The current one always shows'));
        look.add(switchRow(settings, 'show-icons', 'App icons', 'Small icons of the apps on each workspace, next to its name'));
        const behave = group('Behaviour');
        behave.add(switchRow(settings, 'smart-names', 'Smart names', 'A workspace gets the name last used for the apps on it'));
        behave.add(switchRow(settings, 'scroll-wrap', 'Scrolling wraps around', 'Scrolling past the last workspace goes back to the first'));
        window.add(page('Workspaces', 'view-grid-symbolic', [look, behave]));
    }
}
