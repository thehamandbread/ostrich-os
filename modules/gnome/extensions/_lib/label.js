// SPDX-License-Identifier: GPL-2.0-or-later
// _lib/label.js: a name for an icon-only control, shown on hover and on keyboard focus. St has no
// tooltips; GNOME's dash labels its icons the same way (a `dash-label` on the top layer). The text is
// the control's accessible name by default, so what a screen reader says and what a sighted user
// reads can't drift apart. One HoverLabel serves many controls (one label on screen at a time).
// Without it the monitor's footer buttons and the drawer's top-bar icons had names only for screen
// readers.

import GLib from 'gi://GLib';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {Signals} from './signals.js';

const HOVER_MS = 500; // a pause before a hover shows it (focus shows it at once)
const GAP = 4;

export class HoverLabel {
    /**
     * @param {() => boolean} hoverOn  whether resting the pointer may show a label. The drawer's
     *                                 icons open their site on a hover pause, so they pass false then.
     */
    constructor(hoverOn = () => true) {
        this._hoverOn = hoverOn;
        this._signals = new Signals();
        this._label = new St.Label({style_class: 'dash-label', visible: false, reactive: false});
        Main.uiGroup.add_child(this._label);
        this._timeout = 0;
        this._owner = null; // the control the label is shown (or about to be shown) for
    }

    /** Label `actor` with `text()` (default: its accessible name). */
    attach(actor, text = () => actor.accessible_name) {
        this._signals.connect(actor, 'notify::hover', () => {
            if (!actor.hover)
                this._hide(actor);
            else if (this._hoverOn())
                this._later(actor, text);
        });
        this._signals.connect(actor, 'key-focus-in', () => this._show(actor, text()));
        this._signals.connect(actor, 'key-focus-out', () => this._hide(actor));
        // A click that closes its menu unmaps the control: the label goes with it. So does a control that is
        // destroyed (the drawer rebuilds its icons), which would never send another hover or focus event.
        this._signals.connect(actor, 'notify::mapped', () => {
            if (!actor.mapped)
                this._hide(actor);
        });
        this._signals.connect(actor, 'destroy', () => this._hide(actor));
    }

    _later(actor, text) {
        this._clearTimeout();
        this._owner = actor;
        this._timeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, HOVER_MS, () => {
            this._timeout = 0;
            this._show(actor, text());
            return GLib.SOURCE_REMOVE;
        });
    }

    _show(actor, text) {
        if (!text || !actor.mapped)
            return;
        this._clearTimeout();
        this._owner = actor;
        this._label.text = text;
        this._label.show();
        Main.uiGroup.set_child_above_sibling(this._label, null); // above any open menu
        const [, w] = this._label.get_preferred_width(-1);
        const [ax, ay] = actor.get_transformed_position();
        const [aw, ah] = actor.get_transformed_size();
        const mon = Main.layoutManager.findMonitorForActor(actor) ?? Main.layoutManager.primaryMonitor;
        const x = Math.max(mon.x, Math.min(ax + (aw - w) / 2, mon.x + mon.width - w));
        this._label.set_position(Math.round(x), Math.round(ay + ah + GAP));
    }

    _hide(actor) {
        if (this._owner !== actor)
            return;
        this._clearTimeout();
        this._owner = null;
        this._label.hide();
    }

    _clearTimeout() {
        if (this._timeout)
            GLib.source_remove(this._timeout);
        this._timeout = 0;
    }

    destroy() {
        this._clearTimeout();
        this._signals.disconnectAll();
        this._label.destroy();
    }
}
