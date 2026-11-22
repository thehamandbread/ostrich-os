#!/usr/bin/env bash
# tests/vm/overview-test.sh: the dock's Show Apps button in the test VM (owner, 2026-11-20).
#
#   overview-test.sh [--snapshot NAME] [--out DIR]     (default snapshot: try-me)
#
# This checkout's dock replaces the installed one; a Files window is open, so "the window you were
# in" is something to come back to. Then, by screenshots:
#   - Super shows the window picker and Esc closes it (the baseline pictures);
#   - the button with the overview closed shows the app grid (not the window picker);
#   - the button again closes the overview: the desktop is as it was, window and all;
#   - after Super (window picker showing) the button goes to the app grid;
#   - the button again closes the overview;
#   - the journal gate.
# Screenshots go to DIR for a look.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
ROOT="$(cd "$HERE/../.." && pwd)"
VM="$HERE/vm.sh"
PROJECT="ostrich-os"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
SNAPSHOT=try-me
OUT="$VM_DIR/overview-test"
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	--out) OUT=$2 && shift ;;
	*)
		echo "usage: overview-test.sh [--snapshot NAME] [--out DIR]" >&2
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
shot() { "$VM" screenshot "$OUT/$1.png" >/dev/null; }
step() { printf '== %s\n' "$*"; }
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0;'
run() { "$VM" ssh "$SESSION $*"; }
# Mean per-pixel difference (0-255) of two screenshots over the middle of the screen, where the
# windows, the window picker and the app grid are; the top bar and the dock are left out.
diff_mid() { # a b
	python3 -I - "$OUT/$1.png" "$OUT/$2.png" <<'PYEND'
import sys
from PIL import Image, ImageChops, ImageStat
a, b = (Image.open(f).convert("L").crop((200, 100, 1720, 880)) for f in sys.argv[1:3])
print(round(ImageStat.Stat(ImageChops.difference(a, b)).mean[0], 1))
PYEND
}
# The dock's last icon is Show Apps: its x is the dock's right edge less its padding. The edge is
# where the row through the icons first differs from the wallpaper (taken at x = 1500) scanning in.
dock_x() { # png
	python3 -I - "$OUT/$1.png" <<'PYEND'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("L")
y = 1028
bg = im.getpixel((1500, y))
edge = next((x for x in range(1500, 900, -1) if abs(im.getpixel((x, y)) - bg) > 14), 0)
print(edge - 40 if edge else 0)
PYEND
}
less_than() { python3 -I -c "import sys; sys.exit(0 if float('$1') < float('$2') else 1)"; }

rm -rf "$OUT"
mkdir -p "$OUT"

step "start from $SNAPSHOT with this checkout's dock"
"$VM" stop
"$VM" snapshot restore "$SNAPSHOT"
"$VM" start
sleep 10
"$ROOT/modules/gnome/extensions/build.sh" dock >/dev/null
"$VM" copy "$ROOT/dist/dock@ostrich-os.shell-extension.zip" /tmp/dock.zip
run "gnome-extensions install --force /tmp/dock.zip"
"$VM" stop
"$VM" start
sleep 40
run "pkill -x ostrich-setup || true"
run "gsettings set org.gnome.desktop.session idle-delay 0"
run "setsid -f gtk-launch org.gnome.Nautilus.desktop </dev/null >/dev/null 2>&1"
sleep 6
"$VM" move 960 400
sleep 1

step "baselines: the desktop with its window, and the window picker (Super)"
shot 00-desktop
"$VM" key meta_l
sleep 2
shot 01-picker
"$VM" key esc
sleep 2
shot 02-closed
if less_than "$(diff_mid 00-desktop 02-closed)" 3; then ok "Esc closes the window picker: back to the desktop"; else bad "the desktop changed after Super and Esc"; fi
if less_than 6 "$(diff_mid 00-desktop 01-picker)"; then ok "the window picker looks different from the desktop"; else bad "Super showed no window picker"; fi
bx=$(dock_x 00-desktop)
echo "    Show Apps icon at x=$bx"
if ((bx > 700 && bx < 1400)); then ok "found the Show Apps icon"; else bad "could not find the Show Apps icon (x=$bx)"; fi

step "the button with the overview closed: the app grid"
"$VM" click "$bx" 1028
sleep 2
shot 03-grid
if less_than 6 "$(diff_mid 03-grid 01-picker)"; then ok "it is the app grid, not the window picker"; else bad "the button showed the window picker"; fi

step "the button again: back to the window you were in"
"$VM" click "$bx" 1028
sleep 2
shot 04-back
if less_than "$(diff_mid 00-desktop 04-back)" 3; then ok "back to the desktop and its window"; else bad "the second press did not return to the window (diff $(diff_mid 00-desktop 04-back))"; fi

step "after Super (window picker showing) the button goes to the app grid"
"$VM" key meta_l
sleep 2
"$VM" click "$bx" 1028
sleep 2
shot 05-grid-after-super
if less_than "$(diff_mid 03-grid 05-grid-after-super)" 3; then ok "the same app grid"; else bad "after Super the button did not show the app grid (diff $(diff_mid 03-grid 05-grid-after-super))"; fi
"$VM" click "$bx" 1028
sleep 2
shot 06-back-again
if less_than "$(diff_mid 00-desktop 06-back-again)" 3; then ok "and again back to the window"; else bad "the press from that app grid did not return to the window"; fi

journal_gate
"$VM" stop
echo
if ((failures == 0)); then echo "PASS (screenshots in $OUT)"; else echo "$failures FAILED (screenshots in $OUT)"; fi
((failures == 0))
