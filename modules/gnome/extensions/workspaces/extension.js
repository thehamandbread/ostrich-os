// SPDX-License-Identifier: GPL-2.0-or-later
// Workspaces: a workspace bar in place of the Activities button (what Space Bar does, and more).
//
//   - a bold pill per workspace with its name or number; the active one filled, empty ones faded;
//   - click to switch, click the active one for the overview, scroll over the bar to move;
//   - drag a pill to reorder workspaces; drop a window (from the overview) on a pill to move it;
//   - right-click: rename, new workspace, move left/right, remove;
//   - shortcuts: Super+Alt+N new, Super+Alt+R rename, Super+Alt+Page Up/Down move the workspace;
//   - options: hide empty workspaces, show only the current one, small app icons per workspace.
// Names live in GNOME's own org.gnome.desktop.wm.preferences workspace-names. Smart names (names.js)
// give an unnamed workspace the name last used for the apps on it. Event-driven: no timers.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GObject from 'gi://GObject';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as DND from 'resource:///org/gnome/shell/ui/dnd.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {SchemeStyle} from './_lib/scheme.js';
import {Signals} from './_lib/signals.js';
import {ScrollGate} from './scroll.js';
import {accessibleName, associate, label, moveName, parseMap, removeName, smartName, visibleIndexes} from './names.js';

const WM_PREFS = 'org.gnome.desktop.wm.preferences';
const MAX_ICONS = 3; // app icons per pill, when shown

// The normal windows on a workspace.
function normalWindows(ws) {
    return ws.list_windows().filter(w => !w.is_on_all_workspaces() && !w.skip_taskbar &&
        w.get_window_type() === Meta.WindowType.NORMAL);
}

// Window classes of the normal windows on a workspace (what smart names associate with).
function windowClasses(ws) {
    return normalWindows(ws).map(w => w.get_wm_class()).filter(Boolean);
}

const Bar = GObject.registerClass(
class WorkspacesBar extends PanelMenu.Button {
    _init(extension) {
        super._init(0.0, 'Workspaces', true);
        this._settings = extension.getSettings();
        this._wm = new Gio.Settings({schema_id: WM_PREFS});
        this._signals = new Signals();
        this._wsSignals = new Signals();
        this._menuManager = new PopupMenu.PopupMenuManager(this);
        this._menu = null;
        this.add_style_class_name('ost-ws-panel-button');

        this._box = new St.BoxLayout({style_class: 'ost-ws-bar'});
        this.add_child(this._box);
        // At shell shutdown the panel goes before the windows: stop restyling buttons that are gone.
        this._box.connect('destroy', () => {
            this._signals.disconnectAll();
            this._wsSignals.disconnectAll();
            this._buttons = [];
        });

        const wsm = global.workspace_manager;
        for (const s of ['notify::n-workspaces', 'workspaces-reordered'])
            this._signals.connect(wsm, s, () => this._rebuild());
        this._signals.connect(wsm, 'active-workspace-changed', () => this._restyle());
        this._signals.connect(this._wm, 'changed::workspace-names', () => {
            this._relabel();
            this._restyle(); // the accessible names
        });
        for (const key of ['active-style', 'show-empty', 'indicator-style', 'show-icons'])
            this._signals.connect(this._settings, `changed::${key}`, () => this._restyle());
        this._signals.connect(global.display, 'notify::focus-window', () => this._restyle());
        this._signals.connect(this, 'scroll-event', (_a, event) => this._onScroll(event));

        this._rebuild();
    }

    _names() {
        return this._wm.get_strv('workspace-names');
    }

    _setNames(names) {
        const list = [...names];
        while (list.length > 0 && list.at(-1) === '')
            list.pop();
        this._wm.set_strv('workspace-names', list);
    }

    _setName(index, name) {
        const names = this._names();
        while (names.length <= index)
            names.push('');
        names[index] = name;
        this._setNames(names);
    }

    _rebuild() {
        this._closeMenu();
        this._wsSignals.disconnectAll();
        this._box.destroy_all_children();
        this._buttons = [];
        const wsm = global.workspace_manager;
        for (let i = 0; i < wsm.get_n_workspaces(); i++) {
            const ws = wsm.get_workspace_by_index(i);
            this._buttons.push(this._makeButton(ws));
            for (const s of ['window-added', 'window-removed']) {
                this._wsSignals.connect(ws, s, () => {
                    if (s === 'window-added')
                        this._applySmartName(ws);
                    this._restyle();
                });
            }
        }
        this._relabel();
        this._restyle();
    }

    _makeButton(ws) {
        const button = new St.Button({style_class: 'ost-ws-button', can_focus: true, y_align: Clutter.ActorAlign.CENTER});
        const content = new St.BoxLayout({style_class: 'ost-ws-content'});
        const icons = new St.BoxLayout({style_class: 'ost-ws-icons'});
        const text = new St.Label({y_align: Clutter.ActorAlign.CENTER});
        content.add_child(text);
        content.add_child(icons);
        button.set_child(content);
        const entry = {button, ws, text, icons};

        // Left: switch, or the overview when it's already the active one. Right: the menu.
        // St.Button's own click, as GNOME's app icons do: a separate click gesture on a draggable
        // button never got the press (the drag gesture took it), so clicks did nothing.
        button.connect('clicked', () => {
            if (ws === global.workspace_manager.get_active_workspace())
                Main.overview.toggle();
            else
                ws.activate(global.get_current_time());
        });
        const right = new Clutter.ClickGesture({required_button: Clutter.BUTTON_SECONDARY, recognize_on_press: true});
        right.connect('recognize', () => this._openMenu(entry));
        button.add_action(right);

        // Drag a pill to reorder; drop a pill or a window on one.
        button._delegate = {
            ws,
            getDragActor: () => new St.Label({text: text.text, style_class: 'ost-ws-button ost-ws-dragging'}),
            getDragActorSource: () => button,
            handleDragOver: source => source?.ws || source?.metaWindow
                ? DND.DragMotionResult.MOVE_DROP : DND.DragMotionResult.CONTINUE,
            acceptDrop: source => this._acceptDrop(ws, source),
        };
        DND.makeDraggable(button, {restoreOnSuccess: false});

        this._box.add_child(button);
        return entry;
    }

    _acceptDrop(ws, source) {
        if (source?.ws && source.ws !== ws) {
            this._moveWorkspace(source.ws, ws.index());
            return true;
        }
        if (source?.metaWindow) {
            source.metaWindow.change_workspace(ws);
            return true;
        }
        return false;
    }

    _relabel() {
        const names = this._names();
        for (const {text, ws} of this._buttons)
            text.text = label(names, ws.index());
    }

    _restyle() {
        const wsm = global.workspace_manager;
        const active = wsm.get_active_workspace();
        const accent = this._settings.get_string('active-style') === 'accent';
        const showIcons = this._settings.get_boolean('show-icons');
        const visible = new Set(visibleIndexes({
            count: this._buttons.length,
            active: active.index(),
            empty: this._buttons.map(({ws}) => normalWindows(ws).length === 0),
            style: this._settings.get_string('indicator-style'),
            showEmpty: this._settings.get_boolean('show-empty'),
        }));
        const names = this._names();
        for (const {button, ws, icons} of this._buttons) {
            const isActive = ws === active;
            button.accessible_name = accessibleName(names, ws.index(), isActive);
            const empty = normalWindows(ws).length === 0;
            let cls = 'ost-ws-button';
            if (isActive)
                cls += accent ? ' ost-ws-active ost-ws-accent' : ' ost-ws-active';
            else if (empty)
                cls += ' ost-ws-empty';
            button.style_class = cls;
            button.visible = visible.has(ws.index());
            // Small icons of the apps on it (one per app, a few at most).
            icons.destroy_all_children();
            icons.visible = showIcons && !empty;
            if (showIcons && !empty) {
                const tracker = Shell.WindowTracker.get_default();
                const apps = [...new Set(normalWindows(ws).map(w => tracker.get_window_app(w)).filter(Boolean))];
                for (const app of apps.slice(0, MAX_ICONS))
                    icons.add_child(app.create_icon_texture(14));
            }
        }
    }

    // One scroll movement, wheel or touchpad, moves one workspace (see scroll.js).
    _onScroll(event) {
        const dir = event.get_scroll_direction();
        let delta;
        if (dir === Clutter.ScrollDirection.UP || dir === Clutter.ScrollDirection.LEFT) {
            delta = -1;
        } else if (dir === Clutter.ScrollDirection.DOWN || dir === Clutter.ScrollDirection.RIGHT) {
            delta = 1;
        } else if (dir === Clutter.ScrollDirection.SMOOTH && event.get_scroll_source() !== Clutter.ScrollSource.WHEEL) {
            // A wheel sends a smooth copy of each click too; only a touchpad's count here.
            const [dx, dy] = event.get_scroll_delta();
            delta = Math.abs(dy) >= Math.abs(dx) ? dy : dx;
        } else {
            return Clutter.EVENT_PROPAGATE;
        }
        this._gate ??= new ScrollGate();
        const step = this._gate.step(event.get_time(), delta);
        if (step === 0)
            return Clutter.EVENT_STOP;
        const wsm = global.workspace_manager;
        const n = wsm.get_n_workspaces();
        let next = wsm.get_active_workspace_index() + step;
        if (this._settings.get_boolean('scroll-wrap'))
            next = (next + n) % n;
        if (next >= 0 && next < n)
            wsm.get_workspace_by_index(next).activate(global.get_current_time());
        return Clutter.EVENT_STOP;
    }

    // ---- workspace changes (menu, drag and drop, shortcuts) ----

    _moveWorkspace(ws, to) {
        const wsm = global.workspace_manager;
        const from = ws.index();
        to = Math.max(0, Math.min(wsm.get_n_workspaces() - 1, to));
        if (to === from)
            return;
        // Names first, so the rebuild after the reorder shows them in their new places.
        this._setNames(moveName(this._names(), from, to));
        wsm.reorder_workspace(ws, to);
    }

    newWorkspace() {
        const wsm = global.workspace_manager;
        const ws = wsm.append_new_workspace(false, global.get_current_time());
        ws.activate(global.get_current_time());
        return ws;
    }

    _removeWorkspace(ws) {
        const wsm = global.workspace_manager;
        if (wsm.get_n_workspaces() <= 1)
            return;
        // Its windows go to the workspace before it (or after, for the first).
        const i = ws.index();
        const neighbour = wsm.get_workspace_by_index(i > 0 ? i - 1 : 1);
        for (const w of normalWindows(ws))
            w.change_workspace(neighbour);
        this._setNames(removeName(this._names(), i));
        if (ws === wsm.get_active_workspace())
            neighbour.activate(global.get_current_time());
        wsm.remove_workspace(ws, global.get_current_time());
    }

    moveActive(step) {
        const ws = global.workspace_manager.get_active_workspace();
        this._moveWorkspace(ws, ws.index() + step);
    }

    renameActive() {
        const ws = global.workspace_manager.get_active_workspace();
        const entry = this._buttons.find(b => b.ws === ws);
        if (entry)
            this._openMenu(entry);
    }

    // ---- smart names ----

    _namesInUse(exceptIndex) {
        return this._names().filter((n, i) => n && i !== exceptIndex);
    }

    _applySmartName(ws) {
        if (!this._settings.get_boolean('smart-names') || this._names()[ws.index()])
            return;
        const map = parseMap(this._settings.get_string('names-map'));
        const name = smartName(map, windowClasses(ws), this._namesInUse(ws.index()));
        if (name)
            this._setName(ws.index(), name);
    }

    _rename(ws, name) {
        this._setName(ws.index(), name);
        if (!this._settings.get_boolean('smart-names') || !name)
            return;
        const map = parseMap(this._settings.get_string('names-map'));
        const next = associate(map, windowClasses(ws), name, this._namesInUse(ws.index()));
        this._settings.set_string('names-map', JSON.stringify(next));
    }

    // ---- the right-click menu: rename (the entry at the top), new, move, remove ----

    _openMenu({button, ws}) {
        this._closeMenu();
        const menu = new PopupMenu.PopupMenu(button, 0.5, St.Side.TOP);
        Main.uiGroup.add_child(menu.actor);
        menu.actor.hide();
        const item = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        const entry = new St.Entry({
            text: this._names()[ws.index()] ?? '',
            hint_text: `Name workspace ${ws.index() + 1}`,
            x_expand: true,
            style_class: 'ost-ws-entry',
        });
        item.add_child(entry);
        menu.addMenuItem(item);
        entry.clutter_text.connect('activate', () => {
            this._rename(ws, entry.get_text().trim());
            menu.close();
        });
        menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        const n = global.workspace_manager.get_n_workspaces();
        menu.addAction('New workspace', () => this.newWorkspace());
        const left = menu.addAction('Move left', () => this._moveWorkspace(ws, ws.index() - 1));
        left.setSensitive(ws.index() > 0);
        const right = menu.addAction('Move right', () => this._moveWorkspace(ws, ws.index() + 1));
        right.setSensitive(ws.index() < n - 1);
        const windows = normalWindows(ws).length;
        const remove = menu.addAction(windows > 0
            ? `Remove workspace (its ${windows === 1 ? 'window moves' : `${windows} windows move`} next door)`
            : 'Remove workspace', () => this._removeWorkspace(ws));
        remove.setSensitive(n > 1);
        menu.connect('open-state-changed', (_m, open) => {
            if (!open)
                this._closeMenu();
        });
        this._menuManager.addMenu(menu);
        this._menu = menu;
        menu.open();
        entry.clutter_text.set_selection(0, -1);
        global.stage.set_key_focus(entry);
    }

    _closeMenu() {
        const menu = this._menu;
        if (!menu)
            return;
        this._menu = null;
        this._menuManager.removeMenu(menu);
        menu.destroy();
    }

    destroy() {
        this._closeMenu();
        this._signals.disconnectAll();
        this._wsSignals.disconnectAll();
        this._settings = this._wm = null;
        super.destroy();
    }
});

const KEYS = [
    ['new-workspace', bar => bar.newWorkspace()],
    ['rename-workspace', bar => bar.renameActive()],
    ['move-workspace-left', bar => bar.moveActive(-1)],
    ['move-workspace-right', bar => bar.moveActive(1)],
];

export default class WorkspacesExtension extends Extension {
    enable() {
        this._scheme = new SchemeStyle(this); // the user's colour scheme, if one is applied
        this._settings = this.getSettings();
        this._bar = new Bar(this);
        Main.panel.addToStatusArea(this.uuid, this._bar, 0, 'left');
        // Scrolling anywhere on the top bar moves between workspaces too; items that use the scroll
        // themselves (the volume) keep it, as their handlers stop it before it reaches the panel.
        this._panelScrollId = Main.panel.connect('scroll-event', (_a, event) => this._bar._onScroll(event));
        // The bar takes the Activities button's place; restored on disable.
        this._activities = Main.panel.statusArea.activities?.container;
        this._activities?.hide();
        for (const [key, run] of KEYS) {
            Main.wm.addKeybinding(key, this._settings, Meta.KeyBindingFlags.NONE,
                Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW, () => run(this._bar));
        }
    }

    disable() {
        this._scheme.destroy();
        this._scheme = null;
        for (const [key] of KEYS)
            Main.wm.removeKeybinding(key);
        if (this._panelScrollId)
            Main.panel.disconnect(this._panelScrollId);
        this._panelScrollId = 0;
        this._activities?.show();
        this._activities = null;
        this._bar?.destroy();
        this._bar = null;
        this._settings = null;
    }
}
