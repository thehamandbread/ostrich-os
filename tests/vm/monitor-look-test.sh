#!/usr/bin/env bash
# tests/vm/monitor-look-test.sh: key focus on the system monitor's popup, in the test VM (council
# verdict 2026-11-05-the-ostrich-look, M1: the shell's ring on the footer buttons measured 2.8:1 on
# light glass).
#
#   monitor-look-test.sh [--snapshot NAME]     (default: try-me; needs the Ostrich desktop in it)
#
# Installs this checkout's monitor and drawer (ext-test.sh), puts a busy photo behind the glass, and for the dark
# and the light style opens the popup with the pointer out of the way, then presses Tab through it.
# The first five stops are the section rows (they highlight the whole row); every stop after them (the
# footer buttons) must draw a ring: the strongest pixel that changed against the
# popup at the last row's stop has to contrast 3:1 or more with what it covers (WCAG 1.4.11). Screenshots go to
# $VM_DIR/monitor-look-test.
#
# A second phase checks the popup keeps one width and one left edge (within 4 px) in Balanced, during a
# real download (the network reading changes width) and with Processor open; in Saver only the width (the
# button folds to one icon and the popup stays centred under it). A third phase
# checks an open Processor section adds no more than section-rows rows (6 and 12) to the popup, and
# leaves shots of the keyboard reaching the last row (look at them: the scroll must follow the focus).
# A fourth phase checks the icon-only controls get a visible name (council M4): the footer buttons on
# keyboard focus and with the pointer resting, and a drawer icon with hover-to-open off.
#
# Where things are on the 1920x1080 screen can be overridden: MONITOR_X (the top-bar pill, default 265),
# ROWS (stops that are rows, default 7: 2 pinned, 5 sections), STOPS (Tab presses, default 10: 7 rows, 3 buttons), SHIFT (the pinned strip's height, 66), FOOT_SHIFT (strip plus the footer's separator, 86) and CONTROLS_BOX (x0,y0,x1,y1 of the part of the popup below the rows).
# Finally the journal gate: a JS error or a warning from our code in the shell journal fails it too.
# Not covered: text contrast (run tests/vm/contrast.sh on the shots), high contrast.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ubuntu-ostrich/vm}"
OUT="$VM_DIR/monitor-look-test"
SNAPSHOT=try-me
MONITOR_X="${MONITOR_X:-265}"
# The popup starts with the pinned values (two by default) above the sections, 66 px of strip; the sections
# the popup opens by itself (Processor, Memory, Network, Storage here) are folded once, below, so the rest
# of this test sees the compact layout it was written for.
SHIFT="${SHIFT:-66}"
# A reopened popup has a separator above the footer that the first open does not draw yet (20 px more).
FOOT_SHIFT="${FOOT_SHIFT:-86}"
ROWS="${ROWS:-7}"
STOPS="${STOPS:-10}"
CONTROLS_BOX="${CONTROLS_BOX:-100,$((200 + FOOT_SHIFT)),360,$((300 + FOOT_SHIFT))}"
PROCESSOR_XY="${PROCESSOR_XY:-200 $((59 + SHIFT))}"                                         # the Processor row, to open it
FOLD_XY="${FOLD_XY:-$((59 + SHIFT)) $((87 + SHIFT)) $((145 + SHIFT)) $((176 + SHIFT))}"     # y of the headers of the sections that start open, top-down, once the ones above are folded
ROW_PX="${ROW_PX:-28}"                                                                      # one row of an open section, with a little slack
ROW_MIN_PX="${ROW_MIN_PX:-20}"                                                              # and the least a row can be, to tell a cap that is too small
SECTION_ROWS_AVAILABLE="${SECTION_ROWS_AVAILABLE:-8}"                                       # rows of an open Processor (4 cores: usage, 3 loads, 4 cores)
FOOTER_BUTTON_XY="${FOOTER_BUTTON_XY:-257 $((208 + FOOT_SHIFT))}"                           # the Refresh button
FOOTER_LABEL_BOX="${FOOTER_LABEL_BOX:-100,$((228 + FOOT_SHIFT)),420,$((276 + FOOT_SHIFT))}" # where its label shows, under the footer
FOOTER_HOVER_BOX="${FOOTER_HOVER_BOX:-100,$((228 + FOOT_SHIFT)),260,$((276 + FOOT_SHIFT))}" # under the Refresh button only
DRAWER_ICON_XY="${DRAWER_ICON_XY:-1545 15}"                                                 # the first drawer icon in the top bar
DRAWER_LABEL_BOX="${DRAWER_LABEL_BOX:-1450,36,1750,72}"                                     # under it
SECTIONS_KEY=/org/gnome/shell/extensions/ubuntu-ostrich/monitor/sections-open               # what the popup remembers as open
DOWNLOAD=http://archive.ubuntu.com/ubuntu/ls-lR.gz
PHOTO=/usr/share/backgrounds/mendhak-Red_Acer.jpg # the busy one the council's glass shots use
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	*)
		echo "usage: monitor-look-test.sh [--snapshot NAME]" >&2
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

rm -rf "$OUT"
mkdir -p "$OUT"
"$HERE/ext-test.sh" --snapshot "$SNAPSHOT" --cycles 3 monitor drawer >&2
trap '"$VM" stop >/dev/null 2>&1 || true' EXIT
run "for k in picture-uri picture-uri-dark; do gsettings set org.gnome.desktop.background \$k file://$PHOTO; done; gsettings set org.gnome.desktop.session idle-delay 0; gsettings set org.gnome.desktop.screensaver lock-enabled false"

for style in prefer-dark default; do
	echo "== $style"
	run "gsettings set org.gnome.desktop.interface color-scheme $style"
	sleep 3
	"$VM" click "$MONITOR_X" 15
	sleep 2
	if [[ $style == prefer-dark ]]; then
		for y in $FOLD_XY; do
			"$VM" click 200 "$y"
			sleep 1
		done
		"$VM" screenshot "$OUT/folded.png" >/dev/null
		# The clicks left the keyboard focus on a header: reopen, so the Tab walk starts from the top.
		"$VM" key esc
		sleep 1
		"$VM" click "$MONITOR_X" 15
		sleep 2
	fi
	"$VM" move 960 700 # the pointer away, so only the keyboard moves the focus
	sleep 1
	for ((i = 1; i <= STOPS; i++)); do
		"$VM" key tab
		sleep 1
		"$VM" screenshot "$OUT/$style-$i.png" >/dev/null
	done
	if [[ $style == prefer-dark ]]; then
		# The pointer onto the Refresh button, in this same open popup (its layout is known here): the label
		# moves from the last stop's button to this one.
		# shellcheck disable=SC2086 # two coordinates
		"$VM" move $FOOTER_BUTTON_XY
		sleep 3
		"$VM" screenshot "$OUT/label-footer-hover.png" >/dev/null
	fi
	"$VM" key esc
	sleep 1
	# One line per stop after the rows: "stop ratio" (ratio 0 when nothing changed).
	rings=$(
		python3 -I - "$OUT" "$style" "$ROWS" "$STOPS" "$CONTROLS_BOX" <<'EOF'
import sys
from PIL import Image, ImageChops

out, style, rows, stops, box = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), tuple(int(v) for v in sys.argv[5].split(","))

def lin(c):
    c /= 255
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

def lum(p):
    return 0.2126 * lin(p[0]) + 0.7152 * lin(p[1]) + 0.0722 * lin(p[2])

# The baseline is the last row's stop: a row's focus changes nothing below the rows, so any change
# there at a later stop is that control's own focus.
base = Image.open(f"{out}/{style}-{rows}.png").convert("RGB").crop(box)
for i in range(rows + 1, stops + 1):
    cur = Image.open(f"{out}/{style}-{i}.png").convert("RGB").crop(box)
    diff = ImageChops.difference(base, cur).convert("L")
    best, bestv = None, 0
    for y in range(diff.height):
        for x in range(diff.width):
            v = diff.getpixel((x, y))
            if v > bestv:
                best, bestv = (x, y), v
    if best is None or bestv < 25:
        print(i, "0")
        continue
    a, b = lum(base.getpixel(best)), lum(cur.getpixel(best))
    print(i, f"{(max(a, b) + 0.05) / (min(a, b) + 0.05):.2f}")
EOF
	)
	while read -r stop ratio; do
		if [[ $ratio == 0 ]]; then
			bad "$style: Tab stop $stop shows no ring"
		elif awk -v r="$ratio" 'BEGIN { exit !(r >= 3) }'; then
			ok "$style: Tab stop $stop ring $ratio:1"
		else
			bad "$style: Tab stop $stop ring only $ratio:1 (needs 3:1)"
		fi
	done <<<"$rings"
done

echo "== width"
run "gsettings set org.gnome.desktop.interface color-scheme prefer-dark"
sleep 3
"$VM" move 960 700
sleep 2
"$VM" screenshot "$OUT/width-closed.png" >/dev/null
run "setsid -f timeout 45 sh -c \"while :; do wget -q -O /dev/null $DOWNLOAD; done\" </dev/null >/dev/null 2>&1"
"$VM" click "$MONITOR_X" 15
sleep 3
"$VM" screenshot "$OUT/width-1-balanced.png" >/dev/null
for n in 2 3 4; do
	sleep 3
	"$VM" screenshot "$OUT/width-$n-download.png" >/dev/null
done
# shellcheck disable=SC2086 # two coordinates
"$VM" click $PROCESSOR_XY
sleep 3
"$VM" screenshot "$OUT/width-5-processor-open.png" >/dev/null
# shellcheck disable=SC2086
"$VM" click $PROCESSOR_XY
sleep 2
# Power saver from outside (the popup has no power row since 2026-11-09); as root, because polkit
# lets only the active local session switch modes and SSH is not that.
"$VM" ssh "sudo powerprofilesctl set power-saver"
sleep 3
"$VM" screenshot "$OUT/width-6-saver.png" >/dev/null
"$VM" ssh "sudo powerprofilesctl set balanced"
sleep 1
"$VM" key esc
# The longest ordinary network line: three digits of B/s in both directions (small pings), which the
# popup's width has to hold without cutting it ("..." instead of "B/s").
run "setsid -f timeout 40 ping -i 0.3 -s 230 -q 1.1.1.1 </dev/null >/dev/null 2>&1"
sleep 4
"$VM" click "$MONITOR_X" 15
sleep 5
"$VM" screenshot "$OUT/width-7-ping.png" >/dev/null
echo "    look at width-7-ping.png: the Network line must end in B/s, not an ellipsis"
"$VM" key esc
widths=$(
	python3 -I - "$OUT" <<'PYEND'
import glob, os, sys
from PIL import Image, ImageChops

out = sys.argv[1]
closed = Image.open(f"{out}/width-closed.png").convert("RGB")
for path in sorted(glob.glob(f"{out}/width-[0-9]-*.png")):
    diff = ImageChops.difference(closed, Image.open(path).convert("RGB")).convert("L").point(lambda v: 255 if v > 12 else 0)
    box = diff.crop((0, 40, diff.width, diff.height)).getbbox()  # below the top bar
    name = os.path.basename(path)[:-4]
    print(name, *((box[0], box[2] - box[0]) if box else ("none", 0)))
PYEND
)
echo "$widths"
first_left="" first_width=""
while read -r name left width; do
	if [[ $left == none ]]; then
		bad "$name: no popup found"
	elif [[ -z $first_left ]]; then
		first_left=$left first_width=$width
		ok "$name: left $left, width $width (the reference)"
	elif [[ $name == *saver ]] && ((width - first_width <= 4 && first_width - width <= 4)); then
		# In saver the top-bar button folds to one icon and GNOME centres the popup under its button,
		# so the popup moves once, with the button; only its width must hold (owner, 2026-11-09).
		ok "$name: width $width (left $left: follows the folded button)"
	elif ((left - first_left > 4 || first_left - left > 4 || width - first_width > 4 || first_width - width > 4)); then
		bad "$name: left $left, width $width (reference $first_left, $first_width: more than 4 px apart)"
	else
		ok "$name: left $left, width $width"
	fi
done <<<"$widths"

echo "== labels"
# A label (the control's name) appears just under an icon-only control: the pixels in the strip below it
# change against a shot of the same state without it. The footer buttons are the last stops of the Tab
# walk (shots from the dark run); then the pointer rests on a footer button (shot taken in that same popup), and on a
# drawer icon with hover-to-open off (with it on, the pause opens the site instead). This runs before
# the cap phase: an open section there would move the footer. The VM's timers are slow: wait 3 s.
changed() { # image-a image-b x0,y0,x1,y1: how many pixels in the box differ clearly
	python3 -I - "$@" <<'PYEND'
import sys
from PIL import Image, ImageChops

a, b = (Image.open(p).convert("RGB") for p in sys.argv[1:3])
box = tuple(int(v) for v in sys.argv[3].split(","))
diff = ImageChops.difference(a.crop(box), b.crop(box)).convert("L").point(lambda v: 255 if v > 40 else 0)
print(sum(1 for v in diff.get_flattened_data() if v))
PYEND
}
label_seen() { # description n
	if (($2 > 150)); then ok "$1: a label is shown ($2 pixels)"; else bad "$1: no label ($2 pixels changed)"; fi
}
for ((i = STOPS - 2; i <= STOPS; i++)); do
	label_seen "footer button, keyboard focus (Tab stop $i)" "$(changed "$OUT/prefer-dark-$ROWS.png" "$OUT/prefer-dark-$i.png" "$FOOTER_LABEL_BOX")"
done
label_seen "footer button, pointer resting (the label moves to it)" "$(changed "$OUT/prefer-dark-$STOPS.png" "$OUT/label-footer-hover.png" "$FOOTER_HOVER_BOX")"
run "dconf write /org/gnome/shell/extensions/ubuntu-ostrich/drawer/open-on-hover false"
sleep 2
"$VM" move 960 700
sleep 1
"$VM" screenshot "$OUT/label-drawer-away.png" >/dev/null
# shellcheck disable=SC2086
"$VM" move $DRAWER_ICON_XY
sleep 3
"$VM" screenshot "$OUT/label-drawer-hover.png" >/dev/null
label_seen "drawer icon, pointer resting (hover-to-open off)" "$(changed "$OUT/label-drawer-away.png" "$OUT/label-drawer-hover.png" "$DRAWER_LABEL_BOX")"
# And they go: no label left under the footer after the popup closed (the shot above was taken with it
# closed), and none under the drawer icon once the pointer has left it.
gone() { # description n
	if (($2 < 60)); then ok "$1: no label left behind"; else bad "$1: a label stayed ($2 pixels)"; fi
}
gone "footer button, popup closed" "$(changed "$OUT/width-closed.png" "$OUT/label-drawer-away.png" "$FOOTER_LABEL_BOX")"
"$VM" move 960 700
sleep 2
"$VM" screenshot "$OUT/label-drawer-left.png" >/dev/null
gone "drawer icon, pointer left" "$(changed "$OUT/label-drawer-away.png" "$OUT/label-drawer-left.png" "$DRAWER_LABEL_BOX")"
run "dconf write /org/gnome/shell/extensions/ubuntu-ostrich/drawer/open-on-hover true"

echo "== section cap (section-rows)"
# The popup with Processor open, against the closed popup: an open section may add the setting's rows
# (ROW_PX each) plus one row of slack, and no fewer than ROW_MIN_PX each. The shots show whether the cap scrolls.
cap_height() { # image: the popup's height against the closed shot
	python3 -I - "$OUT/width-closed.png" "$1" <<'PYEND'
import sys
from PIL import Image, ImageChops

diff = ImageChops.difference(Image.open(sys.argv[1]).convert("RGB"), Image.open(sys.argv[2]).convert("RGB")).convert("L").point(lambda v: 255 if v > 12 else 0)
box = diff.crop((0, 40, 440, diff.height)).getbbox()  # the popup's columns only (it ends at x 365): a dialog elsewhere must not count
print(box[3] - box[1] if box else 0)
PYEND
}
for rows in 6 12; do
	run "dconf write /org/gnome/shell/extensions/ubuntu-ostrich/monitor/section-rows 'uint32 $rows'"
	run "dconf write $SECTIONS_KEY \"@as []\"" # the popup remembers what was left open: start folded, as the click below expects
	sleep 2
	"$VM" move 960 700
	"$VM" click "$MONITOR_X" 15
	sleep 3
	"$VM" screenshot "$OUT/cap-$rows-closed.png" >/dev/null
	# shellcheck disable=SC2086 # two coordinates
	"$VM" click $PROCESSOR_XY
	sleep 3
	"$VM" screenshot "$OUT/cap-$rows-open.png" >/dev/null
	closed_h=$(cap_height "$OUT/cap-$rows-closed.png")
	open_h=$(cap_height "$OUT/cap-$rows-open.png")
	added=$((open_h - closed_h))
	limit=$(((rows + 1) * ROW_PX))
	# The VM has 4 cores: an open Processor section has 8 rows, so 12 rows is not reached.
	shown=$((rows < SECTION_ROWS_AVAILABLE ? rows : SECTION_ROWS_AVAILABLE))
	least=$(((shown - 1) * ROW_MIN_PX))
	if ((added > limit)); then
		bad "section-rows $rows: Processor adds $added px, more than $limit (the cap isn't holding)"
	elif ((added < least)); then
		bad "section-rows $rows: Processor adds only $added px, less than $least (the cap is too small)"
	else
		ok "section-rows $rows: open popup $open_h px, $added px more than closed (between $least and $limit)"
	fi
	# Down to the last row of the section, then the next section: the focused row must be on screen.
	for _ in 1 2 3 4 5 6 7 8; do
		"$VM" key down
		sleep 1
	done
	"$VM" screenshot "$OUT/cap-$rows-last-row.png" >/dev/null
	"$VM" key esc
	sleep 1
done
echo "    look at cap-6-last-row.png: the last row (Core 3) must be highlighted and inside the popup"

echo "== remembered (sections-open): what you leave open stays so after a login"
# A login starts the extension again, so the test turns it off and on. Heights are of the popup against
# the closed shot, as in the cap phase above.
reopen_with() { # stored-list shot-name: the extension restarted with this list, the popup's height
	run "dconf write $SECTIONS_KEY \"$1\""
	run "gnome-extensions disable monitor@ubuntu-ostrich; sleep 1; gnome-extensions enable monitor@ubuntu-ostrich"
	sleep 3
	"$VM" move 960 700
	"$VM" click "$MONITOR_X" 15
	sleep 3
	"$VM" screenshot "$OUT/$2.png" >/dev/null
	cap_height "$OUT/$2.png"
	"$VM" key esc
	sleep 1
}
h_none=$(reopen_with "@as []" remembered-none)
h_mem=$(reopen_with "['mem']" remembered-mem)
h_default=$(reopen_with "['default']" remembered-default)
if ((h_mem - h_none >= 100)); then ok "only Memory remembered: $h_mem px, $((h_mem - h_none)) px above all folded ($h_none px)"; else bad "only Memory remembered gives $h_mem px against $h_none px folded"; fi
if ((h_default - h_none >= 300)); then ok "default: four sections open, $h_default px"; else bad "default gives only $h_default px against $h_none px folded (four sections should open)"; fi
# Closing the popup folds the sections; that must not be taken for your choice, and they come back.
"$VM" click "$MONITOR_X" 15
sleep 3
"$VM" screenshot "$OUT/remembered-reopened.png" >/dev/null
h_again=$(cap_height "$OUT/remembered-reopened.png")
"$VM" key esc
sleep 1
after_close=$(run "dconf read $SECTIONS_KEY")
if ((h_again >= h_default - 30)); then ok "closed and reopened: still $h_again px (four sections open)"; else bad "closed and reopened: only $h_again px against $h_default px"; fi
if [[ $after_close == "['default']" ]]; then ok "closing the popup left the stored choice alone"; else bad "closing the popup changed the stored choice to $after_close"; fi
# Fold Processor by hand in the default popup: the list the extension keeps loses it.
run "dconf write $SECTIONS_KEY \"['default']\""
run "gnome-extensions disable monitor@ubuntu-ostrich; sleep 1; gnome-extensions enable monitor@ubuntu-ostrich"
sleep 3
"$VM" move 960 700
"$VM" click "$MONITOR_X" 15
sleep 3
# shellcheck disable=SC2086 # two coordinates
"$VM" click $PROCESSOR_XY
sleep 2
stored=$(run "dconf read $SECTIONS_KEY")
"$VM" key esc
if [[ $stored == *mem* && $stored != *cpu* && $stored != *default* ]]; then ok "folding Processor by hand is kept: $stored"; else bad "folding Processor by hand left $stored"; fi

echo "== journal"
journal_gate

if ((failures > 0)); then
	echo "FAIL: $failures problem(s); screenshots in $OUT"
	exit 1
fi
echo "PASS (screenshots in $OUT)"
