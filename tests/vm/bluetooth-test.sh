#!/usr/bin/env bash
# tests/vm/bluetooth-test.sh: the recent-device tiles in quick settings (council 2026-11-09, S1).
#
#   bluetooth-test.sh [--snapshot NAME]     (default: try-me-0.3.0; needs the Ostrich desktop in it)
#
# Installs this checkout's tweaks, puts mock-bluez.py on the VM's system bus (one adapter, three paired
# devices; "Mock Keyboard" never connects), then checks:
#   - with quick settings closed no device tile exists;
#   - open, the three tiles are there; one press connects the earbuds, one more disconnects them;
#   - a device that connects from outside while the menu is open shows it;
#   - a device that fails says so in text ("Couldn't connect");
#   - with the adapter off, or quick-settings-style 'stock', no tiles;
#   - 20 open/close cycles grow gnome-shell by under 10 MB (the client is freed on close);
#   - the journal gate.
# Screenshots go to $VM_DIR/bluetooth-test.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ostrich-os/vm}"
OUT="$VM_DIR/bluetooth-test"
SNAPSHOT=try-me-0.3.0
QS_XY="${QS_XY:-1880 15}"
RSS_LIMIT_MB="${RSS_LIMIT_MB:-10}"
FAILED_TEXT="Couldn't connect"
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	*)
		echo "usage: bluetooth-test.sh [--snapshot NAME]" >&2
		exit 2
		;;
	esac
	shift
done

failures=0
ok() { printf '  ok: %s\n' "$*"; }
bad() {
	printf '  FAIL: %s\n' "$*"
	failures=$((failures + 1))
}
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0;'
run() { "$VM" ssh "$SESSION $*"; }
tree() { run "python3 - $*" <"$HERE/a11y-tree.py"; }
shot() { "$VM" screenshot "$OUT/$1.png" >/dev/null; }
style() { run "dconf write /org/gnome/shell/extensions/ostrich-os/tweaks/quick-settings-style \"'$1'\""; }
# shellcheck disable=SC2016 # expands in the VM
shell_rss_kb() { "$VM" ssh 'awk "/^VmRSS:/{print \$2}" /proc/$(pgrep -u $(id -u) -x gnome-shell | head -1)/status'; }
dev() { echo "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_0$1"; }
connected() { "$VM" ssh "busctl --system get-property org.bluez $(dev "$1") org.bluez.Device1 Connected" | awk '{print $2}'; }
open_qs() {
	"$VM" key esc >/dev/null
	sleep 1
	# shellcheck disable=SC2086 # two coordinates
	"$VM" click $QS_XY >/dev/null
	sleep 1.5
}
close_qs() {
	"$VM" key esc >/dev/null
	sleep 0.5
}
# Names are passed through the VM's shell: an apostrophe is written as '\'' inside the single quotes.
quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
present() { tree showing "$(quote "$1")" >/dev/null 2>&1; }
press() { # name
	local xy
	xy=$(tree showing "$(quote "$1")") || return 1
	# shellcheck disable=SC2086 # two coordinates
	"$VM" click $xy >/dev/null
}

rm -rf "$OUT"
mkdir -p "$OUT"
"$HERE/ext-test.sh" --snapshot "$SNAPSHOT" --cycles 3 tweaks >&2
trap '"$VM" ssh "sudo systemctl stop mock-bluez; sudo rm -f /etc/dbus-1/system.d/mock-bluez.conf" >/dev/null 2>&1 || true; "$VM" stop >/dev/null 2>&1 || true' EXIT
"$VM" ssh "gsettings set org.gnome.desktop.session idle-delay 0; gsettings set org.gnome.desktop.screensaver lock-enabled false"
"$VM" move 960 700
"$VM" copy "$HERE/mock-bluez.py" /tmp/mock-bluez.py >/dev/null
"$VM" copy "$HERE/mock-bluez.conf" /tmp/mock-bluez.conf >/dev/null
"$VM" ssh "sudo systemctl stop bluetooth 2>/dev/null; sudo install -m 644 /tmp/mock-bluez.conf /etc/dbus-1/system.d/mock-bluez.conf && sudo systemctl reload dbus && sudo systemd-run --quiet --unit mock-bluez python3 /tmp/mock-bluez.py on"
sleep 3

echo "== closed: nothing"
close_qs
if present "Mock Earbuds"; then bad "a device tile exists with quick settings closed"; else ok "no device tile while closed"; fi

echo "== open: three tiles, one press connects, one more disconnects"
open_qs
shot open
for n in "Mock Earbuds" "Mock Speaker" "Mock Keyboard"; do
	if present "$n"; then ok "$n has a tile"; else bad "$n has no tile"; fi
done
press "Mock Earbuds" || bad "no Mock Earbuds tile to press"
sleep 0.4
shot connecting
sleep 2.5
if [[ $(connected 1) == true ]]; then ok "one press: connected"; else bad "one press: not connected"; fi
shot connected
press "Mock Earbuds" || true
sleep 1.5
if [[ $(connected 1) == false ]]; then ok "second press: disconnected"; else bad "second press: still connected"; fi

echo "== a device that connects from outside while the menu is open"
if present Connected; then bad "a tile says Connected before anything is connected"; fi
"$VM" ssh "busctl --system call org.bluez $(dev 2) org.bluez.Device1 Connect" >/dev/null
sleep 1.5
shot outside
if present Connected; then ok "the Speaker tile follows a connect from outside"; else bad "the Speaker tile still says Not connected"; fi
"$VM" ssh "busctl --system call org.bluez $(dev 2) org.bluez.Device1 Disconnect" >/dev/null

echo "== a device that fails says so"
press "Mock Keyboard" || bad "no Mock Keyboard tile to press"
sleep 2.5
shot failed
if present "$FAILED_TEXT"; then ok "the failure is in text"; else bad "no failure text on the tile"; fi

echo "== adapter off, then style stock: no tiles"
"$VM" ssh "sudo busctl --system set-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered b false"
sleep 1
open_qs
shot adapter-off
if present "Mock Speaker"; then bad "tiles show with the adapter off"; else ok "adapter off: no tiles"; fi
"$VM" ssh "sudo busctl --system set-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered b true"
style stock
sleep 2
open_qs
if present "Mock Speaker"; then bad "stock style still shows device tiles"; else ok "stock style: no tiles"; fi
style ostrich
sleep 2
open_qs
if present "Mock Speaker"; then ok "ostrich style: tiles are back"; else bad "ostrich style: no tiles"; fi
close_qs

echo "== 20 open/close cycles: the client is freed on close"
for _ in 1 2 3; do open_qs && close_qs; done
rss0=$(shell_rss_kb)
for _ in $(seq 20); do open_qs && close_qs; done
rss1=$(shell_rss_kb)
grew=$(((rss1 - rss0) / 1024))
if ((grew < RSS_LIMIT_MB)); then ok "gnome-shell grew ${grew} MB over 20 cycles"; else bad "gnome-shell grew ${grew} MB over 20 cycles (limit $RSS_LIMIT_MB)"; fi

echo "== journal"
journal_gate

if ((failures > 0)); then
	echo "FAIL: $failures problem(s); screenshots in $OUT"
	exit 1
fi
echo PASS
