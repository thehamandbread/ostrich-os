// SPDX-License-Identifier: GPL-2.0-or-later
// Throwaway spike (DESIGN.md: blur). Live blur behind the top panel, built so that panel content
// updates (clock, monitor readouts, workspace bar) don't trigger a re-blur:
//   - a clone of global.window_group (wallpaper + windows), not of the stage, so the panel itself
//     is never part of the blurred input;
//   - the blur effect sits on a panel-sized, clipped container, so its offscreen buffer is only
//     monitor-width x panel-height;
//   - Shell.BlurEffect (ACTOR mode) downscales internally for large radii.
// The clone only repaints when the window group is damaged, i.e. when something behind changes.

import Clutter from 'gi://Clutter';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const RADIUS = 30;
const BRIGHTNESS = 0.6;

export default class BlurSpike extends Extension {
    enable() {
        const box = Main.layoutManager.panelBox;
        this._blur = new St.Widget({clip_to_allocation: true, reactive: false, name: 'blur-spike'});
        this._clone = new Clutter.Clone({source: global.window_group});
        this._blur.add_child(this._clone);
        this._blur.add_effect(new Shell.BlurEffect({mode: Shell.BlurMode.ACTOR, radius: RADIUS, brightness: BRIGHTNESS}));
        // Behind the panel box in the UI layer (fixed layout), not inside the box layout.
        Main.layoutManager.uiGroup.insert_child_below(this._blur, box);

        // Let the blur show through the panel.
        this._oldStyle = Main.panel.get_style();
        Main.panel.set_style('background-color: transparent;');

        this._sync = () => {
            const [x, y] = box.get_transformed_position();
            const [w, h] = box.get_size();
            this._blur.set_position(x, y);
            this._blur.set_size(w, h);
            // Clone coordinates are stage coordinates of the window group; shift so the part
            // behind the panel lines up with it.
            this._clone.set_position(-x, -y);
        };
        this._ids = [
            box.connect('notify::allocation', this._sync),
            Main.layoutManager.connect('monitors-changed', this._sync),
        ];
        this._sync();
    }

    disable() {
        const box = Main.layoutManager.panelBox;
        box.disconnect(this._ids[0]);
        Main.layoutManager.disconnect(this._ids[1]);
        Main.panel.set_style(this._oldStyle);
        this._blur.destroy();
        this._blur = this._clone = this._sync = null;
    }
}
