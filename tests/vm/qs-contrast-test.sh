#!/usr/bin/env bash
# tests/vm/qs-contrast-test.sh: text on lit ("on") quick-settings tiles reaches 4.5:1 (council
# 2026-11-09, test 4: white on the accent measured 3.3-4.2:1 over a photo).
#
#   qs-contrast-test.sh [--snapshot NAME]     (default: try-me; needs the Ostrich desktop in it)
#
# Installs this checkout's tweaks (ext-test.sh, 3 cycles), puts the pack's busy photo behind the
# menus, and measures every text line on the tiles with contrast.sh:
#   - dark style with the accents where white text is weakest: slate, orange, blue, yellow
#     (ACCENTS to change them);
#   - light style;
#   - power saver (solid menus, the Power Mode tile lit), plus the clock menu's "No Notifications".
# The VM has Wired and Dark Style lit, and Power Mode lit in saver; boxes cover the tiles' text
# columns at 1920x1080 (QS_BOXES, CLOCK_BOX to move them). Screenshots go to $VM_DIR/qs-contrast-test.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ostrich-os/vm}"
OUT="$VM_DIR/qs-contrast-test"
SNAPSHOT=try-me
ACCENTS="${ACCENTS:-slate orange blue yellow}"
QS_BOXES="${QS_BOXES:-1566,155,1660,305:left-tiles 1754,152,1855,303:right-tiles}"
CLOCK_BOX="${CLOCK_BOX:-720,316,900,348:no-notifications}"
WALLPAPER=/usr/share/backgrounds/mendhak-Red_Acer.jpg
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	*)
		echo "usage: qs-contrast-test.sh [--snapshot NAME]" >&2
		exit 2
		;;
	esac
	shift
done

failures=0
gs() { "$VM" ssh "gsettings set $*"; }
qs_shot() { # name: open quick settings, screenshot, close
	"$VM" click 1880 15 >/dev/null
	sleep 1.5
	"$VM" screenshot "$OUT/$1.png" >/dev/null
	"$VM" key esc >/dev/null
	sleep 0.8
}
measure() { # png boxes...: --peak, the boxes hold only the tiles' 11 px labels and their fill
	echo "== ${1##*/}"
	"$HERE/contrast.sh" --peak "$@" || failures=$((failures + 1))
}

rm -rf "$OUT"
mkdir -p "$OUT"
"$HERE/ext-test.sh" --snapshot "$SNAPSHOT" --cycles 3 tweaks blur >&2
trap '"$VM" stop >/dev/null 2>&1 || true' EXIT
"$VM" ssh "gsettings set org.gnome.desktop.session idle-delay 0; gsettings set org.gnome.desktop.screensaver lock-enabled false"
"$VM" ssh "for k in picture-uri picture-uri-dark; do gsettings set org.gnome.desktop.background \$k 'file://$WALLPAPER'; done"
"$VM" move 960 900
sleep 2

gs org.gnome.desktop.interface color-scheme prefer-dark
for a in $ACCENTS; do
	gs org.gnome.desktop.interface accent-color "$a"
	sleep 2
	qs_shot "dark-$a"
	# shellcheck disable=SC2086
	measure "$OUT/dark-$a.png" $QS_BOXES
done
"$VM" ssh "gsettings reset org.gnome.desktop.interface accent-color"

gs org.gnome.desktop.interface color-scheme prefer-light
sleep 2
qs_shot light
# shellcheck disable=SC2086
measure "$OUT/light.png" $QS_BOXES

gs org.gnome.desktop.interface color-scheme prefer-dark
"$VM" ssh "sudo powerprofilesctl set power-saver"
sleep 3
qs_shot saver
# shellcheck disable=SC2086
measure "$OUT/saver.png" $QS_BOXES
"$VM" click 960 15 >/dev/null
sleep 1.5
"$VM" screenshot "$OUT/saver-clock.png" >/dev/null
"$VM" key esc >/dev/null
measure "$OUT/saver-clock.png" "$CLOCK_BOX"
"$VM" ssh "sudo powerprofilesctl set balanced"

if ((failures > 0)); then
	echo "FAIL: $failures screenshot(s) with text under 4.5:1; see $OUT"
	exit 1
fi
echo PASS
