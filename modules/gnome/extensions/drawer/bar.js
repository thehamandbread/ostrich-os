// SPDX-License-Identifier: GPL-2.0-or-later
// drawer/bar.js: Ostrich Drawer's top-bar icons.
//
// One icon per site in the bar (the host's state "bar": pinned sites, or an environment's set),
// up to `bar-max`; the rest, and every other site, are in the ⌄ menu. The + after them adds a site
// (an address, a name, or one of the recommended ones). An icon shows the site's
// favicon, an unread badge, and a dot while the site is loaded (dimmed when it isn't).
// Left click or hover opens the site (the extension decides; see extension.js), right click opens
// the site's menu. Each icon is a status-area item with the role `drawer@ubuntu-ostrich-<id>`, so
// focus mode hides them like the other top-bar items.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as Dialog from 'resource:///org/gnome/shell/ui/dialog.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as ModalDialog from 'resource:///org/gnome/shell/ui/modalDialog.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {badgeText, splitBar, inside} from './barlogic.js';
import {HoverLabel} from './_lib/label.js';

export const ROLE = 'drawer@ubuntu-ostrich-';
const MORE_ROLE = `${ROLE}-more`; // site ids never start with '-'
const ADD_ROLE = `${ROLE}-add`;

function giconFor(icon) {
    if (icon?.startsWith('/'))
        return Gio.FileIcon.new(Gio.File.new_for_path(icon));
    return Gio.ThemedIcon.new(icon || 'web-browser-symbolic');
}

const SiteButton = GObject.registerClass(
class SiteButton extends PanelMenu.Button {
    _init(site, bar) {
        super._init(0.5, site.name, false);
        this._bar = bar;
        this.siteId = site.id;
        this.add_style_class_name('ost-drawer-site');
        const box = new St.Widget({layout_manager: new Clutter.BinLayout(), y_expand: true});
        this._icon = new St.Icon({style_class: 'system-status-icon', y_align: Clutter.ActorAlign.CENTER});
        this._badge = new St.Label({
            style_class: 'ost-drawer-badge', visible: false,
            x_align: Clutter.ActorAlign.END, y_align: Clutter.ActorAlign.START,
        });
        this._dot = new St.Widget({
            style_class: 'ost-drawer-dot',
            x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.END,
        });
        // A speaker while the site plays sound (the host's state "playing"), in the bottom-right
        // corner, on an accent disc so it reads over any favicon (note 20261102-014728).
        this._playing = new St.Icon({
            icon_name: 'audio-volume-high-symbolic', style_class: 'ost-drawer-playing', visible: false,
            x_align: Clutter.ActorAlign.END, y_align: Clutter.ActorAlign.END,
        });
        box.add_child(this._icon);
        box.add_child(this._playing);
        box.add_child(this._badge);
        box.add_child(this._dot);
        this.add_child(box);
        // GNOME 50's panel buttons open their menu from a click gesture; ours: the left button
        // (or a tap) opens or folds the site, the right button opens the site's menu.
        this._clickGesture.set_enabled(false);
        const primary = new Clutter.ClickGesture({recognize_on_press: true, required_button: Clutter.BUTTON_PRIMARY});
        primary.connect('recognize', () => {
            this.menu.close();
            this._bar.clicked(this.siteId);
        });
        this.add_action(primary);
        const secondary = new Clutter.ClickGesture({recognize_on_press: true, required_button: Clutter.BUTTON_SECONDARY});
        secondary.connect('recognize', () => {
            this._fillMenu();
            this.menu.toggle();
        });
        this.add_action(secondary);
        this.connect('notify::hover', () => {
            if (this.hover)
                this._bar.hoverEnter(this.siteId);
            else
                this._bar.hoverLeave(this.siteId);
        });
        // Moving over the icon restarts the hover delay: only a real pause opens the site.
        this.connect('motion-event', () => {
            this._bar.hoverMove(this.siteId);
            return Clutter.EVENT_PROPAGATE;
        });
        this.update(site);
    }

    update(site, open = false) {
        this._site = site;
        // The open site's icon keeps one steady look while it's open (not hover flicker).
        if (open)
            this.add_style_pseudo_class('checked');
        else
            this.remove_style_pseudo_class('checked');
        if (site.icon !== this._iconName) {
            this._iconName = site.icon;
            this._icon.gicon = giconFor(site.icon);
        }
        const badge = badgeText(site.unread);
        this._badge.text = badge;
        this._badge.visible = badge !== '';
        this._dot.visible = site.loaded;
        this._playing.visible = Boolean(site.playing);
        this._icon.opacity = site.loaded ? 255 : 153;
        // Says what the icon is (a site in a drop-down panel), not just its name.
        this.accessible_name = `${site.name} (opens in a panel)${site.playing ? ', playing sound' : ''}${badge ? `, ${site.unread} unread` : ''}`;
    }

    _fillMenu() {
        const s = this._site;
        const host = this._bar.host;
        const sb = on => new GLib.Variant('(sb)', [s.id, on]);
        const str = new GLib.Variant('s', s.id);
        this.menu.removeAll();
        if (s.loaded) {
            this.menu.addAction('Close (unload to free memory)', () => host.activate('unload', str));
            this.menu.addAction('Back', () => host.activate('back', str));
            this.menu.addAction('Reload', () => host.activate('reload', str));
        } else {
            this.menu.addAction('Load', () => host.activate('load', str));
        }
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        const toggle = (label, on, action) => {
            const item = new PopupMenu.PopupSwitchMenuItem(label, on);
            item.connect('toggled', (_i, state) => host.activate(action, sb(state)));
            this.menu.addMenuItem(item);
        };
        // What a loaded site costs (the host's estimate), and its warning on a small machine.
        toggle(`Keep loaded in the background${s.mb ? ` (about ${s.mb} MB)` : ''}`, s.keep, 'keep');
        const warning = this._bar.state?.memWarning;
        if (warning)
            this.menu.addMenuItem(new PopupMenu.PopupMenuItem(warning, {reactive: false}));
        toggle('Mute notifications', s.muted, 'mute-site');
        toggle('Pin to the top bar', s.pinned, 'pin');
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        // Removing asks first, in a small dialog (a submenu for it made the menu heavy).
        this.menu.addAction(`Remove ${s.name}…`, () => confirmRemove(s.name, () => host.activate('remove', str)));
    }
});

// "Remove NAME from the drawer?" Remove / Cancel; Cancel is the default (Esc, Enter).
function confirmRemove(name, remove) {
    const dialog = new ModalDialog.ModalDialog({styleClass: 'ost-drawer-remove'});
    dialog.contentLayout.add_child(new Dialog.MessageDialogContent({
        title: `Remove ${name} from the drawer?`,
        description: 'Its icon leaves the top bar. You can add it again from the + menu.',
    }));
    dialog.addButton({label: 'Cancel', action: () => dialog.close(), key: Clutter.KEY_Escape, default: true});
    dialog.addButton({
        label: 'Remove',
        action: () => {
            dialog.close();
            remove();
        },
    });
    dialog.open();
}

const GROUPS = [['messaging', 'Messaging'], ['ai', 'AI'], ['mail', 'Mail & calendar'], ['media', 'Media & notes']];

// + : add a site by address or name, or pick a recommended one.
const AddButton = GObject.registerClass(
class AddButton extends PanelMenu.Button {
    _init(bar) {
        super._init(0.5, 'Add a site', false);
        this._bar = bar;
        this.add_child(new St.Icon({icon_name: 'list-add-symbolic', style_class: 'system-status-icon'}));
        // Filled now, not on opening: GNOME won't open an empty menu, so a menu filled from its own
        // open signal never opens at all (the + did nothing).
        this._fill();
        this.menu.connect('open-state-changed', (_m, open) => {
            if (!open) {
                this._status.visible = false;
                return;
            }
            // After the menu manager has focused the menu itself (its handler runs after this one),
            // so typing goes straight into the address field.
            this._focusId = GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                this._focusId = 0;
                if (this.menu.isOpen)
                    global.stage.set_key_focus(this._entry);
                return GLib.SOURCE_REMOVE;
            });
        });
        this.connect('destroy', () => {
            if (this._focusId)
                GLib.source_remove(this._focusId);
        });
    }

    _fill() {
        this.menu.removeAll();
        this._recommended = JSON.stringify(this._bar.state?.recommended ?? []);
        const entryItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        const entry = new St.Entry({
            hint_text: 'Add a site: address or name',
            can_focus: true, x_expand: true, style_class: 'ost-drawer-add-entry',
        });
        this._entry = entry;
        entry.clutter_text.connect('activate', () => {
            const text = entry.get_text().trim();
            if (text)
                this._submit(text, text);
        });
        entryItem.add_child(entry);
        this.menu.addMenuItem(entryItem);
        // What an add did. A plain label, not a menu item: GNOME greys out items that can't be
        // activated, and this has to be readable.
        const statusSection = new PopupMenu.PopupMenuSection();
        this._status = new St.Label({style_class: 'ost-drawer-add-status', visible: false});
        this._status.clutter_text.line_wrap = true;
        statusSection.actor.add_child(this._status);
        this.menu.addMenuItem(statusSection);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem('Recommended'));
        const rec = this._bar.state?.recommended ?? [];
        for (const [group, title] of GROUPS) {
            const sub = new PopupMenu.PopupSubMenuMenuItem(title);
            for (const r of rec.filter(x => x.group === group)) {
                // A DRM site can't play in the drawer: it opens in its own app or the browser.
                const label = r.drm ? `${r.name} (opens in ${r.app ? 'its app' : 'your browser'})` : r.name;
                const item = new PopupMenu.PopupMenuItem(label);
                if (r.added)
                    item.setOrnament(PopupMenu.Ornament.CHECK);
                if (r.added) {
                    item.reactive = false;
                    item.add_style_pseudo_class('insensitive');
                }
                item.connect('activate', () => (r.drm ? this._elsewhere(r) : this._submit(r.id, r.name)));
                sub.menu.addMenuItem(item);
            }
            this.menu.addMenuItem(sub);
        }
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this.menu.addAction('Sites and settings…', () => this._bar.openSettings());
    }

    // Asks the drawer to add `what` (an address or a recommended id); `label` names it meanwhile.
    _submit(what, label) {
        this._pending = label;
        if (this._bar.host.activate('add', new GLib.Variant('s', what))) {
            this._entry.set_text('');
        } else {
            this._showStatus("The drawer isn't running. Open it with Super+Alt+D, then try again.");
        }
    }

    // A DRM site, in its own app or the browser (the drawer opens it; see ostrich-drawer).
    _elsewhere(r) {
        if (!this._bar.host.activate('elsewhere', new GLib.Variant('s', r.id)))
            this._showStatus("The drawer isn't running. Open it with Super+Alt+D, then try again.");
    }

    _showStatus(text) {
        this._status.text = text;
        this._status.visible = true;
    }

    /** A new state: the recommended list (what's added) when it changed, and what an add did. */
    update(state, before) {
        if (!this.menu.isOpen) {
            if (JSON.stringify(state.recommended ?? []) !== this._recommended)
                this._fill();
            return;
        }
        if (state.lastError && state.errorCount !== before?.errorCount) {
            this._showStatus(state.lastError);
        } else if (state.lastAdded && state.lastAdded !== before?.lastAdded) {
            const site = state.sites.find(x => x.id === state.lastAdded);
            const name = site?.name ?? this._pending ?? 'the site';
            this._showStatus(Gio.NetworkMonitor.get_default().network_available
                ? `Added ${name}`
                : `Added ${name}. You're offline, so it will load when you're back online.`);
        }
    }
});

const MoreButton = GObject.registerClass(
class MoreButton extends PanelMenu.Button {
    _init(bar) {
        super._init(0.5, 'More sites', false);
        this._bar = bar;
        this.add_child(new St.Icon({icon_name: 'pan-down-symbolic', style_class: 'system-status-icon'}));
        this.menu.connect('open-state-changed', (_m, open) => {
            if (open)
                this._fill();
        });
    }

    _fill() {
        this.menu.removeAll();
        for (const s of this._bar.sites) {
            const badge = badgeText(s.unread);
            const label = `${s.name}${s.playing ? '  🔊' : ''}${badge ? `  (${badge})` : ''}`;
            const item = new PopupMenu.PopupImageMenuItem(label, giconFor(s.icon));
            item.connect('activate', () => this._bar.open(s.id));
            this.menu.addMenuItem(item);
        }
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this.menu.addAction('Add a site…', () => this._bar.openAdd());
        this.menu.addAction('Sites and settings…', () => this._bar.openSettings());
    }
});

export class DrawerBar {
    /**
     * @param {object} ext  {host: {activate(name, variant)}, settings, clicked(id), open(id),
     *                       hoverEnter(id), hoverLeave(id), openSettings()}
     */
    constructor(ext) {
        this._ext = ext;
        this.host = ext.host;
        this.sites = [];
        // Names for the icons (council M4). Hovering already opens a site after a pause, so a hover label
        // shows only when hover-to-open is off; keyboard focus always shows it.
        this._labels = new HoverLabel(() => !this._ext.settings.get_boolean('open-on-hover'));
        this._buttons = new Map(); // id -> SiteButton
        this._more = null;
        this._add = null;
        this._order = '';
        this.state = null;
    }

    clicked(id) {
        this._ext.clicked(id);
    }

    open(id) {
        this._ext.open(id);
    }

    hoverEnter(id) {
        this._ext.hoverEnter(id);
    }

    hoverLeave(id) {
        this._ext.hoverLeave(id);
    }

    hoverMove(id) {
        this._ext.hoverMove(id);
    }

    openSettings() {
        this._ext.openSettings();
    }

    openAdd() {
        this._add?.menu.open();
    }

    /** The host's state, or null when it isn't running (no icons then). */
    update(state) {
        const before = this.state;
        this.state = state;
        this.sites = state?.sites ?? [];
        const byId = new Map(this.sites.map(s => [s.id, s]));
        const {shown} = splitBar((state?.bar ?? []).filter(id => byId.has(id)), this._ext.settings.get_uint('bar-max'));
        const more = this.sites.length > shown.length;
        const order = `${shown.join(' ')}|${more}|${!!state}`;
        if (order !== this._order) {
            this._clear(!state);
            this._order = order;
            shown.forEach((id, i) => {
                const b = new SiteButton(byId.get(id), this);
                b.update(byId.get(id), !!state?.shown && state?.active === id);
                this._labels.attach(b);
                this._buttons.set(id, b);
                Main.panel.addToStatusArea(`${ROLE}${id}`, b, i, 'right');
            });
            if (more) {
                this._more = new MoreButton(this);
                this._labels.attach(this._more);
                Main.panel.addToStatusArea(MORE_ROLE, this._more, shown.length, 'right');
            }
            // The + is kept across rebuilds (destroying it would close its menu just as a site it
            // added appears) and only moved after the icons.
            const addAt = shown.length + (more ? 1 : 0);
            if (state && !this._add) {
                this._add = new AddButton(this);
                this._labels.attach(this._add);
                Main.panel.addToStatusArea(ADD_ROLE, this._add, addAt, 'right');
            } else if (this._add) {
                const box = this._add.container.get_parent();
                box?.set_child_at_index(this._add.container, addAt);
            }
        } else {
            for (const [id, b] of this._buttons)
                b.update(byId.get(id), !!state?.shown && state?.active === id);
        }
        if (state)
            this._add?.update(state, before);
    }

    /** The icon actor for a site, if it has one in the bar. */
    buttonFor(id) {
        return this._buttons.get(id) ?? null;
    }

    /** Is a screen point over one of the drawer's top-bar icons? */
    contains(x, y) {
        for (const b of [...this._buttons.values(), this._more, this._add]) {
            if (!b?.visible)
                continue;
            const [bx, by] = b.get_transformed_position();
            const [w, h] = b.get_transformed_size();
            if (inside({x: bx, y: by, width: w, height: h}, x, y))
                return true;
        }
        return false;
    }

    // The site icons and ⌄ go; the + too when `all` (the drawer stopped, or the bar is going).
    _clear(all = true) {
        for (const b of this._buttons.values())
            b.destroy();
        this._buttons.clear();
        this._more?.destroy();
        this._more = null;
        if (!all)
            return;
        this._add?.destroy();
        this._add = null;
        this._order = '';
    }

    destroy() {
        this._clear();
        this._labels.destroy();
    }
}
