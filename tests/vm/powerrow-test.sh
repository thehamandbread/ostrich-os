#!/usr/bin/env bash
# tests/vm/powerrow-test.sh: the Saver | Balanced | Performance row in quick settings (council 2026-11-09).
#
#   powerrow-test.sh [--snapshot NAME]     (default: try-me; needs the Ostrich desktop in it)
#
# Installs this checkout's tweaks and gives the VM three power profiles (ppd-three.sh), then checks:
#   - each segment is one click after quick settings is open, and power-profiles-daemon agrees;
#   - the keyboard works: Right or Left, then Enter, picks the next or the previous mode;
#   - GNOME's own tile stays hidden through the changes (its slot, beside the Wired tile, stays empty);
#   - GNOME's top-bar power icon still follows the mode while its tile is hidden;
#   - quick-settings-style 'stock' brings GNOME's tile back, 'ostrich' the row;
#   - with two profiles the row is gone and GNOME's tile is back;
#   - the journal gate.
# Screenshots go to $VM_DIR/powerrow-test.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ostrich-os/vm}"
OUT="$VM_DIR/powerrow-test"
SNAPSHOT=try-me
QS_XY="${QS_XY:-1880 15}"
SAVER_XY="${SAVER_XY:-1600 228}"
BALANCED_XY="${BALANCED_XY:-1711 228}"
PERFORMANCE_XY="${PERFORMANCE_XY:-1832 228}"
TABS_TO_SAVER="${TABS_TO_SAVER:-9}"       # Tab stops from a fresh quick settings to Power Saver (the focus ring in keys-focus.png shows it)
SLOT_BOX="${SLOT_BOX:-1725,150,1895,195}" # beside the Wired tile: GNOME's Power Mode tile sits here when it shows
ICONS_BOX="${ICONS_BOX:-1650,0,1920,32}"  # the quick-settings icons in the top bar, where GNOME shows the power mode
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	*)
		echo "usage: powerrow-test.sh [--snapshot NAME]" >&2
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
style() { "$VM" ssh "$SESSION dconf write /org/gnome/shell/extensions/ostrich-os/tweaks/quick-settings-style \"'$1'\""; }
shot() { "$VM" screenshot "$OUT/$1.png" >/dev/null; }
mode() { "$VM" ssh "powerprofilesctl get"; }
# Opens quick settings (closes it first, so the shot is of a fresh menu).
open_qs() {
	"$VM" key esc >/dev/null
	sleep 1
	# shellcheck disable=SC2086 # two coordinates
	"$VM" click $QS_XY >/dev/null
	sleep 1.5
}
# Contrast (standard deviation) of a box: a tile with text in it is high, glass alone is low.
contrast() { # png x0,y0,x1,y1
	python3 -I - "$@" <<'PYEND'
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("L").crop(tuple(int(v) for v in sys.argv[2].split(",")))
print(round(ImageStat.Stat(im).stddev[0]))
PYEND
}
differ() { # png png: the icons box differs (6+ pixels changed, the same mode gives 0: Yaru's saver and performance icons differ only in the needle)
	python3 -I - "$ICONS_BOX" "$@" <<'PYEND'
import sys
from PIL import Image, ImageChops
box = tuple(int(v) for v in sys.argv[1].split(","))
a, b = (Image.open(f).convert("L").crop(box) for f in sys.argv[2:4])
sys.exit(0 if sum(v > 60 for v in ImageChops.difference(a, b).tobytes()) >= 6 else 1)
PYEND
}
slot_empty() { # name: the stock tile is hidden
	local c
	c=$(contrast "$OUT/$1.png" "$SLOT_BOX") || return 1
	((c < 8))
}

rm -rf "$OUT"
mkdir -p "$OUT"
"$HERE/ext-test.sh" --snapshot "$SNAPSHOT" --cycles 3 tweaks >&2
trap '"$VM" stop >/dev/null 2>&1 || true' EXIT
"$VM" ssh "gsettings set org.gnome.desktop.session idle-delay 0; gsettings set org.gnome.desktop.screensaver lock-enabled false"
"$VM" move 960 700
"$HERE/ppd-three.sh" >&2
sleep 3

echo "== three profiles: one click each"
"$VM" ssh "sudo powerprofilesctl set balanced"
open_qs
shot three-0
for want in power-saver performance balanced; do
	case $want in
	power-saver) xy=$SAVER_XY ;;
	performance) xy=$PERFORMANCE_XY ;;
	balanced) xy=$BALANCED_XY ;;
	esac
	# shellcheck disable=SC2086 # two coordinates
	"$VM" click $xy >/dev/null
	sleep 1.5
	got=$(mode)
	shot "three-$want"
	if [[ $got == "$want" ]]; then ok "one click on $want: the daemon says $got"; else bad "clicked $want, the daemon says $got"; fi
	if slot_empty "three-$want"; then ok "$want: GNOME's tile stays hidden"; else bad "$want: GNOME's tile is back beside Wired"; fi
done

echo "== keyboard: Tab reaches the row, Enter picks, Right moves on"
"$VM" ssh "sudo powerprofilesctl set performance"
open_qs
for _ in $(seq "$TABS_TO_SAVER"); do
	"$VM" key tab >/dev/null
	sleep 0.3
done
shot keys-focus
"$VM" key ret >/dev/null
sleep 1.5
got=$(mode)
if [[ $got == power-saver ]]; then ok "Tab x$TABS_TO_SAVER then Enter: $got"; else bad "Tab x$TABS_TO_SAVER then Enter gave $got (want power-saver)"; fi
"$VM" key right >/dev/null
sleep 0.5
"$VM" key ret >/dev/null
sleep 1.5
got=$(mode)
if [[ $got == balanced ]]; then ok "Right then Enter: $got"; else bad "Right then Enter gave $got (want balanced)"; fi
open_qs
"$VM" ssh "sudo powerprofilesctl set balanced"

echo "== a change from outside (the daemon's own)"
"$VM" ssh "sudo powerprofilesctl set performance"
sleep 2
shot outside
if slot_empty outside; then ok "GNOME's tile stays hidden after a change from outside"; else bad "after a change from outside GNOME's tile is back"; fi
"$VM" ssh "sudo powerprofilesctl set balanced"

echo "== GNOME's top-bar power icon follows the mode (it stuck on the first one: owner, 2026-11-18)"
"$VM" key esc >/dev/null
for m in performance power-saver balanced performance; do
	"$VM" ssh "sudo powerprofilesctl set $m"
	sleep 2
	shot "icon-$m"
done
if differ "$OUT/icon-performance.png" "$OUT/icon-power-saver.png"; then ok "the icon changes from performance to power saver"; else bad "the icon stays the same in performance and power saver"; fi
if differ "$OUT/icon-power-saver.png" "$OUT/icon-balanced.png"; then ok "the icon changes from power saver to balanced"; else bad "the icon stays the same in power saver and balanced"; fi
"$VM" ssh "sudo powerprofilesctl set balanced"

echo "== quick-settings-style = stock: GNOME's tile is back, then ostrich: the row again"
style stock
sleep 2
open_qs
shot style-stock
if slot_empty style-stock; then bad "stock: GNOME's tile is still hidden"; else ok "stock: GNOME's tile is back beside Wired"; fi
style ostrich
sleep 2
open_qs
shot style-ostrich
if slot_empty style-ostrich; then ok "ostrich: the row replaces it again"; else bad "ostrich: GNOME's tile is still showing"; fi

echo "== two profiles: GNOME's tile again"
"$HERE/ppd-three.sh" --off >&2
sleep 4
open_qs
shot two
if slot_empty two; then bad "with two profiles GNOME's tile is missing"; else ok "with two profiles GNOME's tile is back beside Wired"; fi

echo "== journal"
journal_gate

if ((failures > 0)); then
	echo "FAIL: $failures problem(s); screenshots in $OUT"
	exit 1
fi
echo PASS
