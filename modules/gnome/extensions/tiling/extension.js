// SPDX-License-Identifier: GPL-2.0-or-later
// Tiling (replaces Tiling Assistant): halves and quarters by keyboard or by dragging a window to a
// screen edge, a popup offering windows for the rest of the screen, tiled windows that raise and
// resize together, and an optional focus outline.
//
// Geometry lives in layout.js. Costs: nothing runs while no window is being dragged. During a drag
// a pointer check runs every 50 ms, 100 ms on battery (the window stops moving at the top bar while
// the pointer goes on to the edge, so window signals alone can't see the top-edge zone).
//
// GNOME's own edge tiling and Super+arrow shortcuts are switched off while this is enabled, and
// put back as they were when it's disabled (saved in `overridden-settings`, so a crash can't lose
// them).

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {animate, stop, QUICK} from './_lib/motion.js';
import {SchemeStyle} from './_lib/scheme.js';
import {Signals} from './_lib/signals.js';
import {PowerAwareTimer} from './_lib/timers.js';
import {rectFor, zoneAt, nextTile, freeTile, followEdges} from './layout.js';

// seconds, as PowerAwareTimer takes them
const DRAG_POLL = {ac: 0.05, battery: 0.1, saver: 0.1};
const HIDDEN_APP_PREFIX = 'ostrich_os.drawer';

const KEYS = {
    'tile-left': w => ['dir', 'left', w],
    'tile-right': w => ['dir', 'right', w],
    'tile-up': w => ['dir', 'up', w],
    'tile-down': w => ['dir', 'down', w],
    'tile-top-left': w => ['tile', 'tl', w],
    'tile-top-right': w => ['tile', 'tr', w],
    'tile-bottom-left': w => ['tile', 'bl', w],
    'tile-bottom-right': w => ['tile', 'br', w],
};

// GNOME settings that clash with ours: [schema, key]. Booleans are switched off; shortcut lists
// lose only the accelerators we use.
const OVERRIDES = [
    ['org.gnome.mutter', 'edge-tiling'],
    ['org.gnome.mutter.keybindings', 'toggle-tiled-left'],
    ['org.gnome.mutter.keybindings', 'toggle-tiled-right'],
    ['org.gnome.desktop.wm.keybindings', 'maximize'],
    ['org.gnome.desktop.wm.keybindings', 'unmaximize'],
];

const MOVE_OPS = [Meta.GrabOp.MOVING, Meta.GrabOp.MOVING_UNCONSTRAINED];

function isResizeOp(op) {
    return op !== Meta.GrabOp.NONE && !MOVE_OPS.includes(op) && op !== Meta.GrabOp.KEYBOARD_MOVING;
}

function sameRect(a, b) {
    return a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;
}

function plain(r) {
    return {x: r.x, y: r.y, width: r.width, height: r.height};
}

function canTile(win) {
    return win && win.get_window_type() === Meta.WindowType.NORMAL && win.allows_resize() &&
        win.allows_move() && !win.is_fullscreen() &&
        !(win.get_gtk_application_id?.() ?? win.get_wm_class() ?? '').startsWith(HIDDEN_APP_PREFIX);
}

export default class TilingExtension extends Extension {
    enable() {
        this._scheme = new SchemeStyle(this); // the user's colour scheme, if one is applied
        this._settings = this.getSettings();
        this._signals = new Signals();
        this._tiles = new Map(); // window → {tile, rect, restore, signals}
        // Tiling stays on while locked: its fill-the-rest list (window titles you can click) mustn't
        // stay above the lock screen.
        this._signals.connect(Main.sessionMode, 'updated', () => {
            if (Main.sessionMode.isLocked)
                this._closePopup();
        });
        this._drag = null; // {win, timer, zone}
        this._resizing = null; // tiled window being resized by hand
        this._popup = null;
        this._hint = null;

        this._gsettings = new Map(); // schema id → Gio.Settings, for the overridden GNOME settings
        this._override();
        this._preview = new St.Widget({style_class: 'tile-preview', visible: false, opacity: 0});
        global.window_group.add_child(this._preview);

        for (const [name, action] of Object.entries(KEYS)) {
            Main.wm.addKeybinding(name, this._settings, Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL,
                () => this._onKey(...action(global.display.focus_window)));
        }
        this._signals.connect(global.display, 'grab-op-begin', (_d, win, op) => this._onGrabBegin(win, op));
        this._signals.connect(global.display, 'grab-op-end', (_d, win, op) => this._onGrabEnd(win, op));
        this._signals.connect(global.display, 'notify::focus-window', () => this._onFocus());
        this._signals.connect(this._settings, 'changed::focus-hint', () => this._updateHint());
        this._signals.connect(this._settings, 'changed::focus-hint-color', () => this._updateHint(true));
        this._updateHint();
    }

    disable() {
        this._scheme.destroy();
        this._scheme = null;
        for (const name of Object.keys(KEYS))
            Main.wm.removeKeybinding(name);
        this._signals.disconnectAll(); // before restoring, so the restore isn't taken over again
        this._endDrag();
        if (this._idleId)
            GLib.source_remove(this._idleId);
        this._idleId = 0;
        this._closePopup();
        this._setHint(false);
        for (const win of [...this._tiles.keys()])
            this._untrack(win);
        this._preview.destroy();
        this._preview = null;
        this._restoreOverrides();
        this._gsettings = null;
        this._settings = null;
    }

    // ---- GNOME's clashing settings ----

    _ourAccels() {
        return new Set(Object.keys(KEYS).flatMap(k => this._settings.get_strv(k)));
    }

    _override() {
        const saved = this._settings.get_string('overridden-settings');
        // After a crash the saved values are the real originals; keep them.
        const originals = saved === '' ? {} : JSON.parse(saved);
        for (const [schema, key] of OVERRIDES) {
            const s = this._gs(schema);
            const id = `${schema}|${key}`;
            if (!(id in originals))
                originals[id] = s.get_value(key).recursiveUnpack();
            this._strip(s, key);
            // Someone else put it back (e.g. Tiling Assistant restoring its own overrides as it's
            // switched off): that's the value to restore later; take it over again.
            this._signals.connect(s, `changed::${key}`, () => {
                if (this._strip(s, key, originals, id))
                    this._settings.set_string('overridden-settings', JSON.stringify(originals));
            });
        }
        this._settings.set_string('overridden-settings', JSON.stringify(originals));
    }

    _gs(schema) {
        if (!this._gsettings.has(schema))
            this._gsettings.set(schema, new Gio.Settings({schema_id: schema}));
        return this._gsettings.get(schema);
    }

    // Switches a clashing setting off; true if it had to (and records the value in `originals`).
    _strip(s, key, originals = null, id = null) {
        const v = s.get_value(key).recursiveUnpack();
        const ours = this._ourAccels();
        const clash = typeof v === 'boolean' ? v : v.some(a => ours.has(a));
        if (!clash)
            return false;
        if (originals)
            originals[id] = v;
        if (typeof v === 'boolean')
            s.set_boolean(key, false);
        else
            s.set_strv(key, v.filter(a => !ours.has(a)));
        return true;
    }

    _restoreOverrides() {
        const saved = this._settings.get_string('overridden-settings');
        if (saved === '')
            return;
        try {
            for (const [id, v] of Object.entries(JSON.parse(saved))) {
                const [schema, key] = id.split('|');
                const s = this._gs(schema);
                if (typeof v === 'boolean')
                    s.set_boolean(key, v);
                else
                    s.set_strv(key, v);
            }
        } catch (e) {
            console.warn(`tiling: could not restore GNOME settings: ${e.message}`);
        }
        this._settings.set_string('overridden-settings', '');
    }

    // ---- tiling ----

    _current(win) {
        return win.is_maximized() ? 'max' : this._tiles.get(win)?.tile ?? null;
    }

    _onKey(kind, value, win) {
        if (!canTile(win))
            return;
        const tile = kind === 'dir' ? nextTile(this._current(win), value) : value;
        if (tile === 'restore')
            this._restore(win);
        else if (tile)
            this._tile(win, tile, true);
    }

    _tile(win, tile, offerFill) {
        if (tile === 'max') {
            this._untrack(win);
            win.maximize();
            return;
        }
        const restore = this._tiles.get(win)?.restore ?? plain(win.get_frame_rect());
        if (win.is_maximized())
            win.unmaximize();
        const wa = win.get_work_area_current_monitor();
        const rect = rectFor(tile, wa, this._settings.get_uint('window-gap'));
        this._track(win, tile, rect, restore);
        win.move_resize_frame(true, rect.x, rect.y, rect.width, rect.height);
        if (offerFill && this._settings.get_boolean('fill-popup'))
            this._offerFill(win);
    }

    _restore(win) {
        if (win.is_maximized()) {
            win.unmaximize();
            return;
        }
        const entry = this._tiles.get(win);
        if (!entry)
            return;
        this._untrack(win);
        const wa = win.get_work_area_current_monitor();
        const r = entry.restore;
        const width = Math.min(r.width, wa.width), height = Math.min(r.height, wa.height);
        const x = Math.max(wa.x, Math.min(r.x, wa.x + wa.width - width));
        const y = Math.max(wa.y, Math.min(r.y, wa.y + wa.height - height));
        win.move_resize_frame(true, x, y, width, height);
    }

    _track(win, tile, rect, restore) {
        let entry = this._tiles.get(win);
        if (!entry) {
            const signals = new Signals();
            entry = {signals};
            this._tiles.set(win, entry);
            signals.connect(win, 'unmanaged', () => this._untrack(win));
            signals.connect(win, 'size-changed', () => this._onSizeChanged(win));
            signals.connect(win, 'notify::maximized-horizontally', () => {
                if (win.is_maximized())
                    this._untrack(win);
            });
        }
        Object.assign(entry, {tile, rect, restore});
    }

    _untrack(win) {
        const entry = this._tiles.get(win);
        if (!entry)
            return;
        entry.signals.disconnectAll();
        this._tiles.delete(win);
    }

    // Windows tiled on the same workspace and monitor as `win` (its tile group), not minimized.
    _group(win) {
        return [...this._tiles.keys()].filter(w => w !== win && !w.minimized &&
            w.get_workspace() === win.get_workspace() && w.get_monitor() === win.get_monitor());
    }

    // A tiled window resized by hand: neighbours sharing the moved edge follow it.
    _onSizeChanged(win) {
        const entry = this._tiles.get(win);
        if (!entry)
            return;
        const now = plain(win.get_frame_rect());
        if (sameRect(now, entry.rect))
            return;
        const before = entry.rect;
        entry.rect = now;
        if (this._resizing !== win)
            return;
        const group = this._group(win);
        const moved = followEdges(before, now, group.map(w => this._tiles.get(w).rect));
        for (const [i, r] of moved) {
            const n = group[i];
            this._tiles.get(n).rect = r;
            n.move_resize_frame(true, r.x, r.y, r.width, r.height);
        }
    }

    // ---- dragging ----

    _onGrabBegin(win, op) {
        if (isResizeOp(op) && this._tiles.has(win)) {
            this._resizing = win;
            return;
        }
        if (!MOVE_OPS.includes(op) || !canTile(win))
            return;
        // Dragging a tiled window away gives it back its own size, under the pointer.
        const entry = this._tiles.get(win);
        if (entry) {
            this._untrack(win);
            const f = win.get_frame_rect();
            const [px] = global.get_pointer();
            const r = entry.restore;
            const x = Math.round(px - (px - f.x) * r.width / Math.max(1, f.width));
            win.move_resize_frame(true, x, f.y, r.width, r.height);
        }
        if (!this._settings.get_boolean('drag-tiling'))
            return;
        this._drag = {win, zone: null};
        // why: the zone under the pointer while a window is dragged; runs only during the drag
        // (removed at grab end).
        this._drag.timer = new PowerAwareTimer(DRAG_POLL, () => this._updateZone());
        this._drag.timer.start();
    }

    _onGrabEnd(win, _op) {
        this._resizing = null;
        if (!this._drag || this._drag.win !== win)
            return;
        const zone = this._drag.zone;
        this._endDrag();
        // Let Mutter finish the grab before moving the window.
        if (zone) {
            this._idleId = GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                this._idleId = 0;
                if (canTile(win))
                    this._tile(win, zone, true);
                return GLib.SOURCE_REMOVE;
            });
        }
    }

    _updateZone() {
        const [px, py] = global.get_pointer();
        const i = global.display.get_current_monitor();
        const mon = global.display.get_monitor_geometry(i);
        const wa = Main.layoutManager.getWorkAreaForMonitor(i);
        const zone = zoneAt(px, py, mon, wa);
        if (zone === this._drag.zone)
            return;
        this._drag.zone = zone;
        if (!zone) {
            animate(this._preview, {opacity: 0}, {duration: QUICK, onDone: () => this._preview?.hide()});
            return;
        }
        const r = rectFor(zone, wa, this._settings.get_uint('window-gap'));
        const actor = this._drag.win.get_compositor_private();
        if (actor)
            global.window_group.set_child_below_sibling(this._preview, actor);
        this._preview.show();
        animate(this._preview, {x: r.x, y: r.y, width: r.width, height: r.height, opacity: 255}, {duration: QUICK});
    }

    _endDrag() {
        if (!this._drag)
            return;
        this._drag.timer.stop();
        this._drag = null;
        stop(this._preview);
        this._preview.opacity = 0;
        this._preview.hide();
    }

    // ---- fill the rest of the screen ----

    _offerFill(win) {
        const wa = win.get_work_area_current_monitor();
        const tiled = [win, ...this._group(win)];
        const tile = freeTile(tiled.map(w => this._tiles.get(w)?.rect).filter(Boolean), wa);
        if (!tile)
            return;
        const ws = global.workspace_manager.get_active_workspace();
        const all = this._settings.get_boolean('fill-popup-all-workspaces');
        const windows = global.display.get_tab_list(Meta.TabList.NORMAL_ALL, all ? null : ws)
            .filter(w => canTile(w) && !tiled.includes(w));
        if (windows.length > 0)
            this._showPopup(rectFor(tile, wa, this._settings.get_uint('window-gap')), tile, windows);
    }

    _showPopup(rect, tile, windows) {
        this._closePopup();
        const tracker = Shell.WindowTracker.get_default();
        const backdrop = new St.Widget({
            style_class: 'ost-tiling-popup', reactive: true,
            x: rect.x, y: rect.y, width: rect.width, height: rect.height,
            layout_manager: new Clutter.BinLayout(),
        });
        const list = new St.BoxLayout({
            style_class: 'ost-tiling-list', orientation: Clutter.Orientation.VERTICAL,
            x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER,
        });
        backdrop.add_child(list);
        for (const w of windows.slice(0, 12)) {
            const row = new St.BoxLayout({style_class: 'ost-tiling-row'});
            const icon = tracker.get_window_app(w)?.create_icon_texture(32) ??
                new St.Icon({icon_name: 'application-x-executable-symbolic', icon_size: 32});
            row.add_child(icon);
            row.add_child(new St.Label({text: w.get_title() ?? '', y_align: Clutter.ActorAlign.CENTER}));
            const button = new St.Button({style_class: 'ost-tiling-item', can_focus: true, child: row, x_expand: true});
            button.connect('clicked', () => this._fillWith(w, tile));
            list.add_child(button);
        }
        backdrop.connect('button-press-event', (_a, event) => {
            if (global.stage.get_event_actor(event) === backdrop)
                this._closePopup();
            return Clutter.EVENT_PROPAGATE;
        });
        backdrop.connect('key-press-event', (_a, event) => {
            const key = event.get_key_symbol();
            if (key === Clutter.KEY_Escape) {
                this._closePopup();
                return Clutter.EVENT_STOP;
            }
            const dir = {[Clutter.KEY_Up]: St.DirectionType.UP, [Clutter.KEY_Down]: St.DirectionType.DOWN}[key];
            if (dir !== undefined) {
                list.navigate_focus(global.stage.key_focus, dir, true);
                return Clutter.EVENT_STOP;
            }
            return Clutter.EVENT_PROPAGATE;
        });

        Main.uiGroup.add_child(backdrop);
        this._popup = {backdrop, grab: Main.pushModal(backdrop, {actionMode: Shell.ActionMode.POPUP})};
        list.get_first_child()?.grab_key_focus();
    }

    _closePopup() {
        if (!this._popup)
            return;
        Main.popModal(this._popup.grab);
        this._popup.backdrop.destroy();
        this._popup = null;
    }

    _fillWith(win, tile) {
        this._closePopup();
        const ws = global.workspace_manager.get_active_workspace();
        if (win.get_workspace() !== ws && !win.is_on_all_workspaces())
            win.change_workspace(ws);
        if (win.minimized)
            win.unminimize();
        win.activate(global.get_current_time());
        this._tile(win, tile, true);
    }

    // ---- raise together, focus outline ----

    _onFocus() {
        const win = global.display.focus_window;
        if (win && this._tiles.has(win) && this._settings.get_boolean('raise-together')) {
            for (const w of this._group(win))
                w.raise();
            win.raise();
        }
        this._placeHint();
    }

    _updateHint(restyle = false) {
        const on = this._settings.get_boolean('focus-hint');
        if (restyle && this._hint)
            this._setHint(false);
        this._setHint(on);
    }

    _setHint(on) {
        if (!on) {
            this._hint?.signals.disconnectAll();
            this._hint?.focusSignals.disconnectAll();
            this._hint?.actor.destroy();
            this._hint = null;
            return;
        }
        if (this._hint)
            return;
        const color = this._settings.get_string('focus-hint-color').replace(/[;{}]/g, '');
        const actor = new St.Widget({style: `border: 2px solid ${color}; border-radius: 14px;`, visible: false});
        global.window_group.add_child(actor);
        this._hint = {actor, signals: new Signals(), focusSignals: new Signals()};
        this._hint.signals.connect(global.display, 'restacked', () => this._placeHint());
        this._placeHint();
    }

    _placeHint() {
        if (!this._hint)
            return;
        const {actor, focusSignals} = this._hint;
        focusSignals.disconnectAll();
        const win = global.display.focus_window;
        const winActor = win?.get_compositor_private();
        if (!winActor || win.is_fullscreen() || win.get_window_type() !== Meta.WindowType.NORMAL) {
            actor.hide();
            return;
        }
        const place = () => {
            const f = win.get_frame_rect();
            actor.set_position(f.x - 2, f.y - 2);
            actor.set_size(f.width + 4, f.height + 4);
        };
        focusSignals.connect(win, 'position-changed', place);
        focusSignals.connect(win, 'size-changed', place);
        place();
        global.window_group.set_child_above_sibling(actor, winActor);
        actor.show();
    }
}
