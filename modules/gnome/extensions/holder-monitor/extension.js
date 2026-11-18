// SPDX-License-Identifier: GPL-2.0-or-later
// Holder Monitor: windows on non-primary displays are left out of Alt+Tab and the window switcher.

import Meta from 'gi://Meta';

import * as AltTab from 'resource:///org/gnome/shell/ui/altTab.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {Patches} from './_lib/patches.js';

// Set to false to keep holder windows in Alt+` (the same-app / window switcher)
// while still hiding them from Alt+Tab.
const FILTER_WINDOW_SWITCHER = true;

// True while a switcher popup is building its list. The Meta.Display patch below
// only filters during that window, so the rest of the shell (focus handling,
// window management, the overview) keeps seeing every window.
let filtering = false;

function isHolderWindow(window) {
    return window.get_monitor() !== global.display.get_primary_monitor();
}

function filterHolderWindows(windows) {
    // A single display means there is no holder screen to separate out.
    if (global.display.get_n_monitors() < 2)
        return windows;

    const kept = windows.filter(w => !isHolderWindow(w));

    // If everything currently open lives on the holder screen, an empty switcher
    // would look broken and leave no way back via the keyboard, so show it all.
    return kept.length > 0 ? kept : windows;
}

// Turns `filtering` on for the duration of the wrapped call.
function whileFiltering(wrapped) {
    return function (...args) {
        filtering = true;
        try {
            return wrapped.apply(this, args);
        } finally {
            filtering = false;
        }
    };
}

export default class HolderMonitorExtension extends Extension {
    enable() {
        this._patches = new Patches();

        // altTab.js's own getWindows() helper is module-private, but every switcher
        // reaches it through display.get_tab_list(), so patching that one method
        // covers both the app switcher and the window switcher at once.
        this._patches.replace(Meta.Display.prototype, 'get_tab_list', getTabList =>
            function (type, workspace) {
                const windows = getTabList.call(this, type, workspace);
                return filtering ? filterHolderWindows(windows) : windows;
            });

        // Alt+Tab. AppSwitcher is private too, so flip the flag around the _init
        // that constructs it rather than patching the switcher list itself.
        this._patches.replace(AltTab.AppSwitcherPopup.prototype, '_init', whileFiltering);

        if (FILTER_WINDOW_SWITCHER)
            this._patches.replace(AltTab.WindowSwitcherPopup.prototype, '_getWindowList', whileFiltering);

        // GroupCyclerPopup is deliberately left alone: it cycles the focused app's
        // own windows, so filtering it would break Spotify-to-Spotify switching
        // while you're actually using the holder screen.
    }

    disable() {
        this._patches?.restoreAll();
        this._patches = null;
        filtering = false;
    }
}
