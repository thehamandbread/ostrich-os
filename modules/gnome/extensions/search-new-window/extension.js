// SPDX-License-Identifier: GPL-2.0-or-later
// New Window on Search: Enter on a running app in overview search opens a new window.

import Shell from 'gi://Shell';

import * as AppDisplay from 'resource:///org/gnome/shell/ui/appDisplay.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {Patches} from './_lib/patches.js';

// Mirrors AppIcon.activate() from appDisplay.js, minus the modifier check:
// activating a running app always gets a new window, as if Ctrl were held.
function activateAlwaysNewWindow() {
    const app = this.app;
    const openNewWindow =
        app.can_open_new_window() && app.state === Shell.AppState.RUNNING;

    if (app.state === Shell.AppState.STOPPED || openNewWindow)
        this.animateLaunch();

    if (openNewWindow)
        app.open_new_window(-1);
    else
        app.activate();

    Main.overview.hide();
}

export default class SearchNewWindowExtension extends Extension {
    enable() {
        this._patches = new Patches();

        // Search results for apps *are* AppIcon instances, and the overview
        // calls activate() on the result object directly, so overriding the
        // method per instance is enough — and it leaves the app grid and the
        // dock (which build their own AppIcons) untouched.
        this._patches.replace(AppDisplay.AppSearchProvider.prototype, 'createResultObject', wrapped =>
            function (resultMeta) {
                const result = wrapped.call(this, resultMeta);

                if (result instanceof AppDisplay.AppIcon)
                    result.activate = activateAlwaysNewWindow;

                return result;
            });
    }

    disable() {
        this._patches?.restoreAll();
        this._patches = null;
    }
}
