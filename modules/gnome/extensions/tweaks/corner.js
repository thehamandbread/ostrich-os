// SPDX-License-Identifier: GPL-2.0-or-later
// tweaks/corner.js: pushing the pointer into the top-right corner opens quick settings, the way the
// top-left corner opens the overview (owner, 2026-11-09). It must feel exactly like GNOME 50's own
// HotCorner (layout.js, owner 2026-11-18): the same barriers, pressure, timeout and action modes, a
// second push closes, the ripple plays, and a fullscreen window on that monitor blocks it.
// With a monitor to the right of the top-bar one, the corner moves to the outer edge of the right-most
// monitor on the same top edge; with nothing to push against there, there is no corner.

import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {PressureBarrier} from 'resource:///org/gnome/shell/ui/layout.js';
import * as Ripples from 'resource:///org/gnome/shell/ui/ripples.js';

import {cornerFor} from './cornerplace.js';

const PRESSURE = 100; // px, GNOME's HOT_CORNER_PRESSURE_THRESHOLD
const TIMEOUT = 1000; // ms, GNOME's HOT_CORNER_PRESSURE_TIMEOUT

export class QuickSettingsCorner {
    constructor() {
        this._pressure = new PressureBarrier(PRESSURE, TIMEOUT, Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW);
        this._pressure.connect('trigger', () => this._toggle());
        this._ripples = new Ripples.Ripples(1.0, 0.0, 'ripple-box'); // pivot at the top-right, as GNOME's RTL corner
        this._ripples.addTo(Main.layoutManager.uiGroup);
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
        this._corner = corner;
        this._monitor = Main.layoutManager.monitors.find(m => x - 1 >= m.x && x - 1 < m.x + m.width && y >= m.y && y < m.y + m.height);
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

    // GNOME's HotCorner._toggleOverview, with quick settings in place of the overview.
    _toggle() {
        if (this._monitor?.inFullscreen && !Main.overview.visible)
            return;
        const menu = Main.panel.statusArea.quickSettings?.menu;
        if (!menu)
            return;
        menu.toggle(); // as a click does, with its animation
        this._ripples.playAnimation(this._corner.x, this._corner.y);
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
        this._ripples.destroy();
    }
}
