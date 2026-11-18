#!/usr/bin/env python3
# tests/vm/mock-bluez.py: a mock BlueZ for VM tests (runs in the test VM, on the SYSTEM bus; needs root
# and tests/vm/mock-bluez.conf in /etc/dbus-1/system.d/, which bluetooth-test.sh installs).
#   mock-bluez.py [on|off]
# One adapter (hci0), three paired devices: "Mock Earbuds" and "Mock Speaker" connect after a second,
# "Mock Keyboard" fails every Connect with org.bluez.Error.Failed. Nothing pairs or scans, no timers
# run except the one-second connect delay. Disconnect is immediate. State changes send
# PropertiesChanged like the real daemon, so GnomeBluetooth.Client sees them.
import sys

from gi.repository import Gio, GLib

POWERED = (sys.argv[1] if len(sys.argv) > 1 else "on") == "on"

ADAPTER_XML = """<node><interface name="org.bluez.Adapter1">
 <method name="StartDiscovery"/><method name="StopDiscovery"/>
 <method name="RemoveDevice"><arg type="o" direction="in"/></method>
 <property name="Address" type="s" access="read"/><property name="Name" type="s" access="read"/>
 <property name="Alias" type="s" access="readwrite"/><property name="Powered" type="b" access="readwrite"/>
 <property name="Discoverable" type="b" access="readwrite"/><property name="Pairable" type="b" access="readwrite"/>
 <property name="Discovering" type="b" access="read"/>
</interface></node>"""

DEVICE_XML = """<node><interface name="org.bluez.Device1">
 <method name="Connect"/><method name="Disconnect"/>
 <method name="Pair"/><method name="CancelPairing"/>
 <property name="Address" type="s" access="read"/><property name="Name" type="s" access="read"/>
 <property name="Alias" type="s" access="readwrite"/><property name="Icon" type="s" access="read"/>
 <property name="Class" type="u" access="read"/><property name="Adapter" type="o" access="read"/>
 <property name="Paired" type="b" access="read"/><property name="Trusted" type="b" access="readwrite"/>
 <property name="Blocked" type="b" access="readwrite"/><property name="Connected" type="b" access="read"/>
 <property name="LegacyPairing" type="b" access="read"/><property name="UUIDs" type="as" access="read"/>
</interface></node>"""

MANAGER_XML = """<node><interface name="org.freedesktop.DBus.ObjectManager">
 <method name="GetManagedObjects"><arg type="a{oa{sa{sv}}}" direction="out"/></method>
 <signal name="InterfacesAdded"/><signal name="InterfacesRemoved"/>
</interface></node>"""

ADAPTER = "/org/bluez/hci0"
state = {
    "adapter": {"Address": "00:11:22:33:44:55", "Name": "mock", "Alias": "mock", "Powered": POWERED,
                "Discoverable": False, "Pairable": True, "Discovering": False},
    "devices": {},
}
for n, (alias, icon, ok) in enumerate([("Mock Earbuds", "audio-headphones", True),
                                       ("Mock Speaker", "audio-speakers", True),
                                       ("Mock Keyboard", "input-keyboard", False)], start=1):
    state["devices"][f"{ADAPTER}/dev_AA_BB_CC_DD_EE_0{n}"] = {
        "Address": f"AA:BB:CC:DD:EE:0{n}", "Name": alias, "Alias": alias, "Icon": icon, "Class": 0,
        "Adapter": ADAPTER, "Paired": True, "Trusted": True, "Blocked": False, "Connected": False,
        "LegacyPairing": False, "UUIDs": [], "_works": ok,
    }

TYPES = {"Address": "s", "Name": "s", "Alias": "s", "Icon": "s", "Class": "u", "Adapter": "o", "Paired": "b",
         "Trusted": "b", "Blocked": "b", "Connected": "b", "LegacyPairing": "b", "UUIDs": "as",
         "Powered": "b", "Discoverable": "b", "Pairable": "b", "Discovering": "b"}
conn = None


def variant(key, value):
    return GLib.Variant(TYPES[key], value)


def props_of(table):
    return {k: variant(k, v) for k, v in table.items() if not k.startswith("_")}


def changed(path, iface, key, value):
    conn.emit_signal(None, path, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                     GLib.Variant("(sa{sv}as)", (iface, {key: variant(key, value)}, [])))


def get_prop(_c, _s, path, _i, key):
    table = state["adapter"] if path == ADAPTER else state["devices"][path]
    return variant(key, table[key])


def set_prop(_c, _s, path, iface, key, value):
    table = state["adapter"] if path == ADAPTER else state["devices"][path]
    table[key] = value.unpack()
    changed(path, iface, key, table[key])
    return True


def device_call(_c, _s, path, _i, method, _params, invocation):
    dev = state["devices"][path]
    if method == "Connect":
        def done():
            if dev["_works"]:
                dev["Connected"] = True
                changed(path, "org.bluez.Device1", "Connected", True)
                invocation.return_value(None)
            else:
                invocation.return_dbus_error("org.bluez.Error.Failed", "Input/output error")
            return GLib.SOURCE_REMOVE
        GLib.timeout_add(1000, done)
        return
    if method == "Disconnect" and dev["Connected"]:
        dev["Connected"] = False
        changed(path, "org.bluez.Device1", "Connected", False)
    invocation.return_value(None)


def adapter_call(_c, _s, _p, _i, _m, _params, invocation):
    invocation.return_value(None)


def manager_call(_c, _s, _p, _i, _m, _params, invocation):
    objs = {ADAPTER: {"org.bluez.Adapter1": props_of(state["adapter"])}}
    for path, dev in state["devices"].items():
        objs[path] = {"org.bluez.Device1": props_of(dev)}
    invocation.return_value(GLib.Variant("(a{oa{sa{sv}}})", (objs,)))


def on_bus(c, _name):
    global conn
    conn = c
    node = lambda xml: Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0]
    c.register_object("/", node(MANAGER_XML), manager_call, None, None)
    c.register_object(ADAPTER, node(ADAPTER_XML), adapter_call, get_prop, set_prop)
    for path in state["devices"]:
        c.register_object(path, node(DEVICE_XML), device_call, get_prop, set_prop)


Gio.bus_own_name(Gio.BusType.SYSTEM, "org.bluez", Gio.BusNameOwnerFlags.NONE, on_bus, None,
                 lambda *_: sys.exit("mock-bluez: could not own org.bluez (is the dbus policy installed, and is bluetoothd stopped?)"))
GLib.MainLoop().run()
