// SPDX-License-Identifier: GPL-2.0-or-later
// Throwaway spike (DESIGN.md: drawer extension). Answers, on GNOME 50 Wayland:
//   - can an extension place the drawer-host window under the top bar and size it?
//   - can it slide it down/up, keep it above, on all workspaces, and focused for typing?
//   - can it keep it out of Alt+Tab?
// Driven over D-Bus for testing: ostrich_os.DrawerSpike.Toggle() / State().

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import Meta from 'gi://Meta';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const APP_ID = 'ostrich_os.drawer';
const IFACE = `<node><interface name="ostrich_os.DrawerSpike">
  <method name="Toggle"/>
  <method name="State"><arg type="s" direction="out"/></method>
</interface></node>`;

function isDrawer(win) {
    return win?.get_gtk_application_id?.() === APP_ID || win?.get_wm_class?.() === APP_ID;
}

export default class DrawerSpike extends Extension {
    enable() {
        this._shown = false;
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this);
        this._dbus.export(Gio.DBus.session, '/ostrich_os/DrawerSpike');
        this._nameId = Gio.bus_own_name_on_connection(Gio.DBus.session,
            'ostrich_os.DrawerSpike', Gio.BusNameOwnerFlags.NONE, null, null);

        // Keep the drawer out of Alt+Tab (same approach as holder-monitor: every switcher
        // goes through display.get_tab_list).
        const proto = Meta.Display.prototype;
        this._getTabList = proto.get_tab_list;
        const orig = this._getTabList;
        proto.get_tab_list = function (type, workspace) {
            return orig.call(this, type, workspace).filter(w => !isDrawer(w));
        };
    }

    disable() {
        Meta.Display.prototype.get_tab_list = this._getTabList;
        Gio.bus_unown_name(this._nameId);
        this._dbus.unexport();
        this._dbus = null;
    }

    _window() {
        return global.display.list_all_windows().find(isDrawer) ?? null;
    }

    _rect() {
        const m = Main.layoutManager.primaryMonitor;
        const width = Math.round(m.width * 0.5);
        const height = Math.round(m.height * 0.6);
        return {x: m.x + Math.round((m.width - width) / 2), y: m.y + Main.panel.height, width, height};
    }

    Toggle() {
        const win = this._window();
        if (!win)
            return;
        const actor = win.get_compositor_private();
        const r = this._rect();

        if (!this._shown) {
            this._shown = true;
            win.unminimize();
            win.make_above();
            win.stick(); // on every workspace
            win.move_resize_frame(false, r.x, r.y, r.width, r.height);
            win.activate(global.get_current_time());
            actor.remove_all_transitions();
            actor.translation_y = -(r.height + Main.panel.height);
            actor.ease({translation_y: 0, duration: 180, mode: Clutter.AnimationMode.EASE_OUT_QUAD});
        } else {
            this._shown = false;
            actor.ease({
                translation_y: -(r.height + Main.panel.height),
                duration: 140,
                mode: Clutter.AnimationMode.EASE_IN_QUAD,
                // Minimized windows are hidden, so WebKit throttles their pages (saves power).
                onComplete: () => {
                    win.minimize();
                    actor.translation_y = 0;
                },
            });
        }
    }

    State() {
        const win = this._window();
        if (!win)
            return JSON.stringify({found: false});
        const f = win.get_frame_rect();
        const inTabList = global.display.get_tab_list(Meta.TabList.NORMAL_ALL, null).includes(win);
        return JSON.stringify({
            found: true, shown: this._shown, minimized: win.minimized, above: win.is_above(),
            onAllWorkspaces: win.is_on_all_workspaces(), focused: win.has_focus(), inTabList,
            frame: [f.x, f.y, f.width, f.height], expected: this._rect(),
        });
    }
}
