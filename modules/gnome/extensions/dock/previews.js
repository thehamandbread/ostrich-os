// SPDX-License-Identifier: GPL-2.0-or-later
// dock/previews.js: thumbnails of an app's windows above its dock icon, shown after hovering.
// Live clones of the window actors (no screenshots); click one to switch to it, middle-click to
// close it. Built when shown, destroyed when hidden: nothing runs while no preview is open.
// Motion (owner, 2026-11-01): it grows up out of its icon, glides across when the pointer moves to
// another icon, and shrinks away; only scale, position and opacity move (motion.js).

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {animate, popOut, QUICK} from './_lib/motion.js';

const THUMB_W = 220;
const THUMB_H = 140;
const LEAVE_MS = 300;

export class WindowPreviews {
    constructor() {
        this._box = null;
        this._leaveId = 0;
        this._icon = null;
        this.onHidden = null; // () => void: the previews closed (the dock may hide now)
    }

    /** Shows the windows of `app` (on this workspace) above `icon`; replaces any open preview. */
    show(icon, windows) {
        // Moving from one icon's preview to another's: the new one starts where the old one was.
        const from = this._box ? this._box.x + this._box.width / 2 : null;
        this.hide();
        if (windows.length === 0)
            return;
        this._icon = icon;
        this._box = new St.BoxLayout({style_class: 'ost-dock-previews', reactive: true, track_hover: true});
        for (const win of windows) {
            const actor = win.get_compositor_private();
            if (!actor)
                continue;
            const r = win.get_frame_rect();
            const scale = Math.min(THUMB_W / r.width, THUMB_H / r.height, 1);
            const item = new St.Button({style_class: 'ost-dock-preview', can_focus: true, accessible_name: win.get_title() || icon.app.get_name()});
            const col = new St.BoxLayout({vertical: true});
            const clone = new Clutter.Clone({source: actor, width: Math.round(r.width * scale), height: Math.round(r.height * scale)});
            const title = new St.Label({text: win.get_title() ?? '', style_class: 'ost-dock-preview-title'});
            title.clutter_text.ellipsize = 3; // Pango.EllipsizeMode.END
            col.add_child(title);
            col.add_child(clone);
            item.set_child(col);
            const click = new Clutter.ClickGesture();
            click.connect('recognize', () => {
                if (click.get_button() === Clutter.BUTTON_MIDDLE) {
                    win.delete(global.get_current_time());
                    item.destroy();
                    if (this._box && this._box.get_n_children() === 0)
                        this.hide();
                } else {
                    Main.activateWindow(win);
                    this.hide();
                }
            });
            item.add_action(click);
            this._box.add_child(item);
        }
        Main.layoutManager.addTopChrome(this._box);
        this._box.connect('notify::hover', () => this._onHover());
        // Above the icon, centred on it, inside the monitor.
        const [ix, iy] = icon.get_transformed_position();
        const [iw] = icon.get_transformed_size();
        const [, natW] = this._box.get_preferred_width(-1);
        const [, natH] = this._box.get_preferred_height(natW);
        const m = Main.layoutManager.findMonitorForActor(icon) ?? Main.layoutManager.primaryMonitor;
        const x = Math.min(m.x + m.width - natW - 8, Math.max(m.x + 8, Math.round(ix + iw / 2 - natW / 2)));
        this._box.set_position(x, Math.round(iy - natH - 8));
        if (from === null) {
            // The motion template: it springs up out of its icon.
            popOut(this._box, icon, {pivot: [Math.min(1, Math.max(0, (ix + iw / 2 - x) / natW)), 1],
                at: {x, y: Math.round(iy - natH - 8), width: natW, height: natH}});
        } else {
            this._box.set({opacity: 200, translation_x: from - (x + natW / 2)});
            animate(this._box, {opacity: 255, translation_x: 0}, {duration: QUICK});
        }
    }

    get visible() {
        return !!this._box;
    }

    /** The pointer left the icon: hide soon, unless it moves onto the previews. */
    iconLeft() {
        this._scheduleHide();
    }

    _onHover() {
        if (this._box?.hover)
            this._cancelHide();
        else
            this._scheduleHide();
    }

    _scheduleHide() {
        this._cancelHide();
        this._leaveId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, LEAVE_MS, () => {
            this._leaveId = 0;
            if (!this._box?.hover && !this._icon?.hover)
                this.hide();
            return GLib.SOURCE_REMOVE;
        });
    }

    _cancelHide() {
        if (this._leaveId) {
            GLib.source_remove(this._leaveId);
            this._leaveId = 0;
        }
    }

    // `now`: no animation (a click on a preview, the extension switching off).
    hide(now = false) {
        this._cancelHide();
        const box = this._box;
        this._box = null;
        this._icon = null;
        if (!box)
            return;
        box.reactive = false;
        const gone = () => {
            Main.layoutManager.removeChrome(box);
            box.destroy();
        };
        if (now) {
            gone();
            return; // the extension switching off: nothing to tell
        }
        animate(box, {opacity: 0, scale_x: 0.9, scale_y: 0.9}, {duration: QUICK, mode: Clutter.AnimationMode.EASE_IN_QUAD, onDone: gone});
        this.onHidden?.();
    }
}
