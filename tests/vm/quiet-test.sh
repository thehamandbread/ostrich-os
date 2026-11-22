#!/usr/bin/env bash
# tests/vm/quiet-test.sh: the clock menu's Do Not Disturb and Focus switches (council 2026-11-09).
#
#   quiet-test.sh [--snapshot NAME]     (default: try-me; needs the Ostrich desktop in it)
#
# Installs this checkout's tweaks and focus, then checks that each switch, GNOME's tile or a script
# are three handles on one state: a click on a switch changes the setting, a change from outside
# changes the switch, and Focus mutes banners and gives them back. Screenshots go to $VM_DIR/quiet-test.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ostrich-os/vm}"
OUT="$VM_DIR/quiet-test"
SNAPSHOT=try-me
CLOCK_XY="${CLOCK_XY:-960 15}"
DND_XY="${DND_XY:-1160 143}"
FOCUS_XY="${FOCUS_XY:-1160 185}"
DND_BOX="${DND_BOX:-1015,125,1295,160}"
FOCUS_BOX="${FOCUS_BOX:-1015,168,1295,203}"
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	*)
		echo "usage: quiet-test.sh [--snapshot NAME]" >&2
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
FOCUS_GS="gsettings --schemadir \$HOME/.local/share/gnome-shell/extensions/focus@ostrich-os/schemas"
banners() { run "gsettings get org.gnome.desktop.notifications show-banners"; }
focus_on() { run "$FOCUS_GS get org.gnome.shell.extensions.ostrich-os.focus focus-on"; }
shot() { "$VM" screenshot "$OUT/$1.png" >/dev/null; }
open_menu() {
	"$VM" key esc >/dev/null
	sleep 1
	# shellcheck disable=SC2086 # two coordinates
	"$VM" click $CLOCK_XY >/dev/null
	sleep 1.5
}
# Mean brightness of a box: a lit row (the accent) is brighter or darker than a grey one.
mean() { # png x0,y0,x1,y1
	python3 -I - "$@" <<'PYEND'
import sys
from PIL import Image, ImageStat
print(round(ImageStat.Stat(Image.open(sys.argv[1]).convert("L").crop(tuple(int(v) for v in sys.argv[2].split(",")))).mean[0]))
PYEND
}
# lit NAME BOX: is the row in the shot lit? (against the unlit reference in $off_dnd/$off_focus)
differs() { python3 -c "import sys; sys.exit(0 if abs($1 - $2) >= 8 else 1)"; }

rm -rf "$OUT"
mkdir -p "$OUT"
"$HERE/ext-test.sh" --snapshot "$SNAPSHOT" --cycles 3 tweaks focus >&2
trap '"$VM" stop >/dev/null 2>&1 || true' EXIT
run "gsettings set org.gnome.desktop.session idle-delay 0; gsettings set org.gnome.desktop.screensaver lock-enabled false; gsettings set org.gnome.desktop.notifications show-banners true"
"$VM" move 960 700
sleep 2
open_menu
shot off
off_dnd=$(mean "$OUT/off.png" "$DND_BOX")
off_focus=$(mean "$OUT/off.png" "$FOCUS_BOX")

echo "== Do Not Disturb"
# shellcheck disable=SC2086
"$VM" click $DND_XY >/dev/null
sleep 1
if [[ $(banners) == false ]]; then ok "a click on the switch turned banners off"; else bad "a click on the switch left banners on"; fi
shot dnd-on
if differs "$(mean "$OUT/dnd-on.png" "$DND_BOX")" "$off_dnd"; then ok "the switch shows it is on"; else bad "the switch looks the same on and off"; fi
# shellcheck disable=SC2086
"$VM" click $DND_XY >/dev/null
sleep 1
if [[ $(banners) == true ]]; then ok "a second click turned banners back on"; else bad "a second click did not turn banners on"; fi
run "gsettings set org.gnome.desktop.notifications show-banners false"
sleep 1
shot dnd-outside
if differs "$(mean "$OUT/dnd-outside.png" "$DND_BOX")" "$off_dnd"; then ok "a change from outside moves the switch"; else bad "the switch did not follow a change from outside"; fi
run "gsettings set org.gnome.desktop.notifications show-banners true"
sleep 1

echo "== Focus"
# shellcheck disable=SC2086
"$VM" click $FOCUS_XY >/dev/null
sleep 2
if [[ $(focus_on) == true ]]; then ok "a click on the switch turned focus on"; else bad "a click on the switch left focus off ($(focus_on))"; fi
if [[ $(banners) == false ]]; then ok "focus muted the banners"; else bad "focus left banners on"; fi
shot focus-on
open_menu
shot focus-on-menu
if differs "$(mean "$OUT/focus-on-menu.png" "$FOCUS_BOX")" "$off_focus"; then ok "the switch shows it is on"; else bad "the Focus switch looks the same on and off"; fi
# shellcheck disable=SC2086
"$VM" click $FOCUS_XY >/dev/null
sleep 2
if [[ $(focus_on) == false ]]; then ok "a second click turned focus off"; else bad "a second click left focus on"; fi
if [[ $(banners) == true ]]; then ok "banners are back"; else bad "banners were not given back"; fi
run "$FOCUS_GS set org.gnome.shell.extensions.ostrich-os.focus focus-on true"
sleep 2
if [[ $(banners) == false ]]; then ok "setting focus-on from outside turned focus on (banners muted)"; else bad "focus-on from outside did nothing"; fi
run "$FOCUS_GS set org.gnome.shell.extensions.ostrich-os.focus focus-on false"
sleep 2
if [[ $(banners) == true ]]; then ok "and off again"; else bad "focus-on false from outside left banners muted"; fi

echo "== journal"
journal_gate

if ((failures > 0)); then
	echo "FAIL: $failures problem(s); screenshots in $OUT"
	exit 1
fi
echo PASS
