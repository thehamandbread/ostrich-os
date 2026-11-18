// tests/vm/sni-test-item.js: a scripted tray icon for testing the tray extension in the VM.
//
//   gjs -m sni-test-item.js <log-file>
//
// Registers a StatusNotifierItem (icon "face-smile", title "Tray Test") with a dbusmenu holding
// "Hello" and "Quit". Every Activate / SecondaryActivate / Scroll / menu event is appended to the
// log file as one line, so a test can check what the tray sent.
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';

const LOG = ARGV[0] ?? '/tmp/sni-test.log';
const log = line => {
    const f = Gio.File.new_for_path(LOG);
    const s = f.append_to(Gio.FileCreateFlags.NONE, null);
    s.write_all(`${line}\n`, null);
    s.close(null);
};

const ITEM_XML = `<node><interface name="org.kde.StatusNotifierItem">
  <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
  <property name="Id" type="s" access="read"/>
  <property name="Title" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="IconName" type="s" access="read"/>
  <property name="Menu" type="o" access="read"/>
  <property name="ItemIsMenu" type="b" access="read"/>
  <signal name="NewIcon"/>
</interface></node>`;

const MENU_XML = `<node><interface name="com.canonical.dbusmenu">
  <method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
    <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
  <method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
  <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
</interface></node>`;

const item = {
    Activate(x, y) {
        log(`Activate ${x} ${y}`);
    },
    SecondaryActivate() {
        log('SecondaryActivate');
    },
    ContextMenu() {
        log('ContextMenu');
    },
    Scroll(delta, orientation) {
        log(`Scroll ${delta} ${orientation}`);
    },
    get Id() {
        return 'tray-test';
    },
    get Title() {
        return 'Tray Test';
    },
    get Status() {
        return 'Active';
    },
    get IconName() {
        return 'face-smile';
    },
    get Menu() {
        return '/Menu';
    },
    get ItemIsMenu() {
        return false;
    },
};

const entry = (id, label) => new GLib.Variant('v', new GLib.Variant('(ia{sv}av)', [id, {label: new GLib.Variant('s', label)}, []]));
const menu = {
    GetLayout() {
        return [1, [0, {'children-display': new GLib.Variant('s', 'submenu')}, [entry(1, '_Hello'), entry(2, '_Quit')]]];
    },
    Event(id, type) {
        log(`Event ${id} ${type}`);
        if (id === 2 && type === 'clicked')
            loop.quit();
    },
    AboutToShow() {
        return false;
    },
};

const loop = new GLib.MainLoop(null, false);
const name = `org.kde.StatusNotifierItem-${new Gio.Credentials().get_unix_pid()}-1`;
Gio.DBusExportedObject.wrapJSObject(ITEM_XML, item).export(Gio.DBus.session, '/StatusNotifierItem');
Gio.DBusExportedObject.wrapJSObject(MENU_XML, menu).export(Gio.DBus.session, '/Menu');
Gio.bus_own_name_on_connection(Gio.DBus.session, name, Gio.BusNameOwnerFlags.NONE, () => {
    Gio.DBus.session.call('org.kde.StatusNotifierWatcher', '/StatusNotifierWatcher', 'org.kde.StatusNotifierWatcher',
        'RegisterStatusNotifierItem', new GLib.Variant('(s)', [name]), null, Gio.DBusCallFlags.NONE, -1, null,
        (c, r) => {
            try {
                c.call_finish(r);
                log(`registered ${name}`);
            } catch (e) {
                log(`register failed: ${e.message}`);
            }
        });
}, null);
loop.run();
