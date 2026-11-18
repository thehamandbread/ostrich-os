// SPDX-License-Identifier: GPL-2.0-or-later
// tweaks/corner.js: pushing the pointer into the top-right corner opens quick settings, the way the
// top-left corner opens the overview (owner, 2026-11-09). Built like GNOME 50's own HotCorner
// (layout.js): two short barriers at the corner and GNOME's PressureBarrier, with the same pressure
// and timeout, so a pointer only passing by doesn't trigger it.
// With a monitor to the right of the top-bar one, the corner moves to the outer edge of the right-most
// monitor on the same top edge; with nothing to push against there, there is no corner.

import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {PressureBarrier} from 'resource:///org/gnome/shell/ui/layout.js';

import {cornerFor} from './cornerplace.js';

const PRESSURE = 100; // px, GNOME's HOT_CORNER_PRESSURE_THRESHOLD
const TIMEOUT = 1000; // ms, GNOME's HOT_CORNER_PRESSURE_TIMEOUT

export class QuickSettingsCorner {
    constructor() {
        this._pressure = new PressureBarrier(PRESSURE, TIMEOUT, Shell.ActionMode.NORMAL);
        this._pressure.connect('trigger', () => this._open());
        this._barriers = [];
        this._monitorsId = Main.layoutManager.connect('monitors-changed', () => this._place());
        this._place();
    }

    _place() {
        this._removeBarriers();
        const corner = cornerFor(Main.layoutManager.monitors, Main.layoutManager.primaryMonitor);
        if (!corner)
            return;
        const {x, y} = corner;
        const size = Main.layoutManager.panelBox.height || 32;
        this._barriers = [
            new Meta.Barrier({
                backend: global.backend, x1: x, x2: x, y1: y, y2: y + size,
                directions: Meta.BarrierDirection.NEGATIVE_X,
            }),
            new Meta.Barrier({
                backend: global.backend, x1: x - size, x2: x, y1: y, y2: y,
                directions: Meta.BarrierDirection.POSITIVE_Y,
            }),
        ];
        for (const b of this._barriers)
            this._pressure.addBarrier(b);
    }

    _open() {
        if (Main.layoutManager.primaryMonitor?.inFullscreen)
            return;
        const menu = Main.panel.statusArea.quickSettings?.menu;
        if (menu && !menu.isOpen)
            menu.toggle(); // as a click does, with its animation
    }

    _removeBarriers() {
        for (const b of this._barriers) {
            this._pressure.removeBarrier(b);
            b.destroy();
        }
        this._barriers = [];
    }

    destroy() {
        Main.layoutManager.disconnect(this._monitorsId);
        this._removeBarriers();
        this._pressure.destroy();
    }
}
