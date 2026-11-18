// SPDX-License-Identifier: GPL-2.0-or-later
// blur/scene.js: a mirror of what's behind a surface, for blurring: the wallpaper (a real background
// actor, as the lock screen uses) and a clone of each window on the current workspace, in stacking
// order. A clone of the whole window group isn't drawn into the blur's offscreen buffer in GNOME 50
// (the surface just looked see-through); clones of single windows and a background actor are.
//
// Only windows that overlap the blurred area are cloned: a clone redraws (and re-blurs the surface)
// whenever its window draws, so a window far below the top bar would re-blur it on every hover
// highlight. Moves and resizes of the other windows on the workspace are
// still followed, so one sliding under the surface joins it.
// Window clones follow their windows (moves, resizes, stacking, minimizing, workspaces) through
// signals only. With `windows: false` it's the wallpaper alone (power saver, the overview).

import Clutter from 'gi://Clutter';
import Meta from 'gi://Meta';

import * as Background from 'resource:///org/gnome/shell/ui/background.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {Signals} from './_lib/signals.js';
import {overlaps} from './geometry.js';

export class Scene {
    /**
     * @param {Clutter.Actor} container  gets the wallpaper and the clones (fixed layout)
     * @param {number} monitorIndex
     * @param {boolean} windows  mirror the windows too (false: the wallpaper only)
     * @param {(w: Meta.Window) => boolean} [skip]  windows to leave out
     */
    constructor(container, monitorIndex, windows, skip = () => false) {
        this._skip = skip;
        this._container = container;
        this._monitor = monitorIndex;
        this._area = {x: 0, y: 0, width: 0, height: 0}; // the container, in stage coordinates
        this._signals = new Signals();
        this._winSignals = new Signals();
        this._clones = new Map(); // window actor -> clone
        this._windows = windows;
        this._bg = new Background.BackgroundManager({container, monitorIndex, controlPosition: false});
        // A new wallpaper replaces the background actor: keep it at the bottom, in place.
        this._signals.connect(this._bg, 'changed', () => {
            this._container.set_child_below_sibling(this._bg.backgroundActor, null);
            this._place();
        });
        if (windows) {
            const rebuild = () => this.rebuild();
            this._signals.connect(global.display, 'restacked', rebuild);
            this._signals.connect(global.display, 'window-created', rebuild);
            this._signals.connect(global.workspace_manager, 'active-workspace-changed', rebuild);
            // The overview hides the windows: the dock, which stays there, blurs only the wallpaper.
            this._signals.connect(Main.overview, 'showing', rebuild);
            this._signals.connect(Main.overview, 'hidden', rebuild);
            this.rebuild();
        }
        this._place();
    }

    /** The container's rectangle, in stage coordinates. */
    setArea(x, y, width, height) {
        const a = this._area;
        if (x === a.x && y === a.y && width === a.width && height === a.height)
            return;
        this._area = {x, y, width, height};
        // A sliding dock moves its area every frame: rebuild only when the windows under it change.
        const under = this._windows ? this._onWorkspace().filter(w => this._under(w)) : [];
        if (under.length !== this._clones.size || under.some(w => !this._clones.has(w)))
            this.rebuild();
        else
            this._place();
    }

    _onWorkspace() {
        if (Main.overview.visible)
            return [];
        const ws = global.workspace_manager.get_active_workspace();
        return global.get_window_actors().filter(a => {
            const w = a.meta_window;
            // An invisible window (opacity 0, e.g. while it's being hidden) would still paint in a clone.
            return a.visible && a.opacity > 0 && !w.minimized && w.get_window_type() !== Meta.WindowType.DESKTOP && !this._skip(w) &&
                (w.is_on_all_workspaces() || w.get_workspace() === ws);
        });
    }

    _under(actor) {
        return overlaps({x: actor.x, y: actor.y, width: actor.width, height: actor.height}, this._area);
    }

    rebuild() {
        const candidates = this._onWorkspace();
        const wanted = candidates.filter(a => this._under(a));
        for (const [actor, clone] of this._clones) {
            if (!wanted.includes(actor)) {
                clone.destroy();
                this._clones.delete(actor);
            }
        }
        this._winSignals.disconnectAll();
        for (const actor of wanted) {
            if (!this._clones.has(actor)) {
                const clone = new Clutter.Clone({source: actor});
                this._container.add_child(clone);
                this._clones.set(actor, clone);
            }
        }
        for (const actor of candidates) {
            // Moving into or out of the area changes the clones; moving within it only places one.
            const moved = () => {
                if (this._under(actor) !== this._clones.has(actor))
                    this.rebuild();
                else
                    this._placeClone(actor);
            };
            for (const p of ['notify::x', 'notify::y', 'notify::width', 'notify::height'])
                this._winSignals.connect(actor, p, moved);
            this._winSignals.connect(actor.meta_window, 'notify::minimized', () => this.rebuild());
            this._winSignals.connect(actor, 'destroy', () => this.rebuild());
        }
        // Stacking: the wallpaper at the bottom, then the windows bottom to top.
        let below = this._bg.backgroundActor;
        for (const actor of wanted) {
            const clone = this._clones.get(actor);
            this._container.set_child_above_sibling(clone, below);
            below = clone;
        }
        this._place();
    }

    _placeClone(actor) {
        this._clones.get(actor)?.set_position(actor.x - this._area.x, actor.y - this._area.y);
    }

    _place() {
        const m = Main.layoutManager.monitors[this._monitor] ?? Main.layoutManager.primaryMonitor;
        this._bg.backgroundActor?.set_position(m.x - this._area.x, m.y - this._area.y);
        this._bg.backgroundActor?.set_size(m.width, m.height);
        for (const actor of this._clones.keys())
            this._placeClone(actor);
        this._container.queue_relayout(); // new clones and a new wallpaper actor need an allocation
    }

    destroy() {
        this._signals.disconnectAll();
        this._winSignals.disconnectAll();
        for (const clone of this._clones.values())
            clone.destroy();
        this._clones.clear();
        this._bg.destroy();
        this._bg = null;
    }
}
