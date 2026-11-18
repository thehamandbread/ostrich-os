#!/usr/bin/env bash
# tests/vm/set-mode.sh: change the test VM's screen size (Mutter's DisplayConfig over D-Bus), for
# checks on small screens. Needs the VM running with the desktop logged in.
#
#   set-mode.sh WIDTHxHEIGHT      e.g. 1366x768; the mode must be one the virtual display offers
#   set-mode.sh --list            the modes it offers
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
case ${1:-} in
--list) want=list ;;
[0-9]*x[0-9]*) want=$1 ;;
*)
	echo "usage: set-mode.sh WIDTHxHEIGHT | --list" >&2
	exit 2
	;;
esac
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus;'
"$VM" ssh "$SESSION python3 - $want" <<'PYEND'
import sys

from gi.repository import Gio, GLib

want = sys.argv[1]
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
args = ("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig", "org.gnome.Mutter.DisplayConfig")
serial, monitors, _logical, _props = bus.call_sync(
    args[0], args[1], args[2], "GetCurrentState", None, None, Gio.DBusCallFlags.NONE, -1, None).unpack()
(spec, modes, _mprops) = monitors[0]
connector = spec[0]
names = {}
for mode_id, w, h, rate, *_ in modes:
    names.setdefault(f"{w}x{h}", (mode_id, rate))
if want == "list":
    print(" ".join(sorted(names)))
    sys.exit(0)
if want not in names:
    sys.exit(f"set-mode: no {want} mode; the display offers: {' '.join(sorted(names))}")
mode_id = names[want][0]
config = [(0, 0, 1.0, 0, True, [(connector, mode_id, {})])]
bus.call_sync(args[0], args[1], args[2], "ApplyMonitorsConfig",
              GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})", (serial, 1, config, {})),
              None, Gio.DBusCallFlags.NONE, -1, None)
print(f"set-mode: {want}")
PYEND
