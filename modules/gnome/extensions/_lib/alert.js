// SPDX-License-Identifier: GPL-2.0-or-later
// _lib/alert.js: Ostrich OS's pop-out alert, for every Ostrich system alert.
// It grows out of the top-bar item it belongs to (the monitor's readings, say) and expands into a
// card just below it: a title, one plain line on what's happening, an icon, and buttons. App
// notifications (mail, chat) stay GNOME's banners; this is for the system telling you something.
//
//   const a = new PopOut(this._indicator, {title, body, gicon, buttons: [{label, action, confirm, warn}]});
//   a.show();   // a.close() to take it back; it closes itself after STAY_MS unless hovered
//
// A button with `confirm` asks once: the first click turns it into the question (keep it short: a long
// label is cut off in the button), the second runs it. `warn` is the consequence, added to the card's
// text where it wraps, and read with the question. Motion goes through motion.js (Reduced Motion: a fade; animations off: at once), and only
// scale, position and opacity move. The card is an alert for screen readers, closes with Esc once
// it has focus (it never takes focus itself: you may be typing), and with ✕.
// Vendored into each extension at build time (see build.sh); styled by that extension's stylesheet.

import Atk from 'gi://Atk';
import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {popOut, retreat} from './motion.js';
import {placeUnder} from './place.js';

export const STAY_MS = 20000;
const WIDTH = 360;

export class PopOut {
    /**
     * @param {Clutter.Actor} source  the top-bar item it grows out of
     * @param {object} spec
     * @param {string} spec.title
     * @param {string} spec.body
     * @param {Gio.Icon} [spec.gicon]
     * @param {Array<{label: string, action: () => void, confirm?: string, warn?: string}>} [spec.buttons]
     */
    constructor(source, {title, body, gicon = null, buttons = []}) {
        this._source = source;
        this._timeoutId = 0;
        this.card = new St.BoxLayout({
            style_class: 'ost-alert', orientation: Clutter.Orientation.VERTICAL,
            reactive: true, can_focus: true, track_hover: true, width: WIDTH,
            accessible_role: Atk.Role.ALERT, accessible_name: `${title}. ${body}`,
        });
        const head = new St.BoxLayout({style_class: 'ost-alert-head'});
        if (gicon)
            head.add_child(new St.Icon({gicon, style_class: 'ost-alert-icon', y_align: Clutter.ActorAlign.CENTER}));
        head.add_child(new St.Label({text: title, style_class: 'ost-alert-title', x_expand: true, y_align: Clutter.ActorAlign.CENTER}));
        const x = new St.Button({
            style_class: 'ost-alert-close', can_focus: true, accessible_name: 'Close',
            child: new St.Icon({icon_name: 'window-close-symbolic', icon_size: 14}),
        });
        x.connect('clicked', () => this.close());
        head.add_child(x);
        this.card.add_child(head);
        this._body = new St.Label({text: body, style_class: 'ost-alert-body'});
        this._body.clutter_text.line_wrap = true;
        this.card.add_child(this._body);
        if (buttons.length > 0) {
            const row = new St.BoxLayout({style_class: 'ost-alert-buttons', x_align: Clutter.ActorAlign.END});
            for (const spec of buttons)
                row.add_child(this._button(spec));
            this.card.add_child(row);
        }
        this.card.connect('key-press-event', (_a, event) => {
            if (event.get_key_symbol() !== Clutter.KEY_Escape)
                return Clutter.EVENT_PROPAGATE;
            this.close();
            return Clutter.EVENT_STOP;
        });
        this.card.connect('notify::hover', () => this._arm());
        // Never over the lock screen: its buttons would work for anyone at the locked machine.
        this._lockId = Main.screenShield?.connect('active-changed', () => {
            if (Main.screenShield.active)
                this.destroy();
        }) ?? 0;
        this.card.connect('destroy', () => {
            this._disarm();
            if (this._lockId)
                Main.screenShield.disconnect(this._lockId);
            this._lockId = 0;
            this.card = null;
        });
    }

    _button({label, action, confirm, warn}) {
        const b = new St.Button({style_class: 'ost-alert-button', label, can_focus: true, accessible_name: label});
        let asked = false;
        b.connect('clicked', () => {
            if (confirm && !asked) {
                asked = true;
                b.label = confirm;
                b.accessible_name = warn ? `${confirm} ${warn}` : confirm;
                b.add_style_class_name('ost-alert-confirm');
                if (warn)
                    this._body.text = `${this._body.text} ${warn}`;
                return;
            }
            try {
                action();
            } finally {
                this.close();
            }
        });
        return b;
    }

    show() {
        const card = this.card;
        if (Main.sessionMode.isLocked) {
            card.destroy();
            return;
        }
        Main.layoutManager.addTopChrome(card);
        const [sx, sy] = this._source.get_transformed_position();
        const [sw, sh] = this._source.get_transformed_size();
        const src = {x: sx, y: sy, width: sw, height: sh};
        const monitor = Main.layoutManager.findMonitorForActor(this._source) ?? Main.layoutManager.primaryMonitor;
        const barBottom = Main.layoutManager.panelBox.y + Main.layoutManager.panelBox.height;
        const {x, y} = placeUnder(src, monitor, barBottom, WIDTH);
        const [, height] = card.get_preferred_height(WIDTH);
        card.set_position(x, y);
        popOut(card, this._source, {at: {x, y, width: WIDTH, height}});
        this._arm();
    }

    // Closes by shrinking back into its source.
    close() {
        const card = this.card;
        if (!card || this._closing)
            return;
        this._closing = true;
        this._disarm();
        retreat(card, this._source, {onDone: () => card.destroy()});
    }

    // Closes itself after STAY_MS, counted again whenever the pointer leaves it.
    _arm() {
        this._disarm();
        if (!this.card || this.card.hover || this._closing)
            return;
        this._timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, STAY_MS, () => {
            this._timeoutId = 0;
            this.close();
            return GLib.SOURCE_REMOVE;
        });
    }

    _disarm() {
        if (this._timeoutId)
            GLib.source_remove(this._timeoutId);
        this._timeoutId = 0;
    }

    destroy() {
        this.card?.destroy();
    }
}
