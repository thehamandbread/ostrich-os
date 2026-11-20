// SPDX-License-Identifier: GPL-2.0-or-later
// Tray: StatusNotifierItem (AppIndicator) icons in the top bar.
//
// We own org.kde.StatusNotifierWatcher, which apps register their tray icons with; if another
// program already owns it, we read its item list instead. One top-bar button per item:
//   left click   Activate (or open the menu for menu-only items)
//   right click  the app's menu (com.canonical.dbusmenu), fetched when opened, never polled
//   middle click SecondaryActivate;   scroll  Scroll
// Items disappear when their app's bus name vanishes. Passive items are hidden.

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Gio from 'gi://Gio';
import GdkPixbuf from 'gi://GdkPixbuf';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {argbToRgba, parseService, pickPixmap, stripMnemonic} from './pixmap.js';

const WATCHER_NAME = 'org.kde.StatusNotifierWatcher';
const WATCHER_PATH = '/StatusNotifierWatcher';
const ITEM_IFACE = 'org.kde.StatusNotifierItem';
const MENU_IFACE = 'com.canonical.dbusmenu';
const ICON_SIZE = 16;

const WATCHER_XML = `<node><interface name="${WATCHER_NAME}">
  <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
  <method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
  <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
  <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
  <property name="ProtocolVersion" type="i" access="read"/>
  <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
  <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
  <signal name="StatusNotifierHostRegistered"/>
</interface></node>`;

function call(busName, path, iface, method, params, replyType, cancellable) {
    return new Promise((resolve, reject) => {
        Gio.DBus.session.call(busName, path, iface, method, params,
            replyType ? new GLib.VariantType(replyType) : null, Gio.DBusCallFlags.NONE, 5000, cancellable,
            (conn, res) => {
                try {
                    resolve(conn.call_finish(res));
                } catch (e) {
                    reject(e);
                }
            });
    });
}

const getAll = (busName, path, iface, c) =>
    call(busName, path, 'org.freedesktop.DBus.Properties', 'GetAll', new GLib.Variant('(s)', [iface]), '(a{sv})', c)
        .then(v => v.recursiveUnpack()[0]);

// ---- one tray item ---------------------------------------------------------------------------

const TrayButton = GObject.registerClass(
class TrayButton extends PanelMenu.Button {
    _init(key, busName, objectPath) {
        super._init(0.5, `Tray: ${busName}`);
        this._key = key;
        this._busName = busName;
        this._path = objectPath;
        this._props = {};
        this._cancellable = new Gio.Cancellable();
        this._icon = new St.Icon({style_class: 'system-status-icon', icon_size: ICON_SIZE, fallback_icon_name: 'image-missing-symbolic'});
        this.add_child(this._icon);
        this.visible = false;

        // GNOME 50's panel buttons toggle their menu from a click gesture (and St.Widget has no event
        // vfunc to chain to: overriding it threw on every pointer motion). Ours, as the drawer's:
        // left Activates (or opens the menu of a menu-only item), middle SecondaryActivates, right
        // opens the menu, the wheel Scrolls.
        this._clickGesture.set_enabled(false);
        const click = (button, action) => {
            const g = new Clutter.ClickGesture({recognize_on_press: true, required_button: button});
            g.connect('recognize', () => action(...global.get_pointer().slice(0, 2)));
            this.add_action(g);
        };
        click(Clutter.BUTTON_PRIMARY, (x, y) => {
            if (this._props.ItemIsMenu)
                this._toggleMenu();
            else
                this._itemCall('Activate', new GLib.Variant('(ii)', [x, y]));
        });
        click(Clutter.BUTTON_MIDDLE, (x, y) => this._itemCall('SecondaryActivate', new GLib.Variant('(ii)', [x, y])));
        click(Clutter.BUTTON_SECONDARY, () => this._toggleMenu());
        this.connect('scroll-event', (_a, event) => {
            const dir = event.get_scroll_direction();
            const delta = dir === Clutter.ScrollDirection.UP ? -1 : dir === Clutter.ScrollDirection.DOWN ? 1 : 0;
            if (delta)
                this._itemCall('Scroll', new GLib.Variant('(is)', [delta, 'vertical']));
            return Clutter.EVENT_STOP;
        });

        // NewIcon, NewStatus, NewToolTip... carry no values: re-read the properties.
        this._signalId = Gio.DBus.session.signal_subscribe(busName, ITEM_IFACE, null, objectPath, null,
            Gio.DBusSignalFlags.NONE, () => this._refresh());
        this._refresh();
    }

    async _refresh() {
        try {
            this._props = await getAll(this._busName, this._path, ITEM_IFACE, this._cancellable);
        } catch (e) {
            if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                console.debug(`tray: ${this._busName}: ${e.message}`);
            return;
        }
        this._render();
    }

    _render() {
        const p = this._props;
        const attention = p.Status === 'NeedsAttention';
        this.visible = p.Status !== 'Passive';
        const name = (attention && p.AttentionIconName) || p.IconName;
        const pixmaps = (attention && p.AttentionIconPixmap?.length ? p.AttentionIconPixmap : p.IconPixmap) ?? [];
        this._icon.gicon = this._giconFor(name, p.IconThemePath, pixmaps);
        this.accessible_name = p.Title || p.Id || this._busName;
    }

    _giconFor(name, themePath, pixmaps) {
        if (name) {
            if (name.startsWith('/'))
                return Gio.FileIcon.new(Gio.File.new_for_path(name));
            if (themePath) {
                for (const ext of ['svg', 'png']) {
                    const f = Gio.File.new_for_path(`${themePath}/${name}.${ext}`);
                    if (f.query_exists(null))
                        return Gio.FileIcon.new(f);
                }
            }
            return Gio.ThemedIcon.new(name);
        }
        const scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
        const best = pickPixmap(pixmaps.map(([w, h, d]) => [w, h, Uint8Array.from(d)]), ICON_SIZE * scale);
        if (!best)
            return Gio.ThemedIcon.new('image-missing-symbolic');
        const [w, h, data] = best;
        return GdkPixbuf.Pixbuf.new_from_bytes(new GLib.Bytes(argbToRgba(data)),
            GdkPixbuf.Colorspace.RGB, true, 8, w, h, w * 4);
    }

    _itemCall(method, params) {
        call(this._busName, this._path, ITEM_IFACE, method, params, null, this._cancellable)
            .catch(e => console.debug(`tray: ${method} failed: ${e.message}`));
    }

    _toggleMenu() {
        if (this.menu.isOpen)
            this.menu.close();
        else
            this._openMenu();
    }

    async _openMenu() {
        const menuPath = this._props.Menu;
        if (!menuPath || menuPath === '/') {
            // No dbusmenu: fall back to the item's own context menu.
            this._itemCall('ContextMenu', new GLib.Variant('(ii)', [0, 0]));
            return;
        }
        try {
            await call(this._busName, menuPath, MENU_IFACE, 'AboutToShow', new GLib.Variant('(i)', [0]), null, this._cancellable)
                .catch(() => null); // optional in the spec
            const reply = await call(this._busName, menuPath, MENU_IFACE, 'GetLayout',
                new GLib.Variant('(iias)', [0, -1, []]), '(u(ia{sv}av))', this._cancellable);
            const [, root] = reply.recursiveUnpack();
            this.menu.removeAll();
            this._buildMenu(this.menu, root[2], menuPath);
            this.menu.open();
        } catch (e) {
            console.debug(`tray: menu for ${this._busName} failed: ${e.message}`);
        }
    }

    _buildMenu(menu, children, menuPath) {
        for (const [id, props, sub] of children) {
            if (props.visible === false)
                continue;
            if (props.type === 'separator') {
                menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
                continue;
            }
            const text = stripMnemonic(props.label);
            let item;
            if (props['children-display'] === 'submenu' && sub.length > 0) {
                item = new PopupMenu.PopupSubMenuMenuItem(text);
                this._buildMenu(item.menu, sub, menuPath);
            } else {
                item = new PopupMenu.PopupMenuItem(text);
                item.connect('activate', () => call(this._busName, menuPath, MENU_IFACE, 'Event',
                    new GLib.Variant('(isvu)', [id, 'clicked', new GLib.Variant('i', 0), global.get_current_time()]),
                    null, this._cancellable).catch(() => {}));
            }
            if (props['toggle-type'] && props['toggle-state'] === 1)
                item.setOrnament(PopupMenu.Ornament.CHECK);
            if (props.enabled === false)
                item.setSensitive(false);
            menu.addMenuItem(item);
        }
    }

    destroy() {
        this._cancellable.cancel();
        Gio.DBus.session.signal_unsubscribe(this._signalId);
        super.destroy();
    }
});

// ---- watcher / host --------------------------------------------------------------------------

class Tray {
    constructor(uuid) {
        this._uuid = uuid;
        this._items = new Map(); // key "busName|path" → {button, watchId}
        this._ownId = Gio.bus_own_name_on_connection(Gio.DBus.session, WATCHER_NAME,
            Gio.BusNameOwnerFlags.NONE,
            () => this._onNameAcquired(),
            () => this._onNameLost());
    }

    // ---- as the watcher ----

    _onNameAcquired() {
        this._dbus = Gio.DBusExportedObject.wrapJSObject(WATCHER_XML, this);
        this._dbus.export(Gio.DBus.session, WATCHER_PATH);
    }

    RegisterStatusNotifierItemAsync([service], invocation) {
        const {busName, objectPath} = parseService(service, invocation.get_sender());
        this._addItem(busName, objectPath);
        invocation.return_value(null);
    }

    RegisterStatusNotifierHostAsync(_params, invocation) {
        invocation.return_value(null);
    }

    get RegisteredStatusNotifierItems() {
        return [...this._items.keys()].map(k => k.replace('|', ''));
    }

    get IsStatusNotifierHostRegistered() {
        return true;
    }

    get ProtocolVersion() {
        return 0;
    }

    // ---- someone else is the watcher: read its items ----

    async _onNameLost() {
        if (this._dbus || this._client)
            return; // lost after having it (shutdown); nothing to do
        this._client = true;
        try {
            this._watcherSignal = Gio.DBus.session.signal_subscribe(WATCHER_NAME, WATCHER_NAME,
                'StatusNotifierItemRegistered', WATCHER_PATH, null, Gio.DBusSignalFlags.NONE,
                (_c, sender, _p, _i, _s, params) => {
                    const {busName, objectPath} = parseService(params.deepUnpack()[0], sender);
                    this._addItem(busName, objectPath);
                });
            const props = await getAll(WATCHER_NAME, WATCHER_PATH, WATCHER_NAME, null);
            for (const s of props.RegisteredStatusNotifierItems ?? []) {
                const {busName, objectPath} = parseService(s, s);
                this._addItem(busName, objectPath);
            }
        } catch (e) {
            console.warn(`tray: could not read the existing StatusNotifierWatcher: ${e.message}`);
        }
    }

    _addItem(busName, objectPath) {
        const key = `${busName}|${objectPath}`;
        if (this._items.has(key))
            return;
        const button = new TrayButton(key, busName, objectPath);
        // Left of the drawer's group (+ ⌄ sites, which sits fixed beside quick settings), else just left
        // of quick settings; never at the start of the box. A new background app grows the bar to the
        // left and moves nothing else (owner, 2026-11-18 and 2026-11-19).
        Main.panel.addToStatusArea(`${this._uuid}-${key}`, button, 0, 'right');
        const box = button.container.get_parent();
        const kids = box.get_children();
        const drawer = Object.entries(Main.panel.statusArea)
            .filter(([role]) => role.startsWith('drawer@ubuntu-ostrich-'))
            .map(([, b]) => b.container)
            .filter(c => c.get_parent() === box)
            .sort((a, b) => kids.indexOf(a) - kids.indexOf(b))[0];
        const qs = Main.panel.statusArea.quickSettings?.container;
        const before = drawer ?? (qs?.get_parent() === box ? qs : null);
        if (before)
            box.set_child_below_sibling(button.container, before);
        // Vanishes with its app: no polling, D-Bus tells us.
        const watchId = Gio.bus_watch_name_on_connection(Gio.DBus.session, busName, Gio.BusNameWatcherFlags.NONE,
            null, () => this._removeItem(key));
        this._items.set(key, {button, watchId});
        this._dbus?.emit_signal('StatusNotifierItemRegistered', new GLib.Variant('(s)', [`${busName}${objectPath}`]));
    }

    _removeItem(key) {
        const item = this._items.get(key);
        if (!item)
            return;
        this._items.delete(key);
        Gio.bus_unwatch_name(item.watchId);
        item.button.destroy();
        this._dbus?.emit_signal('StatusNotifierItemUnregistered', new GLib.Variant('(s)', [key.replace('|', '')]));
    }

    destroy() {
        for (const key of [...this._items.keys()])
            this._removeItem(key);
        if (this._watcherSignal)
            Gio.DBus.session.signal_unsubscribe(this._watcherSignal);
        this._dbus?.unexport();
        this._dbus = null;
        Gio.bus_unown_name(this._ownId);
    }
}

export default class TrayExtension extends Extension {
    enable() {
        this._tray = new Tray(this.uuid);
    }

    disable() {
        this._tray?.destroy();
        this._tray = null;
    }
}
