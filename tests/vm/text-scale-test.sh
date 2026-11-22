#!/usr/bin/env bash
# tests/vm/text-scale-test.sh: the clock menu and the monitor popup follow the text size, in the test
# VM (council verdict 2026-11-05-the-ostrich-look, M5: in px they stayed the same size beside 200 %
# text, and the clock menu's date and "Add World Clocks" button were cut off).
#
#   text-scale-test.sh [--snapshot NAME]     (default: try-me; needs the Ostrich desktop in it)
#
# Installs this checkout's monitor and tweaks (ext-test.sh), then at text scale 1.0 and 2.0 opens the
# clock menu and the monitor popup and measures each (the box that changed against the closed desktop).
#   - at 1.0 the clock menu is what it was in px, 706 x 484 by this method (the owner's 680 x 460 plus
#     the menu's margin; the px build measured exactly that), within 6 px;
#   - at 2.0 the clock menu and the monitor popup are 1.8 to 2.2 times as wide as at 1.0.
# Screenshots go to $VM_DIR/text-scale-test: look at the 2.0 shots for text cut off with "..." (the
# size can be right while a line is still too long). The journal gate fails it on a JS error or a
# warning from our code too. A last phase switches the VM to 1360x768 (set-mode.sh) and checks the
# monitor popup's footer buttons are still on screen at 1.0 and 2.0 text.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ostrich-os/vm}"
OUT="$VM_DIR/text-scale-test"
SNAPSHOT=try-me
MONITOR_X="${MONITOR_X:-265}" # the monitor's pill in the top bar
CLOCK_W="${CLOCK_W:-706}"     # the px build, measured the same way
CLOCK_H="${CLOCK_H:-484}"
PHOTO=/usr/share/backgrounds/mendhak-Red_Acer.jpg
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	*)
		echo "usage: text-scale-test.sh [--snapshot NAME]" >&2
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

# width and height of what changed against the closed desktop, below the top bar
size() { # closed-image open-image
	python3 -I - "$1" "$2" <<'PYEND'
import sys
from PIL import Image, ImageChops

diff = ImageChops.difference(Image.open(sys.argv[1]).convert("RGB"), Image.open(sys.argv[2]).convert("RGB")).convert("L").point(lambda v: 255 if v > 12 else 0)
box = diff.crop((0, 40, diff.width, diff.height)).getbbox()
print(*((box[2] - box[0], box[3] - box[1]) if box else (0, 0)))
PYEND
}

rm -rf "$OUT"
mkdir -p "$OUT"
"$HERE/ext-test.sh" --snapshot "$SNAPSHOT" --cycles 3 monitor tweaks >&2
trap '"$VM" stop >/dev/null 2>&1 || true' EXIT
run "for k in picture-uri picture-uri-dark; do gsettings set org.gnome.desktop.background \$k file://$PHOTO; done; gsettings set org.gnome.desktop.session idle-delay 0; gsettings set org.gnome.desktop.screensaver lock-enabled false; gsettings set org.gnome.desktop.interface color-scheme prefer-dark"

for scale in 1.0 2.0; do
	echo "== text scale $scale"
	run "gsettings set org.gnome.desktop.interface text-scaling-factor $scale"
	sleep 5
	"$VM" move 960 700
	sleep 2
	"$VM" screenshot "$OUT/$scale-closed.png" >/dev/null
	"$VM" click 960 15 # the clock
	sleep 4
	"$VM" screenshot "$OUT/$scale-clock.png" >/dev/null
	"$VM" key esc
	sleep 2
	"$VM" click "$MONITOR_X" 15
	sleep 4
	"$VM" screenshot "$OUT/$scale-monitor.png" >/dev/null
	"$VM" key esc
	sleep 2
done
run "gsettings set org.gnome.desktop.interface text-scaling-factor 1.0"

read -r cw1 ch1 <<<"$(size "$OUT/1.0-closed.png" "$OUT/1.0-clock.png")"
read -r cw2 ch2 <<<"$(size "$OUT/2.0-closed.png" "$OUT/2.0-clock.png")"
read -r mw1 mh1 <<<"$(size "$OUT/1.0-closed.png" "$OUT/1.0-monitor.png")"
read -r mw2 mh2 <<<"$(size "$OUT/2.0-closed.png" "$OUT/2.0-monitor.png")"
echo "== sizes"
echo "    clock menu:    1.0: ${cw1}x${ch1}   2.0: ${cw2}x${ch2}"
echo "    monitor popup: 1.0: ${mw1}x${mh1}   2.0: ${mw2}x${mh2}"

within() { # value target tolerance
	(($1 >= $2 - $3 && $1 <= $2 + $3))
}
if within "$cw1" "$CLOCK_W" 6 && within "$ch1" "$CLOCK_H" 6; then
	ok "clock menu at 1.0 is ${cw1}x${ch1} (as in px: ${CLOCK_W}x${CLOCK_H})"
else
	bad "clock menu at 1.0 is ${cw1}x${ch1}, not ${CLOCK_W}x${CLOCK_H} (6 px)"
fi
ratio() { # name bigger smaller
	if (($2 * 10 >= $3 * 18 && $2 * 10 <= $3 * 22)); then
		ok "$1 at 2.0 is $2 px wide against $3 at 1.0 (follows the text size)"
	else
		bad "$1 at 2.0 is $2 px wide against $3 at 1.0 (should be 1.8 to 2.2 times)"
	fi
}
ratio "clock menu" "$cw2" "$cw1"
ratio "monitor popup" "$mw2" "$mw1"
echo "    look at 2.0-clock.png and 2.0-monitor.png: no label cut off with an ellipsis"

echo "== small screen (1360x768): the popup fits, with its headers readable and its footer on screen"
# The popup restores Processor, Memory, Network and Storage open (about 860 px on a tall screen) only while
# it still fits the screen. Squeezed in anyway, the headers collapsed to slivers and the rows scrolled out
# of sight at 2.0 text. So: the footer's settings button is on screen, and every section header is at
# at least HEADER_PX (times the text scale) tall, at 1.0 and 2.0.
SCREEN_H=768
HEADER_PX="${HEADER_PX:-14}" # the least a header's label may be at 1.0 text (its natural height is 18); it grows with the text
tree() { run "python3 - $*" <"$HERE/a11y-tree.py"; }
"$HERE/set-mode.sh" "1360x$SCREEN_H" >&2
sleep 5
for scale in 1.0 2.0; do
	run "gsettings set org.gnome.desktop.interface text-scaling-factor $scale"
	sleep 5
	"$VM" move 700 500
	read -r px py < <(tree where Monitor) # the pill moves with the text size: find it by name
	"$VM" click "$px" "$py"
	sleep 5
	"$VM" screenshot "$OUT/small-$scale-monitor.png" >/dev/null
	if spot=$(tree showing "'Monitor settings'" 2>/dev/null); then
		read -r _ y <<<"$spot"
		if ((y > 0 && y < SCREEN_H)); then ok "text $scale: the footer's settings button is on screen (y $y of $SCREEN_H)"; else bad "text $scale: the footer's settings button is at y $y, off a $SCREEN_H px screen"; fi
	else
		bad "text $scale: the footer's settings button is not on screen"
	fi
	header_min=$(awk -v s="$scale" -v p="$HEADER_PX" 'BEGIN { print int(p * s) }')
	for header in Processor Memory Network Storage; do
		if read -r _ _ _ h < <(tree box "$header" 2>/dev/null); then
			if ((h >= header_min)); then ok "text $scale: the $header header is $h px tall"; else bad "text $scale: the $header header is squashed to $h px (needs $header_min)"; fi
		else
			bad "text $scale: no $header header on screen"
		fi
	done
	"$VM" key esc
	sleep 2
done
run "gsettings set org.gnome.desktop.interface text-scaling-factor 1.0"
"$HERE/set-mode.sh" 1920x1080 >&2

echo "== journal"
journal_gate

if ((failures > 0)); then
	echo "FAIL: $failures problem(s); screenshots in $OUT"
	exit 1
fi
echo "PASS (screenshots in $OUT)"
