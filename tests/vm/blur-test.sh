#!/usr/bin/env bash
# tests/vm/blur-test.sh: is the blur frosted, not just see-through? Measured in the test VM.
#
#   blur-test.sh [--snapshot NAME] [--out DIR]
#
# Needs a snapshot with Ubuntu Ostrich installed (default: post-fresh). The blur and dock
# extensions from this checkout replace the installed ones. The wallpaper becomes a black-and-white
# checkerboard (24 px squares); then:
#   - on the open desktop the squares show at full contrast (the check is fair);
#   - behind the top bar they must be blurred away (little contrast left) while the bar stays a
#     mid grey (it shows the content, frosted, rather than covering it);
#   - with the top bar's blur off, the squares behind it don't matter (solid), for comparison.
# Screenshots of the bar, the dock and a menu over the checkerboard go to DIR for a look.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
ROOT="$(cd "$HERE/../.." && pwd)"
VM="$HERE/vm.sh"
PROJECT="ubuntu-ostrich"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
SNAPSHOT=post-fresh
OUT="$VM_DIR/blur-test"
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	--out) OUT=$2 && shift ;;
	*)
		echo "usage: blur-test.sh [--snapshot NAME] [--out DIR]" >&2
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
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus;'
run() { "$VM" ssh "$SESSION $*"; }
# shellcheck disable=SC2016 # expands in the VM
BS='gsettings --schemadir $HOME/.local/share/gnome-shell/extensions/blur@ubuntu-ostrich/schemas'
SCHEMA=org.gnome.shell.extensions.ubuntu-ostrich.blur
# Standard deviation and mean of a box of a screenshot: "std mean".
stats() { # png x0 y0 x1 y1
	python3 -I - "$@" <<'EOF'
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("L").crop(tuple(int(v) for v in sys.argv[2:6]))
st = ImageStat.Stat(im)
print(round(st.stddev[0]), round(st.mean[0]))
EOF
}

rm -rf "$OUT"
mkdir -p "$OUT"

step "start from $SNAPSHOT with this checkout's blur and dock"
"$VM" stop
"$VM" snapshot restore "$SNAPSHOT"
"$VM" start
sleep 10
"$ROOT/modules/gnome/extensions/build.sh" blur dock >/dev/null
for e in blur dock; do
	"$VM" copy "$ROOT/dist/$e@ubuntu-ostrich.shell-extension.zip" "/tmp/$e.zip"
	run "gnome-extensions install --force /tmp/$e.zip"
done
# The checkerboard wallpaper, written with the standard library only.
"$VM" ssh 'python3 -' <<'EOF'
import struct, zlib
W, H, S = 1920, 1080, 24
rows = b"".join(b"\0" + bytes(255 if ((x // S) + (y // S)) % 2 else 0 for x in range(W) for _ in range(3)) for y in range(H))
chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b"")
import os; open(os.path.expanduser("~/checker.png"), "wb").write(png)
EOF
run "for k in picture-uri picture-uri-dark; do gsettings set org.gnome.desktop.background \$k file://\$HOME/checker.png; done"
sleep 30
"$VM" stop
"$VM" start
sleep 30
# A power-off can catch GNOME Shell still starting; it then switches every extension off
# (docs/DECISIONS.md). Measure the blur, not that: switch them back on and log in again.
if [[ $(run "gsettings get org.gnome.shell disable-user-extensions") == true ]]; then
	echo "  (GNOME had switched extensions off after the restart; switching them back on)"
	run "gsettings set org.gnome.shell disable-user-extensions false"
	sleep 30
	"$VM" stop
	"$VM" start
	sleep 30
fi

# The first-login tour (Ostrich Settings) opens over the desktop; it isn't what's measured.
run "pkill -x ostrich-setup || true"
sleep 2
step "the check is fair: the open desktop shows the squares"
shot 01-desktop
read -r dstd dmean < <(stats "$OUT/01-desktop.png" 300 200 900 400)
if ((dstd > 100)); then ok "desktop contrast $dstd (mean $dmean)"; else bad "the checkerboard isn't showing (contrast $dstd)"; fi

step "top bar: frosted"
# A stretch of the bar with no text or icons: between the workspace bar and the clock.
read -r pstd pmean < <(stats "$OUT/01-desktop.png" 420 3 820 29)
echo "    top bar: contrast $pstd, mean $pmean"
if ((pstd <= 20)); then ok "the squares are blurred away behind the bar (contrast $pstd)"; else bad "the bar still shows the squares (contrast $pstd): see-through, not frosted"; fi
if ((pmean >= 40 && pmean <= 200)); then ok "the bar shows the content, frosted (mean $pmean)"; else bad "the bar is nearly solid (mean $pmean)"; fi

step "the top bar blurs only the wallpaper: a window under it changes nothing (notes 20261102-014611, 014923)"
run "setsid ptyxis --new-window --maximize -- bash -c 'while :; do date +%T.%N; sleep 0.05; done' >/dev/null 2>&1 &"
sleep 5
shot 01b-window-under-bar
d=$(
	python3 -I - "$OUT/01-desktop.png" "$OUT/01b-window-under-bar.png" <<'EOF'
import sys
from PIL import Image, ImageChops, ImageStat
a, b = (Image.open(f).convert("L").crop((420, 3, 820, 29)) for f in sys.argv[1:3])
print(round(ImageStat.Stat(ImageChops.difference(a, b)).mean[0]))
EOF
)
run "pkill -x ptyxis || true"
if ((d <= 2)); then ok "the bar looks the same with a window under it (difference $d)"; else bad "the bar shows the window under it (difference $d)"; fi

step "for comparison: the bar's blur off"
run "$BS set $SCHEMA panel false"
sleep 2
shot 02-bar-solid
read -r sstd smean < <(stats "$OUT/02-bar-solid.png" 420 3 820 29)
echo "    blur off: contrast $sstd, mean $smean"
run "$BS set $SCHEMA panel true"
sleep 2

step "dock and a menu over the squares (for a look)"
"$VM" move 960 1078
"$VM" nudge 0 20 30
sleep 1
shot 03-dock
"$VM" move 960 500
sleep 1
"$VM" click 1880 15
sleep 1
shot 04-menu
"$VM" key esc

step "a menu with its blur off is solid, not see-through"
# The clock menu over the squares, blur on (frosted) then off (solid): either way the squares must
# not show through. An empty stretch of its notification pane.
"$VM" move 960 500
for blur in true false; do
	run "$BS set $SCHEMA menus $blur"
	sleep 2
	"$VM" click 960 15
	sleep 2
	shot "05-clock-menu-blur-$blur"
	"$VM" key esc
	sleep 1
	read -r mstd mmean < <(stats "$OUT/05-clock-menu-blur-$blur.png" 640 400 900 440)
	if ((mstd <= 20)); then ok "menu with blur $blur hides the squares (contrast $mstd, mean $mmean)"; else bad "menu with blur $blur shows the squares through it (contrast $mstd)"; fi
done
run "$BS set $SCHEMA menus true"

step "quick settings: a tile's own menu is frosted all the way down (owner, 2026-11-19)"
"$VM" move 960 500
"$VM" click 1880 15
sleep 2
shot 07a-qs
# The Wired tile's arrow opens its list inside the same menu, which grows to make room.
"$VM" click "${QS_ARROW_X:-1705}" "${QS_ARROW_Y:-172}"
sleep 2
shot 07b-qs-submenu
"$VM" key esc
sleep 1
"$VM" key esc
sleep 1

step "power saver: the top bar keeps a wallpaper blur, menus are solid black (owner, 2026-11-01)"
run "sudo powerprofilesctl set power-saver" # SSH isn't the active session polkit allows
sleep 3
"$VM" click 960 15
sleep 2
shot 06-saver-menu
"$VM" key esc
sleep 1
# The quick-settings menu too (note 20261102-014518 was on it): its empty bottom padding.
"$VM" click 1880 15
sleep 2
shot 06b-saver-quick-settings
"$VM" key esc
run "sudo powerprofilesctl set balanced"
sleep 2
read -r sstd smean < <(stats "$OUT/06-saver-menu.png" 640 400 900 440)
if ((sstd <= 8 && smean <= 12)); then ok "menu is solid black (mean $smean, contrast $sstd)"; else bad "menu in power saver: mean $smean, contrast $sstd (want black)"; fi
read -r qstd qmean < <(stats "$OUT/06b-saver-quick-settings.png" 1530 318 1890 327)
if ((qstd <= 8 && qmean <= 12)); then ok "quick settings is solid black (mean $qmean, contrast $qstd)"; else bad "quick settings in power saver: mean $qmean, contrast $qstd (want black)"; fi
read -r bstd bmean < <(stats "$OUT/06-saver-menu.png" 420 3 560 29)
if ((bstd <= 20 && bmean >= 40)); then ok "the top bar is still frosted (contrast $bstd, mean $bmean)"; else bad "top bar in power saver: contrast $bstd, mean $bmean"; fi

step "no JS errors"
n=$(run 'journalctl --user -b -o cat /usr/bin/gnome-shell | grep -c "JS ERROR" || true')
if [[ $n == 0 ]]; then ok "no JS errors"; else bad "$n JS errors"; fi

journal_gate
"$VM" stop
echo
if ((failures == 0)); then echo "PASS (screenshots in $OUT)"; else echo "$failures FAILED (screenshots in $OUT)"; fi
((failures == 0))
