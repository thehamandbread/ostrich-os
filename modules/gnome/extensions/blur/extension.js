// SPDX-License-Identifier: GPL-2.0-or-later
// Blur: live blur behind the top bar, dock and drop-down menus; static blur behind the overview;
// blur behind app folders while one is open; the lock screen blurred (GNOME's own) or solid.
//
// The approach (docs/spikes/blur.md, corrected for GNOME 50):
//   - each backdrop mirrors what's behind its surface (scene.js: the wallpaper as a real background
//     actor, and a clone of each window), never the shell UI on top, so the bar or menu redrawing
//     its own content never triggers a re-blur. (A clone of the whole window group isn't drawn
//     into the blur's buffer in GNOME 50: surfaces looked see-through instead of frosted.);
//   - the blur runs on the surface's area plus a margin (the blur radius, kept on screen), so its
//     edges mix real content: a blur clipped to a 32 px top bar can only mix 32 px and looks like
//     a dark see-through strip, not frosted glass. A clipping parent the size of the surface shows
//     the middle. Shell.BlurEffect downsamples internally for large radii;
//   - it only re-renders when something behind the surface changes.
// Each surface can be switched to solid. In power saver the top bar and dock
// keep a blur of the wallpaper only (computed once, then cached), and the surfaces that would need
// live re-blurring (menus, banners, app folders, the overview) turn solid black: .ost-saver on the
// UI group, styled in the stylesheet.
//
// The extension stays enabled on the lock screen (session mode unlock-dialog) only to make the lock
// background solid when asked. On locking every live backdrop is removed first, so window content
// can never show through the top bar on the lock screen; they come back on unlock.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as AppDisplay from 'resource:///org/gnome/shell/ui/appDisplay.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as UnlockDialog from 'resource:///org/gnome/shell/ui/unlockDialog.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {Patches, shellField} from './_lib/patches.js';
import {Signals} from './_lib/signals.js';
import {BeforeRedraw, profilesProxy} from './_lib/timers.js';
import {SchemeStyle} from './_lib/scheme.js';
import {RoundedMask} from './rounded.js';
import {paddedRect} from './geometry.js';
import {Scene} from './scene.js';

const DOCK_ACTOR = 'ost-dock';
const FOLDER_EFFECT = 'ost-blur-folder';

// A blurred copy of what's behind `track`, kept under it in the UI layer.
class Backdrop {
    /**
     * @param {string} surface  the settings prefix for its strength: panel, dock or menus
     */
    // `wallpaper`: blur only the wallpaper, always (the top bar: a live bar flickered with every hover in a window under it).
    constructor(ext, track, surface, {radius = 0, watch = [], below, skip, wallpaper = false} = {}) {
        this._wallpaper = wallpaper;
        this._below = below;
        this._skip = skip;
        this._ext = ext;
        this._track = track;
        this._signals = new Signals();
        this._blurRadius = ext.settings.get_uint(`${surface}-radius`);
        // Outer: the surface's rectangle, clipping. Inner: the padded area that is blurred.
        // Fixed layouts: a widget without a layout manager never allocates its children, so the
        // clone (and with it the blur) would never be drawn and the surface would just be
        // see-through.
        this.actor = new St.Widget({
            clip_to_allocation: true, reactive: false, name: 'ost-blur-backdrop',
            layout_manager: new Clutter.FixedLayout(),
        });
        this._padded = new St.Widget({reactive: false, layout_manager: new Clutter.FixedLayout()});
        this.actor.add_child(this._padded);
        this._scene = null; // built while the surface is shown (sync), dropped while it's hidden
        this._padded.add_effect(new Shell.BlurEffect({
            mode: Shell.BlurMode.ACTOR,
            radius: this._blurRadius,
            brightness: ext.settings.get_double(`${surface}-brightness`),
        }));
        if (radius > 0)
            this.actor.add_effect(new RoundedMask(radius));

        // Only fixed-layout parents (spike lesson: a box layout parent crashed the shell).
        Main.layoutManager.uiGroup.insert_child_below(this.actor, this._topLevel(track));

        // Just before the next frame, once: from inside the layout pass (allocation changes) a move
        // or resize logged "needs an allocation" and showed a frame late.
        this._syncLater = new BeforeRedraw(() => this.sync());
        const sync = () => this._syncLater.queue();
        // Scale too: GNOME 50's menus open from 96 %, and with animations off it sets the position
        // first, so a backdrop that ignored scale stayed 4 % too small.
        for (const a of [track, ...watch]) {
            for (const p of ['allocation', 'translation-x', 'translation-y', 'scale-x', 'scale-y', 'visible', 'mapped', 'opacity'])
                this._signals.connect(a, `notify::${p}`, sync);
        }
        this._signals.connect(track, 'destroy', () => this.destroy());
        // The layout manager restacks chrome (the dock, menus) as it goes: keep the backdrop right
        // under its surface, or it covers it (the dock's icons vanished behind their own blur).
        const restack = () => this._restack();
        this._signals.connect(Main.layoutManager.uiGroup, 'child-added', restack);
        this._signals.connect(Main.layoutManager.uiGroup, 'child-removed', restack);
        // At shell shutdown the UI group destroys our actor before the surface it tracks; after
        // that it must never be touched again (a disposed-object error there kept the shell from
        // exiting, and systemd's kill made GNOME switch off every extension).
        // Connected directly (not tracked): there's nothing to disconnect once it's gone.
        this.actor.connect('destroy', () => {
            this._disposed = true;
        });
        this.sync();
    }

    // The uiGroup child that contains `actor`.
    _topLevel(actor) {
        let a = actor;
        while (a.get_parent() && a.get_parent() !== Main.layoutManager.uiGroup)
            a = a.get_parent();
        return a;
    }

    // Live: the wallpaper and the windows. Power saver (and, with static-blur-on-battery, any time on
    // battery): just the wallpaper, which never changes.
    _setSource() {
        this._scene?.destroy();
        const settings = this._ext.settings;
        const wallpaperOnly = this._wallpaper || this._ext.saver ||
            (this._ext.onBattery && settings.get_boolean('static-blur-on-battery'));
        const monitor = Math.max(0, Main.layoutManager.findIndexForActor(this._track));
        this._scene = new Scene(this._padded, monitor, !wallpaperOnly, this._skip);
    }

    refreshSource() {
        if (this._disposed || !this._scene)
            return; // not shown: sync builds it with the current source when it is
        this._setSource();
        this.sync();
    }

    _restack() {
        if (!this.actor || this._disposed)
            return;
        const ui = Main.layoutManager.uiGroup;
        const top = this._topLevel(this._track);
        if (top.get_parent() !== ui || this.actor.get_parent() !== ui)
            return;
        const kids = ui.get_children();
        if (kids.indexOf(this.actor) !== kids.indexOf(top) - 1)
            ui.set_child_below_sibling(this.actor, top);
    }

    sync() {
        if (!this.actor || this._disposed)
            return;
        const t = this._track;
        const shown = t.mapped && t.opacity > 0;
        this.actor.visible = shown;
        if (!shown) {
            // A hidden surface (a closed menu) keeps no live copy of the windows: a Scene follows
            // every window move and restack, and a day's worth of menus each kept one running.
            this._scene?.destroy();
            this._scene = null;
            return;
        }
        if (!this._scene)
            this._setSource();
        this._restack();
        const [tx, ty] = t.get_transformed_position();
        const [tw, th] = t.get_transformed_size();
        // Not laid out yet (a menu's first open): the next allocation syncs again.
        if (![tx, ty, tw, th].every(Number.isFinite))
            return;
        const r = {x: Math.round(tx), y: Math.round(ty), width: Math.round(tw), height: Math.round(th)};
        const p = paddedRect(r, this._blurRadius, global.stage, {below: this._below ?? this._blurRadius});
        this.actor.set_position(r.x, r.y);
        this.actor.set_size(r.width, r.height);
        this.actor.opacity = this._topLevel(t).opacity;
        this._padded.set_position(p.x - r.x, p.y - r.y);
        this._padded.set_size(p.width, p.height);
        this._scene.setArea(p.x, p.y, p.width, p.height);
        // Lay it out now: an unallocated backdrop isn't drawn ("needs an allocation"), and the bar
        // showed the theme's solid black until something else relaid the UI, then flipped to glass.
        this.actor.queue_relayout();
    }

    destroy() {
        if (!this.actor)
            return;
        this._syncLater.cancel();
        this._signals.disconnectAll();
        if (!this._disposed) {
            this._scene?.destroy();
            // Effects first, so their GPU buffers and shaders go now rather than whenever GJS
            // collects the JS side (the dock's backdrop, remade each time the dock is switched on,
            // grew gnome-shell by about 1 MB a time).
            this._padded.clear_effects();
            this.actor.clear_effects();
            this.actor.destroy();
        }
        this.actor = this._scene = this._padded = null;
        try {
            this.onDestroy?.();
        } catch {
            // the tagged actor may already be gone
        }
        this._ext.forget(this);
    }
}

export default class BlurExtension extends Extension {
    enable() {
        this._scheme = new SchemeStyle(this); // the user's colour scheme, if one is applied
        this.settings = this.getSettings();
        this._signals = new Signals();
        this._patches = new Patches();
        this._backdrops = new Set();
        this._menuBackdrops = new WeakMap();
        this._folders = new Set(); // app folder dialogs given a blur effect
        this._saverProfile = false;
        this.onBattery = false;

        // Light glass under the light shell style (dark text), dark glass under the dark one: the
        // stylesheet keys off this class on the UI group. GNOME reloads the theme on a switch.
        this._signals.connect(St.ThemeContext.get_for_stage(global.stage), 'changed', () => this._syncVariant());
        this._syncVariant();

        // Any setting but the lock screen's rebuilds the live surfaces.
        this._signals.connect(this.settings, 'changed', (_s, key) => {
            if (key !== 'lock-screen')
                this._rebuild();
        });
        for (const key of ['lock-screen', 'high-contrast'])
            this._signals.connect(this.settings, `changed::${key}`, () => this._styleLock());
        // GNOME's own High contrast counts as ours: glass under it made banner text 1.7:1.
        this._a11y = new Gio.Settings({schema_id: 'org.gnome.desktop.a11y.interface'});
        this._signals.connect(this._a11y, 'changed::high-contrast', () => {
            this._rebuild();
            this._styleLock();
        });
        this._signals.connect(Main.sessionMode, 'updated', () => this._rebuild());
        // Scenes and the overview copy hold monitor indexes and rects.
        this._signals.connect(Main.layoutManager, 'monitors-changed', () => this._rebuild());
        // At login GNOME zooms the whole UI group in from 75 %: backdrops placed during that sat
        // shrunk toward the middle of the screen, a stray bar, until rebuilt (owner, 2026-11-18).
        this._signals.connect(Main.layoutManager, 'startup-complete', () => this._rebuild());
        // The dock can be enabled after us.
        this._signals.connect(Main.layoutManager.uiGroup, 'child-added', (_g, child) => {
            if (child.name === DOCK_ACTOR && this._on('dock'))
                this._addDock();
        });
        this._watchProfile();
        this._watchBattery();
        this._patchMenus();
        this._patchFolders();
        this._patchLock();
        this._rebuild();
    }

    disable() {
        this._scheme.destroy();
        this._scheme = null;
        this._signals.disconnectAll();
        Main.layoutManager.uiGroup.remove_style_class_name('ost-blur-light');
        Main.layoutManager.uiGroup.remove_style_class_name('ost-saver');
        this._patches.restoreAll();
        this._clear();
        this._styleLock(true);
        this._profiles = null;
        this._upower = null;
        this.settings = null;
        this._a11y = null;
    }

    _syncVariant() {
        const ui = Main.layoutManager.uiGroup;
        if (Main.getStyleVariant() === 'light')
            ui.add_style_class_name('ost-blur-light');
        else
            ui.remove_style_class_name('ost-blur-light');
    }

    forget(backdrop) {
        this._backdrops.delete(backdrop);
    }

    _clear() {
        this._bannerSignals?.disconnectAll();
        this._bannerSignals = null;
        for (const b of [...this._backdrops])
            b.destroy();
        for (const view of this._folders) {
            view.remove_effect_by_name(FOLDER_EFFECT);
            view.remove_style_class_name(FOLDER_EFFECT);
        }
        this._folders.clear();
        this._backdrops.clear();
        this._menuBackdrops = new WeakMap();
        this._restorePanel();
        this._overview?.destroy();
        this._overview = null;
    }

    _rebuild() {
        this._clear();
        const ui = Main.layoutManager.uiGroup;
        if (this.saver)
            ui.add_style_class_name('ost-saver');
        else
            ui.remove_style_class_name('ost-saver');
        // Locked: nothing live (see the header); only the lock background is styled.
        if (Main.sessionMode.isLocked) {
            this._styleLock();
            return;
        }
        if (this._on('panel'))
            this._addPanel();
        if (this._on('dock'))
            this._addDock();
        if (this.saver)
            this._addOverview(true);
        else if (this._on('overview'))
            this._addOverview();
        if (this._on('notifications') && !this.saver)
            this._watchBanners();
    }

    // ---- notification banners: a backdrop for each banner while it's shown ----

    _watchBanners() {
        const bin = shellField(Main.messageTray, '_bannerBin', 'blur');
        if (!bin)
            return;
        const add = banner => {
            if (!banner || [...this._backdrops].some(b => b._track === banner))
                return;
            const radius = banner.get_theme_node().get_border_radius(St.Corner.TOPLEFT) || 16;
            banner.add_style_class_name('ost-blur-banner');
            const b = new Backdrop(this, banner, 'notifications', {radius, watch: [bin, Main.messageTray]});
            b.onDestroy = () => banner.remove_style_class_name?.('ost-blur-banner');
            this._backdrops.add(b);
        };
        this._bannerSignals?.disconnectAll();
        this._bannerSignals = new Signals();
        this._bannerSignals.connect(bin, 'child-added', (_b, child) => add(child));
        bin.get_children().forEach(add);
    }

    // ---- surfaces ----

    _addPanel() {
        // The bar blurs the wallpaper only, always: rendered once, never redrawn by the windows
        // under it (they made it flicker), and the cheapest on battery.
        this._backdrops.add(new Backdrop(this, Main.layoutManager.panelBox, 'panel', {below: 12, wallpaper: true}));
        Main.panel.add_style_class_name('ost-blur-bar'); // its tint: stylesheet, from the palette
    }

    _restorePanel() {
        Main.panel.remove_style_class_name('ost-blur-bar');
    }

    _addDock() {
        const dock = Main.layoutManager.uiGroup.get_children().find(a => a.name === DOCK_ACTOR);
        // The dock's visible rounded background is its Dash's background actor.
        const background = dock?.get_child?.()?._background;
        if (!background || [...this._backdrops].some(b => b._track === background))
            return;
        const b = new Backdrop(this, background, 'dock', {radius: 18, watch: [dock]});
        this._backdrops.add(b);
        // Tells the dock to use a lighter tint over the blur; removed with the backdrop.
        dock.add_style_class_name('ost-blurred');
        b.onDestroy = () => dock.remove_style_class_name('ost-blurred');
    }

    // `black`: power saver's plain black, with nothing rendered behind it.
    _addOverview(black = false) {
        // Static: a blurred copy of the wallpaper under the overview, rendered once and cached.
        const group = Main.layoutManager.overviewGroup;
        const m = Main.layoutManager.primaryMonitor;
        if (!m)
            return;
        const bg = new St.Widget({
            reactive: false, name: 'ost-blur-overview', layout_manager: new Clutter.FixedLayout(),
            x: m.x, y: m.y, width: m.width, height: m.height,
        });
        if (black) {
            bg.add_style_class_name('ost-saver-black');
            group.insert_child_at_index(bg, 0);
            this._overview = bg;
            return;
        }
        const scene = new Scene(bg, Main.layoutManager.primaryIndex, false);
        Main.layoutManager.uiGroup.add_style_class_name('ost-blur-overview-on'); // search results go glass
        bg.add_effect(new Shell.BlurEffect({
            mode: Shell.BlurMode.ACTOR,
            radius: this.settings.get_uint('overview-radius'),
            brightness: this.settings.get_double('overview-brightness'),
        }));
        group.insert_child_at_index(bg, 0);
        this._overview = bg;
        bg.connect('destroy', () => {
            Main.layoutManager.uiGroup.remove_style_class_name('ost-blur-overview-on');
            scene.destroy();
            if (this._overview === bg)
                this._overview = null;
        });
    }

    // ---- menus: attach a backdrop to each drop-down the first time it opens ----

    _patchMenus() {
        const ext = this;
        this._patches.replace(PopupMenu.PopupMenu.prototype, 'open', original => function (...args) {
            original.apply(this, args);
            try {
                ext._onMenuOpen(this);
            } catch (e) {
                console.warn(`blur: menu backdrop failed: ${e.message}`);
            }
        });
    }

    _onMenuOpen(menu) {
        if (Main.sessionMode.isLocked || !this._on('menus') || this.saver || this._menuBackdrops.has(menu))
            return;
        // Only boxpointer drop-downs that live in the UI layer (not in-place submenus).
        if (!menu._boxPointer || !menu.box)
            return;
        let top = menu.actor;
        while (top.get_parent() && top.get_parent() !== Main.layoutManager.uiGroup)
            top = top.get_parent();
        if (top.get_parent() !== Main.layoutManager.uiGroup)
            return;
        const radius = menu.box.get_theme_node().get_border_radius(St.Corner.TOPLEFT);
        menu.box.add_style_class_name('ost-blur-menu');
        // Quick settings' submenus sit beside the box, in menu.actor (an overlay): they key off this.
        menu.actor.add_style_class_name?.('ost-blur-menu-root');
        const b = new Backdrop(this, menu.box, 'menus', {radius, watch: [menu.actor]});
        // The glass tint goes with the backdrop: left on a menu whose blur was switched off, it made
        // the menu see-through instead of solid.
        b.onDestroy = () => {
            menu.box.remove_style_class_name('ost-blur-menu');
            menu.actor.remove_style_class_name?.('ost-blur-menu-root');
        };
        this._backdrops.add(b);
        this._menuBackdrops.set(menu, b);
    }

    // ---- app folders: blur what's behind the folder pop-up, only while it's open ----
    // BACKGROUND mode re-blurs the stage behind the dialog each frame, but the effect only runs
    // while the dialog is mapped, which is while the user is in it.

    _patchFolders() {
        const ext = this;
        this._patches.replace(AppDisplay.AppFolderDialog.prototype, 'popup', original => function (...args) {
            const r = original.apply(this, args);
            try {
                ext._onFolderOpen(this);
            } catch (e) {
                console.warn(`blur: folder blur failed: ${e.message}`);
            }
            return r;
        });
    }

    _onFolderOpen(dialog) {
        const view = dialog._viewBox;
        if (!view || this._folders.has(view) || !this._on('app-folders') || this.saver || Main.sessionMode.isLocked)
            return;
        // Brightness defaults to full: BACKGROUND blur fills the dialog's whole rectangle (a mask
        // can't wrap it: the blur would then read the mask's empty buffer), so the corners outside
        // the rounded dialog show the already-dimmed backdrop, only blurred, and blend in.
        view.add_effect_with_name(FOLDER_EFFECT, new Shell.BlurEffect({
            mode: Shell.BlurMode.BACKGROUND,
            radius: this.settings.get_uint('folders-radius'),
            brightness: this.settings.get_double('folders-brightness'),
        }));
        view.add_style_class_name(FOLDER_EFFECT);
        this._folders.add(view);
        this._signals.connect(view, 'destroy', () => this._folders.delete(view));
    }

    // ---- lock screen: GNOME's blurred wallpaper (blur) or a solid palette colour ----

    _patchLock() {
        const ext = this;
        this._patches.replace(UnlockDialog.UnlockDialog.prototype, '_updateBackgroundEffects', original => function (...args) {
            original.apply(this, args);
            try {
                ext._styleLock(false, this);
            } catch (e) {
                console.warn(`blur: lock screen style failed: ${e.message}`);
            }
        });
    }

    _styleLock(reset = false, dialog = Main.screenShield?._dialog) {
        const group = dialog?._backgroundGroup;
        if (!group)
            return;
        const solid = !reset && this.settings && !this._on('lock-screen');
        for (const widget of group) {
            const effect = widget.get_effect('blur');
            if (effect)
                effect.enabled = !solid;
            for (const child of widget)
                child.visible = !solid;
            // The scheme's neutral solid colour (stylesheet), not the accent.
            if (solid)
                widget.add_style_class_name('ost-solid');
            else
                widget.remove_style_class_name('ost-solid');
        }
    }

    // A surface is blurred when its switch is on, unless high-contrast (ours or GNOME's) is: then every
    // surface is solid (the per-surface switches are left as they are, so turning it off puts them back).
    _on(surface) {
        return this.settings.get_boolean(surface) && !this.settings.get_boolean('high-contrast') &&
            !this._a11y?.get_boolean('high-contrast');
    }

    // ---- power saver ----

    // The power-saver rule is on: power saver is the mode, and its switch (static-on-battery-saver)
    // is on. Any setting change rebuilds, so the switch takes effect at once.
    get saver() {
        return this._saverProfile && (this.settings?.get_boolean('static-on-battery-saver') ?? false);
    }

    // On battery or not (UPower's OnBattery), for static-blur-on-battery: an experiment, off by
    // default, kept only if it saves measurable power on real hardware.
    _watchBattery() {
        Gio.DBusProxy.new_for_bus(Gio.BusType.SYSTEM, Gio.DBusProxyFlags.DO_NOT_AUTO_START, null,
            'org.freedesktop.UPower', '/org/freedesktop/UPower', 'org.freedesktop.UPower', null, (_o, res) => {
                let p = null;
                try {
                    p = Gio.DBusProxy.new_for_bus_finish(res);
                } catch {
                    return; // no UPower: never on battery
                }
                if (!p.get_name_owner() || !this.settings)
                    return;
                this._upower = p;
                const read = () => {
                    const on = p.get_cached_property('OnBattery')?.unpack() === true;
                    if (on === this.onBattery)
                        return;
                    this.onBattery = on;
                    if (this.settings.get_boolean('static-blur-on-battery')) {
                        for (const b of this._backdrops)
                            b.refreshSource();
                    }
                };
                this._signals.connect(p, 'g-properties-changed', read);
                read();
            });
    }

    async _watchProfile() {
        const p = await profilesProxy(null);
        if (!p || !this.settings)
            return;
        this._profiles = p;
        const read = () => {
            const saver = p.get_cached_property('ActiveProfile')?.unpack() === 'power-saver';
            if (saver !== this._saverProfile) {
                this._saverProfile = saver;
                this._rebuild(); // which surfaces have a backdrop changes, not only their source
            }
        };
        this._signals.connect(p, 'g-properties-changed', read);
        read();
    }
}
