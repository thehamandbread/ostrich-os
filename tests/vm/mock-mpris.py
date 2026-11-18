#!/usr/bin/env python3
# tests/vm/mock-mpris.py: a mock MPRIS media player for VM tests (runs in the test VM's session).
#   mock-mpris.py [Playing|Paused] [title]
# Owns org.mpris.MediaPlayer2.mock and answers Play/Pause/Next with PropertiesChanged; no timers.
import sys

from gi.repository import Gio, GLib

STATUS = sys.argv[1] if len(sys.argv) > 1 else "Paused"
TITLE = sys.argv[2] if len(sys.argv) > 2 else "Council test track"
# The app it says it is (MPRIS DesktopEntry), e.g. org.gnome.Nautilus for the dock's Files icon.
ENTRY = sys.argv[3] if len(sys.argv) > 3 else "mock-player"

XML = """<node>
<interface name="org.mpris.MediaPlayer2">
 <method name="Raise"/><method name="Quit"/>
 <property name="CanQuit" type="b" access="read"/><property name="CanRaise" type="b" access="read"/>
 <property name="HasTrackList" type="b" access="read"/><property name="Identity" type="s" access="read"/>
 <property name="DesktopEntry" type="s" access="read"/>
 <property name="SupportedUriSchemes" type="as" access="read"/><property name="SupportedMimeTypes" type="as" access="read"/>
</interface>
<interface name="org.mpris.MediaPlayer2.Player">
 <method name="Next"/><method name="Previous"/><method name="Pause"/><method name="PlayPause"/>
 <method name="Stop"/><method name="Play"/>
 <method name="Seek"><arg type="x" direction="in"/></method>
 <method name="SetPosition"><arg type="o" direction="in"/><arg type="x" direction="in"/></method>
 <method name="OpenUri"><arg type="s" direction="in"/></method>
 <property name="PlaybackStatus" type="s" access="read"/><property name="Rate" type="d" access="read"/>
 <property name="Metadata" type="a{sv}" access="read"/><property name="Volume" type="d" access="read"/>
 <property name="Position" type="x" access="read"/>
 <property name="MinimumRate" type="d" access="read"/><property name="MaximumRate" type="d" access="read"/>
 <property name="CanGoNext" type="b" access="read"/><property name="CanGoPrevious" type="b" access="read"/>
 <property name="CanPlay" type="b" access="read"/><property name="CanPause" type="b" access="read"/>
 <property name="CanSeek" type="b" access="read"/><property name="CanControl" type="b" access="read"/>
</interface>
</node>"""

state = {"status": STATUS, "track": 1}
conn = None


def metadata():
    return {
        "mpris:trackid": GLib.Variant("o", "/org/mpris/MediaPlayer2/track/%d" % state["track"]),
        "xesam:title": GLib.Variant("s", TITLE if state["track"] == 1 else "Track %d" % state["track"]),
        "xesam:artist": GLib.Variant("as", ["Mock Artist"]),
        "mpris:length": GLib.Variant("x", 180_000_000),
    }


def props(iface):
    if iface == "org.mpris.MediaPlayer2":
        return {"CanQuit": GLib.Variant("b", True), "CanRaise": GLib.Variant("b", False),
                "HasTrackList": GLib.Variant("b", False), "Identity": GLib.Variant("s", "Mock Player"),
                "DesktopEntry": GLib.Variant("s", ENTRY),
                "SupportedUriSchemes": GLib.Variant("as", []), "SupportedMimeTypes": GLib.Variant("as", [])}
    return {"PlaybackStatus": GLib.Variant("s", state["status"]), "Rate": GLib.Variant("d", 1.0),
            "Metadata": GLib.Variant("a{sv}", metadata()), "Volume": GLib.Variant("d", 1.0),
            "Position": GLib.Variant("x", 0), "MinimumRate": GLib.Variant("d", 1.0),
            "MaximumRate": GLib.Variant("d", 1.0), "CanGoNext": GLib.Variant("b", True),
            "CanGoPrevious": GLib.Variant("b", True), "CanPlay": GLib.Variant("b", True),
            "CanPause": GLib.Variant("b", True), "CanSeek": GLib.Variant("b", False),
            "CanControl": GLib.Variant("b", True)}


def changed():
    p = props("org.mpris.MediaPlayer2.Player")
    conn.emit_signal(None, "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties", "PropertiesChanged",
                     GLib.Variant("(sa{sv}as)", ("org.mpris.MediaPlayer2.Player",
                                                 {"PlaybackStatus": p["PlaybackStatus"], "Metadata": p["Metadata"]}, [])))


def call(_c, _s, _p, iface, method, _params, inv):
    if method in ("Play", "PlayPause", "Pause", "Stop"):
        playing = method == "Play" or (method == "PlayPause" and state["status"] != "Playing")
        state["status"] = "Playing" if playing else ("Stopped" if method == "Stop" else "Paused")
        changed()
    elif method in ("Next", "Previous"):
        state["track"] = max(1, state["track"] + (1 if method == "Next" else -1))
        changed()
    elif method == "Quit":
        loop.quit()
    inv.return_value(None)


def get_prop(_c, _s, _p, iface, name):
    return props(iface).get(name)


def acquired(c, _name):
    global conn
    conn = c
    node = Gio.DBusNodeInfo.new_for_xml(XML)
    for i in node.interfaces:
        c.register_object("/org/mpris/MediaPlayer2", i, call, get_prop, None)


loop = GLib.MainLoop()
Gio.bus_own_name(Gio.BusType.SESSION, "org.mpris.MediaPlayer2.mock", Gio.BusNameOwnerFlags.NONE,
                 acquired, None, lambda *_: loop.quit())
loop.run()
