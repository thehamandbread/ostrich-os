#!/usr/bin/env bash
# tests/vm/topbar-test.sh: the owner's 2026-11-09 top-bar fixes, in the test VM.
#
#   topbar-test.sh [--snapshot NAME]     (default: try-me; needs the Ostrich desktop in it)
#
# Installs this checkout's monitor, workspaces and tweaks (ext-test.sh, 3 cycles), then checks:
#   - scroll: a fast flick of 5 wheel clicks over the top bar moves one workspace; two flicks a
#     second apart move two; back up the same way (the active pill is the brightest of the five);
#   - no hover: resting on the clock does not open its menu (owner, 2026-11-18: click only);
#   - no activation: a menu opened by a click or by key changes nothing while the pointer
#     sweeps over its rows, and the click that closes it only closes it (Do Not Disturb, Focus, the
#     style and the power mode are read before and after; council 2026-11-09);
#   - power saver: the monitor's readings fold away to one icon, and come back on Balanced;
#   - the journal gate.
#   - hot corner: pushing up into the top-right corner (relative motion, vm.sh nudge, since GNOME's
#     pressure barriers ignore the VM's absolute tablet) opens quick settings, twice in a row; a second
#     push while it is open closes it, as the top-left corner toggles the overview; and it does not
#     open with quick-settings-corner off. A second monitor's placement is a unit test only
#     (tests/js/corner-place.test.js): the VM has one screen.
# Screenshots go to $VM_DIR/topbar-test.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ostrich-os/vm}"
OUT="$VM_DIR/topbar-test"
SNAPSHOT="try-me"
PILLS="${PILLS:-24 51 78 105 132}" # x of the five workspace pills (y 15)
SCROLL_XY="${SCROLL_XY:-600 15}"   # empty top bar
CLOCK_XY="${CLOCK_XY:-960 15}"
CLOCK_MENU_BOX="${CLOCK_MENU_BOX:-700,60,1220,400}" # under the clock
MONITOR_BOX="${MONITOR_BOX:-200,4,330,28}"          # right of the monitor's first icon: readings or nothing
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	*)
		echo "usage: topbar-test.sh [--snapshot NAME]" >&2
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
shot() { "$VM" screenshot "$OUT/$1.png" >/dev/null; }

# The index (0-4) of the brightest pill: the active one has a fill.
active() {
	shot "$1"
	# shellcheck disable=SC2086 # the x list
	python3 -I - "$OUT/$1.png" $PILLS <<'EOF'
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("L")
means = [ImageStat.Stat(im.crop((int(x) - 8, 6, int(x) + 8, 24))).mean[0] for x in sys.argv[2:]]
print(means.index(max(means)))
EOF
}

# Mean brightness and contrast of a box: "std mean".
stats() { # png x0,y0,x1,y1
	python3 -I - "$@" <<'EOF'
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("L").crop(tuple(int(v) for v in sys.argv[2].split(",")))
st = ImageStat.Stat(im)
print(round(st.stddev[0]), round(st.mean[0]))
EOF
}

rm -rf "$OUT"
mkdir -p "$OUT"
"$HERE/ext-test.sh" --snapshot "$SNAPSHOT" --cycles 3 monitor workspaces tweaks >&2
trap '"$VM" stop >/dev/null 2>&1 || true' EXIT
run "gsettings set org.gnome.desktop.session idle-delay 0; gsettings set org.gnome.desktop.screensaver lock-enabled false"
"$VM" move 960 700
sleep 2

echo "== scroll: one movement, one workspace"
start=$(active scroll-0)
[[ $start -le 2 ]] || {
	"$VM" key meta_l-home
	sleep 2
	start=$(active scroll-0)
}
# shellcheck disable=SC2086 # two coordinates
"$VM" scroll $SCROLL_XY down 5
sleep 1.5
a=$(active scroll-1)
if ((a == start + 1)); then ok "a flick of 5 wheel clicks moved one ($start -> $a)"; else bad "a flick of 5 clicks moved from $start to $a (want $((start + 1)))"; fi
# shellcheck disable=SC2086
"$VM" scroll $SCROLL_XY down 1
sleep 1
# shellcheck disable=SC2086
"$VM" scroll $SCROLL_XY up 5
sleep 1.5
b=$(active scroll-2)
if ((b == a)); then ok "one more down, then a flick up: back to $b"; else bad "after one down and a flick up: $b (want $a)"; fi
# shellcheck disable=SC2086
"$VM" scroll $SCROLL_XY up 5
sleep 1.5
c=$(active scroll-3)
if ((c == start)); then ok "another flick up: back to $start"; else bad "another flick up: $c (want $start)"; fi

echo "== no hover: resting on the clock opens nothing"
shot hover-0
read -r _ m0 < <(stats "$OUT/hover-0.png" "$CLOCK_MENU_BOX")
# shellcheck disable=SC2086
"$VM" move $CLOCK_XY
sleep 2
shot hover-1
read -r _ m1 < <(stats "$OUT/hover-1.png" "$CLOCK_MENU_BOX")
if ((m1 - m0 <= 4 && m0 - m1 <= 4)); then ok "the clock menu stayed closed (mean $m0 -> $m1)"; else bad "resting opened the clock menu (mean $m0 -> $m1)"; fi
"$VM" move 960 900
sleep 1

echo "== no activation: open without touching a row"
# Everything a row in either menu could change.
state() { run "echo \$(gsettings get org.gnome.desktop.notifications show-banners) \$(gsettings --schemadir \$HOME/.local/share/gnome-shell/extensions/focus@ostrich-os/schemas get org.gnome.shell.extensions.ostrich-os.focus focus-on 2>/dev/null || echo -) \$(gsettings get org.gnome.desktop.interface color-scheme) \$(powerprofilesctl get)"; }
sweep() { for p in "$@"; do
	"$VM" move "${p%,*}" "${p#*,}"
	sleep 0.4
done; }
s0=$(state)
"$VM" move 960 900
sleep 1
# shellcheck disable=SC2086
"$VM" click $CLOCK_XY # the clock menu, by a click
sleep 1.5
sweep 800,150 1100,150 1100,300 800,350 1000,420
"$VM" click 300 800 # outside: closes it
sleep 1
"$VM" move 1000 300 # where the menu's rows will be
"$VM" key meta_l-v  # by key
sleep 1.5
"$VM" key esc
sleep 0.5
"$VM" click 1880 15 # quick settings by a click, then over its tiles
sleep 1.5
sweep 1550,170 1760,170 1550,230 1760,230 1550,290 1760,290
"$VM" click 300 800
sleep 1
shot no-activation
s1=$(state)
if [[ $s1 == "$s0" ]]; then ok "nothing changed ($s1)"; else bad "a row acted: $s0 -> $s1"; fi

echo "== power saver: the monitor's readings fold away"
shot saver-0
read -r r0 _ < <(stats "$OUT/saver-0.png" "$MONITOR_BOX")
"$VM" ssh "sudo powerprofilesctl set power-saver"
sleep 3
shot saver-1
read -r r1 _ < <(stats "$OUT/saver-1.png" "$MONITOR_BOX")
if ((r0 > 20 && r1 < 8)); then ok "readings gone in saver (contrast $r0 -> $r1)"; else bad "saver: contrast right of the icon $r0 -> $r1 (want readings, then blank)"; fi
"$VM" ssh "sudo powerprofilesctl set balanced"
sleep 4
shot saver-2
read -r r2 _ < <(stats "$OUT/saver-2.png" "$MONITOR_BOX")
if ((r2 > 20)); then ok "readings back on Balanced (contrast $r2)"; else bad "readings not back on Balanced (contrast $r2)"; fi

echo "== hot corner: pushing up into the top-right corner opens quick settings"
CORNER_KEY=/org/gnome/shell/extensions/ostrich-os/tweaks/quick-settings-corner
qs_open() { run "python3 - showing 'Dark Style'" <"$HERE/a11y-tree.py" >/dev/null 2>&1; } # a stock tile, on screen only while quick settings is open
push_corner() {
	"$VM" key esc
	sleep 1
	"$VM" move 1700 300
	sleep 1
	"$VM" move 1915 25
	sleep 1
	"$VM" nudge 0 -40 30
	sleep 2
}
for try in 1 2; do
	push_corner
	if qs_open; then ok "push $try: quick settings opened"; else bad "push $try: quick settings did not open"; fi
	shot "corner-$try"
done
"$VM" move 1700 300 # a second push while it is open closes it
sleep 1
"$VM" move 1915 25
sleep 1
"$VM" nudge 0 -40 30
sleep 2
if qs_open; then bad "a second push left quick settings open"; else ok "a second push closed quick settings"; fi
run "dconf write $CORNER_KEY false"
sleep 1
push_corner
if qs_open; then bad "with the corner switched off, quick settings still opened"; else ok "with the corner switched off, nothing opened"; fi
run "dconf write $CORNER_KEY true"
"$VM" key esc
sleep 1

echo "== journal"
journal_gate

if ((failures > 0)); then
	echo "FAIL: $failures problem(s); screenshots in $OUT"
	exit 1
fi
echo PASS
