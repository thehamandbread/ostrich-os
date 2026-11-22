#!/usr/bin/env bash
# tests/vm/ui-test.sh: drive our shell extensions in the test VM and check what they do.
#
#   ui-test.sh [--snapshot NAME] [--out DIR]
#
# Installs every extension in modules/gnome/extensions on a clean snapshot (default: stock),
# logs in again, then runs scenarios. Checks that can be automated print "ok:" / "FAIL:"; each step
# also saves a screenshot to DIR (default: $VM_DIR/ui-test) for visual review.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
ROOT="$(cd "$HERE/../.." && pwd)"
VM="$HERE/vm.sh"
PROJECT="ostrich-os"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
SNAPSHOT=stock
OUT="$VM_DIR/ui-test"
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	--out) OUT=$2 && shift ;;
	*)
		echo "usage: ui-test.sh [--snapshot NAME] [--out DIR]" >&2
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
gs() { "$VM" ssh "gsettings $*"; }
# Mean per-pixel difference (0-255) of two screenshots inside a box; empty if PIL is missing.
region_diff() { # a.png b.png x0 y0 x1 y1
	python3 -I - "$@" <<'EOF' 2>/dev/null || true
import sys
from PIL import Image, ImageChops, ImageStat
a, b = (Image.open(f).convert("L") for f in sys.argv[1:3])
box = tuple(int(v) for v in sys.argv[3:7])
print(round(ImageStat.Stat(ImageChops.difference(a.crop(box), b.crop(box))).mean[0]))
EOF
}

rm -rf "$OUT"
mkdir -p "$OUT"

step "build and install all extensions"
mapfile -t names < <(find "$ROOT/modules/gnome/extensions" -mindepth 1 -maxdepth 1 -type d ! -name _lib -printf '%f\n' | sort)
"$ROOT/modules/gnome/extensions/build.sh" "${names[@]}" >/dev/null
"$VM" stop
"$VM" snapshot restore "$SNAPSHOT"
"$VM" start
uuids=()
for n in "${names[@]}"; do
	u=$(sed -n 's/^ *"uuid": *"\([^"]*\)".*/\1/p' "$ROOT/modules/gnome/extensions/$n/metadata.json")
	uuids+=("$u")
	"$VM" copy "$ROOT/dist/$u.shell-extension.zip" "/tmp/$u.zip"
	"$VM" ssh "gnome-extensions install --force /tmp/$u.zip"
done
"$VM" ssh "python3 - ${uuids[*]}" <<'PY'
import ast, subprocess, sys
get = lambda k: ast.literal_eval(subprocess.check_output(["gsettings", "get", "org.gnome.shell", k], text=True).replace("@as ", ""))
replaced = ("ubuntu-dock@ubuntu.com", "ubuntu-appindicators@ubuntu.com", "tiling-assistant@ubuntu.com")  # as the gnome module does
enabled = [u for u in get("enabled-extensions") if u not in replaced]
enabled += [u for u in sys.argv[1:] if u not in enabled]
subprocess.check_call(["gsettings", "set", "org.gnome.shell", "enabled-extensions", str(enabled)])
disabled = get("disabled-extensions") + list(replaced)
subprocess.check_call(["gsettings", "set", "org.gnome.shell", "disabled-extensions", str(disabled)])
PY
"$VM" stop
"$VM" start
sleep 25

step "all extensions active, no JS errors"
for u in "${uuids[@]}"; do
	s=$("$VM" ssh "gnome-extensions info $u | sed -n 's/^ *State: //p'")
	if [[ $s == ACTIVE ]]; then ok "$u"; else bad "$u state=$s"; fi
done
n=$("$VM" ssh 'journalctl --user -b -o cat /usr/bin/gnome-shell | grep -c "JS ERROR" || true')
if [[ $n == 0 ]]; then ok "no JS errors"; else bad "$n JS errors (see journal)"; fi
shot 01-desktop

step "dock: hidden at start, shown by pushing the bottom edge, hidden after leaving"
# Plain auto-hide for this check (by default it only hides when a window is in the way).
gs set org.gnome.shell.extensions.ostrich-os.dock intellihide false 2>/dev/null ||
	"$VM" ssh 'gsettings --schemadir ~/.local/share/gnome-shell/extensions/dock@ostrich-os/schemas set org.gnome.shell.extensions.ostrich-os.dock intellihide false'
# The "before" shot once it has hidden: 01-desktop was taken while it was still shown (an empty
# desktop has no window in the way), which made "shown" look unchanged and "hidden" look changed.
"$VM" move 960 400
sleep 2
shot 02a-dock-hidden-before
"$VM" move 960 1078
"$VM" nudge 0 20 30
sleep 1
shot 02-dock-shown
"$VM" move 960 400
sleep 2
shot 03-dock-hidden
# The dock sits in the bottom-centre band: there after the push, gone after leaving.
d_shown=$(region_diff "$OUT/02a-dock-hidden-before.png" "$OUT/02-dock-shown.png" 760 980 1160 1070)
d_hidden=$(region_diff "$OUT/02a-dock-hidden-before.png" "$OUT/03-dock-hidden.png" 760 980 1160 1070)
# The icons themselves must show, not only the dock's background (they once sat under their blur).
d_icons=$(
	python3 -I - "$OUT/02-dock-shown.png" <<'EOF' 2>/dev/null || true
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("L").crop((760, 990, 1160, 1066))
print(round(ImageStat.Stat(im).stddev[0]))
EOF
)
if [[ -n $d_icons ]]; then
	if ((d_icons >= 12)); then ok "dock icons are visible (contrast $d_icons)"; else bad "the dock shows no icons (contrast $d_icons)"; fi
fi
if [[ -z $d_shown ]]; then
	echo "  (python3-pil missing: check dock visibility in the screenshots)"
else
	if ((d_shown >= 8)); then ok "dock shown by edge push (diff $d_shown)"; else bad "dock not shown by edge push (diff $d_shown)"; fi
	if ((d_hidden < 3)); then ok "dock hidden after leaving (diff $d_hidden)"; else bad "dock still visible after leaving (diff $d_hidden)"; fi
fi

step "workspaces: click workspace 2, rename it"
"$VM" click 52 15
sleep 1
shot 04-workspace-2
# The workspace bar's own record of the active one: the accent pill moved (a pixel check).
d_ws=$(region_diff "$OUT/01-desktop.png" "$OUT/04-workspace-2.png" 0 2 140 30)
if [[ -z $d_ws ]]; then
	echo "  (python3-pil missing: check the workspace pills in the screenshots)"
elif ((d_ws >= 3)); then ok "clicking a pill switched workspace (diff $d_ws)"; else bad "clicking a workspace pill did nothing (diff $d_ws)"; fi
"$VM" click 52 15 right
sleep 1
"$VM" key ctrl-a m a i l ret
sleep 1
ws_names=$(gs get org.gnome.desktop.wm.preferences workspace-names)
if [[ $ws_names == *"'mail'"* ]]; then ok "renamed: $ws_names"; else bad "workspace-names=$ws_names"; fi
shot 05-workspace-renamed

step "tray: scripted icon appears, click activates, menu works"
"$VM" copy "$HERE/sni-test-item.js" /tmp/sni-test-item.js
# shellcheck disable=SC2016 # expands in the VM
"$VM" ssh 'rm -f /tmp/sni.log; export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus; setsid -f gjs -m /tmp/sni-test-item.js /tmp/sni.log </dev/null >/dev/null 2>&1'
sleep 3
grep_log() { "$VM" ssh "grep -c '$1' /tmp/sni.log || true"; }
if [[ $(grep_log registered) -ge 1 ]]; then ok "test item registered with our watcher"; else bad "test item did not register"; fi
shot 06-tray
echo "  (tray icon position is read from the screenshot; set TRAY_X to click it)"
if [[ -n ${TRAY_X:-} ]]; then
	"$VM" click "$TRAY_X" 15
	sleep 1
	if [[ $(grep_log Activate) -ge 1 ]]; then ok "left click sent Activate"; else bad "no Activate"; fi
	"$VM" click "$TRAY_X" 15 right
	sleep 1
	shot 07-tray-menu
fi

step "focus: Super+Alt+F hides things and turns on DND, again restores"
before=$(gs get org.gnome.desktop.notifications show-banners)
"$VM" key meta_l-alt-f
sleep 1
on=$(gs get org.gnome.desktop.notifications show-banners)
shot 08-focus-on
"$VM" key meta_l-alt-f
sleep 1
after=$(gs get org.gnome.desktop.notifications show-banners)
shot 09-focus-off
if [[ $on == false ]]; then ok "banners off in focus"; else bad "banners in focus: $on"; fi
if [[ $after == "$before" ]]; then ok "banners restored ($after)"; else bad "banners after: $after (was $before)"; fi

step "blur: quick settings menu over a blurred backdrop"
"$VM" click 1880 15
sleep 1
shot 10-quick-settings
"$VM" key esc

step "tiling: GNOME's own Super+arrows and edge tiling are taken over while enabled"
if [[ $(gs get org.gnome.mutter edge-tiling) == false ]]; then ok "edge-tiling off"; else bad "edge-tiling still on"; fi
m=$(gs get org.gnome.desktop.wm.keybindings maximize)
if [[ $m != *Super* ]]; then ok "maximize shortcut handed over ($m)"; else bad "maximize still $m"; fi

step "tiling: Super+Left tiles, the popup fills the rest, Super+Up makes a quarter"
# shellcheck disable=SC2016 # expands in the VM
"$VM" ssh 'export WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus; setsid -f nautilus --new-window </dev/null >/dev/null 2>&1; sleep 3; setsid -f gnome-text-editor </dev/null >/dev/null 2>&1'
sleep 5
"$VM" key meta_l-left
sleep 1.5
shot 11-tiling-popup
"$VM" key ret
sleep 1.5
shot 12-tiling-halves
"$VM" key meta_l-up
sleep 1.5
shot 13-tiling-quarter
"$VM" key meta_l-down
sleep 1
"$VM" key meta_l-right
sleep 1
shot 14-tiling-restored
echo "  (check 11-14: popup listing Files; two halves; top-left quarter; text editor back to its size)"

step "tiling: disabling it gives GNOME its settings back (as they were before it took them)"
saved=$("$VM" ssh 'dconf read /org/gnome/shell/extensions/ostrich-os/tiling/overridden-settings')
"$VM" ssh 'gnome-extensions disable tiling@ostrich-os'
sleep 1
diffs=$(
	"$VM" ssh "python3 - $(printf '%q' "$saved")" <<'PY'
import ast, json, subprocess, sys
for ident, want in json.loads(ast.literal_eval(sys.argv[1])).items():
    schema, key = ident.split("|")
    got = subprocess.check_output(["gsettings", "get", schema, key], text=True).strip().replace("@as ", "")
    got = ast.literal_eval(got.replace("true", "True").replace("false", "False"))
    if got != want:
        print(f"{key}: {got!r} (was {want!r})")
PY
)
if [[ -n $saved && -z $diffs ]]; then ok "every overridden setting restored"; else bad "not restored: ${diffs:-nothing was saved}"; fi
"$VM" ssh 'gnome-extensions enable tiling@ostrich-os'

step "clock menu: one size, everything inside it, at normal and large text, with a media player"
# The right column once spilled past the menu's edge (council verdict 2026-10-24, T5 and M2). The
# part of the screen the menu changes must be no wider or taller than the menu (688 x 468, plus
# its shadow).
"$VM" copy "$HERE/mock-mpris.py" /tmp/mock-mpris.py
"$VM" ssh 'setsid -f python3 /tmp/mock-mpris.py Playing >/dev/null 2>&1'
# The tiling scenes' windows dim when the menu takes focus, which would count as change.
"$VM" ssh 'pkill -f "[g]nome-text-editor"; pkill -x nautilus; true'
"$VM" move 960 700
# A banner arriving between the two shots (Ubuntu's "Updates Available") would count as the menu.
gs set org.gnome.desktop.notifications show-banners false
for scale in 1.0 2.0; do
	gs set org.gnome.desktop.interface text-scaling-factor "$scale"
	sleep 2
	shot "15-clock-closed-$scale"
	"$VM" click 960 15
	sleep 2
	shot "15-clock-open-$scale"
	"$VM" key esc
	sleep 1
	size=$(
		python3 -I - "$OUT/15-clock-closed-$scale.png" "$OUT/15-clock-open-$scale.png" <<'EOF' 2>/dev/null || true
import sys
from PIL import Image, ImageChops
a, b = (Image.open(f).convert("L") for f in sys.argv[1:3])
top = 40 if a.height <= 1080 else 80  # below the top bar, whose clock changes
d = ImageChops.difference(a.crop((0, top, a.width, a.height)), b.crop((0, top, b.width, b.height)))
# In 8 px blocks, so a few stray pixels elsewhere (a blinking caret, a desktop icon's hover) don't
# stretch the box; a block counts when a quarter of it changed.
mask = d.point(lambda v: 255 if v > 30 else 0).reduce(8).point(lambda v: 255 if v > 64 else 0)
box = mask.getbbox()
print(f"{(box[2] - box[0]) * 8} {(box[3] - box[1]) * 8}" if box else "0 0")
EOF
	)
	read -r w h <<<"${size:-0 0}"
	# It grows with the text (council M5, sizes in em): the limit grows with the scale, and it must stay
	# on the 1920 x 1080 screen.
	read -r maxw maxh < <(python3 -I -c "s=$scale; print(min(int(720*s), 1920), min(int(500*s), 1080 - 40))")
	if ((w > 0 && w <= maxw && h <= maxh)); then ok "clock menu at text scale $scale fits (${w} x ${h}, at most ${maxw} x ${maxh})"; else bad "clock menu at text scale $scale: changed area ${w} x ${h} (at most ${maxw} x ${maxh})"; fi
done
gs set org.gnome.desktop.interface text-scaling-factor 1.0
gs set org.gnome.desktop.notifications show-banners true
"$VM" ssh 'pkill -f "[m]ock-mpris.py" || true'

step "clock menu: the calendar events card follows its switch, with Today off too (note 20261101-224757)"
# shellcheck disable=SC2016 # expands in the VM
TW='gsettings --schemadir $HOME/.local/share/gnome-shell/extensions/tweaks@ostrich-os/schemas'
TWS=org.gnome.shell.extensions.ostrich-os.tweaks
"$VM" ssh "$TW set $TWS today-panel false"
for events in true false; do
	"$VM" ssh "$TW set $TWS show-events $events"
	sleep 1
	"$VM" click 960 15
	sleep 2
	shot "16-clock-events-$events"
	"$VM" key esc
	sleep 1
done
"$VM" ssh "$TW reset $TWS today-panel; $TW reset $TWS show-events"
# The bottom of the menu's right column, where GNOME puts the events card.
d=$(region_diff "$OUT/16-clock-events-true.png" "$OUT/16-clock-events-false.png" 1060 380 1360 640)
if ((${d:-0} >= 3)); then ok "switching events off removes the card (difference $d)"; else bad "the events card doesn't follow show-events with Today off (difference ${d:-none})"; fi

step "re-check: no JS errors after the scenarios"
n=$("$VM" ssh 'journalctl --user -b -o cat /usr/bin/gnome-shell | grep -c "JS ERROR" || true')
if [[ $n == 0 ]]; then ok "no JS errors"; else bad "$n JS errors"; fi
c=$("$VM" ssh 'journalctl -b -o cat | grep -c "GNOME Shell crashed" || true')
if [[ $c == 0 ]]; then ok "no shell crash"; else bad "gnome-shell crashed $c time(s)"; fi

journal_gate
echo
echo "screenshots: $OUT"
if ((failures == 0)); then
	echo "PASS"
else
	echo "FAILED: $failures"
	exit 1
fi
