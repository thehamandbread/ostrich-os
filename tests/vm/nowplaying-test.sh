#!/usr/bin/env bash
# tests/vm/nowplaying-test.sh: the now-playing pill (tweaks/nowplaying.js) with a mock player
# (mock-mpris.py), in the test VM (council verdict 2026-10-24, M7).
#
#   nowplaying-test.sh [--snapshot NAME] [--measure]
#
# Installs this checkout's tweaks (and blur, which styles GNOME's media card), leaves the pill at its
# default (on), then checks the top bar to the right of the clock: nothing while no player runs or
# while a track is only paused; the pill once it plays (out of the clock, owner 2026-11-02);
# nothing for a player with no title (a page that only registered a media session); gone again a
# few seconds after it stops or quits; the shortcut pauses and plays; the drop-down opens; no JS
# errors.
# Screenshots go to $VM_DIR/nowplaying-test.
# --measure then measures the idle cost (experiment E1, measure.sh with SETTLE=30 WINDOW=120, twice
# each): the pill off with a paused player, on with it paused, on with it playing. The verdict's
# line for keeping it on by default: shell CPU <= 0.16 % and wakeups <= 4.4/s (and the owner's
# battery run on real hardware).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
ROOT="$(cd "$HERE/../.." && pwd)"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ubuntu-ostrich/vm}"
OUT="$VM_DIR/nowplaying-test"
SNAPSHOT=post-fresh
MEASURE=0
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	--measure) MEASURE=1 ;;
	*)
		echo "usage: nowplaying-test.sh [--snapshot NAME] [--measure]" >&2
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
step() { printf '== %s\n' "$*"; }
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0;'
run() { "$VM" ssh "$SESSION $*"; }
SCHEMA=org.gnome.shell.extensions.ubuntu-ostrich.tweaks
TS="gsettings --schemadir ~/.local/share/gnome-shell/extensions/tweaks@ubuntu-ostrich/schemas"
player() { run "setsid -f python3 /tmp/mock-mpris.py $1 '$2' >/dev/null 2>&1 </dev/null"; }
quit_player() { run "pkill -f '[m]ock-mpris.py' || true"; }
status() {
	run "gdbus call --session --dest org.mpris.MediaPlayer2.mock --object-path /org/mpris/MediaPlayer2 --method org.freedesktop.DBus.Properties.Get org.mpris.MediaPlayer2.Player PlaybackStatus" |
		grep -o "'[A-Za-z]*'" | tr -d "'"
}
shot() { "$VM" screenshot "$OUT/$1.png" >/dev/null; }
# How much the top bar between the clock and the right-hand icons differs from the first shot.
differs() {
	python3 -I - "$OUT/0-none.png" "$OUT/$1.png" <<'EOF'
import sys
from PIL import Image, ImageChops, ImageStat
a, b = (Image.open(f).convert("L").crop((1010, 0, 1500, 32)) for f in sys.argv[1:3])
sys.exit(0 if ImageStat.Stat(ImageChops.difference(a, b)).mean[0] > 2 else 1)
EOF
}

rm -rf "$OUT"
mkdir -p "$OUT"
"$ROOT/modules/gnome/extensions/build.sh" tweaks blur dock >/dev/null

step "install this checkout's tweaks and blur (the media card's style) on $SNAPSHOT"
"$VM" stop >/dev/null 2>&1 || true
"$VM" snapshot restore "$SNAPSHOT"
"$VM" start
"$VM" copy "$ROOT/dist/tweaks@ubuntu-ostrich.shell-extension.zip" /tmp/tweaks.zip
"$VM" copy "$ROOT/dist/blur@ubuntu-ostrich.shell-extension.zip" /tmp/blur.zip
"$VM" copy "$ROOT/dist/dock@ubuntu-ostrich.shell-extension.zip" /tmp/dock.zip
run "gnome-extensions install --force /tmp/tweaks.zip; gnome-extensions install --force /tmp/blur.zip; gnome-extensions install --force /tmp/dock.zip"
sleep 30 # past the start-up window in which a power-off can make GNOME switch extensions off
"$VM" stop
"$VM" start
sleep 40
"$VM" copy "$HERE/mock-mpris.py" /tmp/mock-mpris.py # after the restart, which empties /tmp
run "$TS reset $SCHEMA now-playing-pill; $TS set $SCHEMA now-playing-play-pause \"['<Super><Alt>p']\""
sleep 2
shot 0-none

step "with nothing playing, the overview doesn't bring the pill out (it sat at the top-left, 2026-11-18)"
"$VM" key meta_l
sleep 2
"$VM" key meta_l
sleep 2
shot 0-after-overview
if python3 -I - "$OUT/0-none.png" "$OUT/0-after-overview.png" <<'EOF'; then ok "still nothing at the top-left or by the clock"; else bad "the pill showed after the overview with nothing playing"; fi
import sys
from PIL import Image, ImageChops, ImageStat
a, b = (Image.open(f).convert("L") for f in sys.argv[1:3])
d = max(ImageStat.Stat(ImageChops.difference(a.crop(r), b.crop(r))).mean[0] for r in ((0, 0, 200, 32), (1010, 0, 1500, 32)))
sys.exit(0 if d <= 2 else 1)
EOF

step "a paused track shows nothing; it comes out of the clock once it plays"
player Paused 'A test song'
sleep 2
shot 1-paused
if differs 1-paused; then bad "paused: shown before anything played"; else ok "paused: nothing yet"; fi
run "gdbus call --session --dest org.mpris.MediaPlayer2.mock --object-path /org/mpris/MediaPlayer2 --method org.mpris.MediaPlayer2.Player.Play >/dev/null"
sleep 2
shot 2-playing
if differs 2-playing; then ok "playing: shown"; else bad "playing: nothing in the top bar"; fi

step "the shortcut pauses and plays"
"$VM" key meta_l-alt-p
sleep 1
if [[ $(status) == Paused ]]; then ok "paused by the shortcut"; else bad "shortcut didn't pause ($(status))"; fi
"$VM" key meta_l-alt-p
sleep 1
if [[ $(status) == Playing ]]; then ok "playing again"; else bad "shortcut didn't play ($(status))"; fi

step "the drop-down opens"
x=$(
	python3 -I - "$OUT/0-none.png" "$OUT/2-playing.png" <<'EOF'
import sys
from PIL import Image, ImageChops
a, b = (Image.open(f).convert("L").crop((1010, 0, 1500, 32)) for f in sys.argv[1:3])
d = ImageChops.difference(a, b)
cols = [x for x in range(d.width) if max(d.getpixel((x, y)) for y in range(d.height)) > 40]
print(1010 + (cols[0] + cols[-1]) // 2 if cols else 0)
EOF
)
"$VM" click "$x" 15 >/dev/null
sleep 1
shot 3-menu
if python3 -I - "$OUT/2-playing.png" "$OUT/3-menu.png" "$x" <<'EOF'; then ok "its menu opened under the pill (x $x)"; else bad "no menu under the pill (x $x)"; fi
import sys
from PIL import Image, ImageChops, ImageStat
x = int(sys.argv[3])
a, b = (Image.open(f).convert("L").crop((max(0, x - 150), 40, x + 150, 200)) for f in sys.argv[1:3])
sys.exit(0 if ImageStat.Stat(ImageChops.difference(a, b)).mean[0] > 8 else 1)
EOF
"$VM" key esc

step "a stopped player, an empty one, and one that quit show nothing"
run "gdbus call --session --dest org.mpris.MediaPlayer2.mock --object-path /org/mpris/MediaPlayer2 --method org.mpris.MediaPlayer2.Player.Stop >/dev/null"
sleep 2
shot 4a-just-stopped
if differs 4a-just-stopped; then ok "just stopped: still shown for a moment"; else bad "just stopped: gone at once"; fi
sleep 7 # HIDE_AFTER_MS (6 s), then back into the clock
shot 4-stopped
if differs 4-stopped; then bad "stopped: still shown"; else ok "stopped: hidden"; fi
quit_player
player Playing ''
sleep 2
shot 5-empty
if differs 5-empty; then bad "a player with no title is shown"; else ok "a player with no title: hidden"; fi
quit_player
player Playing 'Another song'
sleep 2
quit_player
sleep 8 # HIDE_AFTER_MS, then back into the clock
shot 6-quit
if differs 6-quit; then bad "still shown after the player quit"; else ok "the player quit: hidden"; fi

step "the dock: a speaker on the playing app's icon, and its click pauses (DesktopEntry org.gnome.Nautilus = Files)"
quit_player
run "setsid -f python3 /tmp/mock-mpris.py Playing 'A test song' org.gnome.Nautilus >/dev/null 2>&1 </dev/null"
"$VM" move 960 1078 # the dock shows
"$VM" nudge 0 20 30
sleep 2
shot 6b-dock-playing
if spot=$(run "python3 - where 'Files is playing: pause'" <"$HERE/a11y-tree.py" 2>/dev/null); then
	ok "the Files icon shows the speaker (at $spot)"
	read -r sx sy <<<"$spot"
	"$VM" click "$sx" "$sy"
	sleep 1
	if [[ $(status) == Paused ]]; then ok "its click paused the player"; else bad "the speaker's click didn't pause ($(status))"; fi
else
	bad "no speaker on the Files icon"
fi
"$VM" move 960 500
quit_player

step "a 200-character title stays one short pill"
player Playing "$(printf 'Long%.0s' {1..50})"
sleep 2
shot 7-long
quit_player

step "GNOME's media card in the clock menu, light and dark (for review)"
player Playing 'A test song'
sleep 2
for style in default prefer-dark; do
	run "gsettings set org.gnome.desktop.interface color-scheme $style"
	sleep 2
	"$VM" click 960 15 >/dev/null
	sleep 2
	shot "8-media-card-$style"
	"$VM" key esc
	sleep 1
done
quit_player

step "no JS errors"
errors=$(run "journalctl --user -b -o cat | grep -A3 'JS ERROR' | grep -i 'tweaks\|nowplaying' || true")
if [[ -z $errors ]]; then ok "none"; else bad "JS errors: $errors"; fi

if ((MEASURE)); then
	step "E1: idle cost (shell CPU %, wakeups/s; two runs each)"
	"$VM" copy "$HERE/measure.sh" /tmp/measure.sh
	player Paused 'A test song'
	for c in off:Pause on:Pause on:Play; do
		run "$TS set $SCHEMA now-playing-pill $([[ ${c%:*} == on ]] && echo true || echo false)"
		run "gdbus call --session --dest org.mpris.MediaPlayer2.mock --object-path /org/mpris/MediaPlayer2 --method org.mpris.MediaPlayer2.Player.${c#*:} >/dev/null"
		for i in 1 2; do
			m=$(run "SETTLE=30 WINDOW=120 bash /tmp/measure.sh" 2>/dev/null | grep -E '^(shell_cpu_pct|shell_wakeups_per_s)=' | tr '\n' ' ')
			printf '  pill %s, after %s, run %s: %s\n' "${c%:*}" "${c#*:}" "$i" "$m"
		done
	done
	quit_player
fi

journal_gate
"$VM" stop
echo
if ((failures == 0)); then
	echo "PASS (screenshots in $OUT)"
else
	echo "$failures FAILED (screenshots in $OUT)"
	exit 1
fi
