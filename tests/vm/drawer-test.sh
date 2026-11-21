#!/usr/bin/env bash
# tests/vm/drawer-test.sh: Ostrich Drawer in the test VM.
#
#   drawer-test.sh [--snapshot NAME] [--out DIR]   the top-bar icons, opening, sizes, hover,
#                                                  focus, power saver and environment sets
#   drawer-test.sh --sites [--out DIR]             loads every recommended site in WebKitGTK and
#                                                  flags pages that turn the browser away
#
# Needs a snapshot with Ubuntu Ostrich installed (default: post-fresh) and the tools built into
# $VM_DIR/tools-bin (build-tools.sh). The drawer and focus extensions from this checkout and the
# freshly built drawer and ostrich replace the installed ones. The drawer's state comes from its
# published `state` action (org.gtk.Actions.Describe). Screenshots go to DIR.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
ROOT="$(cd "$HERE/../.." && pwd)"
VM="$HERE/vm.sh"
PROJECT="ubuntu-ostrich"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
SNAPSHOT=post-fresh
OUT="$VM_DIR/drawer-test"
SITES=0
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	--out) OUT=$2 && shift ;;
	--sites) SITES=1 ;;
	*)
		echo "usage: drawer-test.sh [--sites] [--snapshot NAME] [--out DIR]" >&2
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
is() {
	local msg=$1
	shift
	if "$@"; then ok "$msg"; else bad "$msg"; fi
}
shot() { "$VM" screenshot "$OUT/$1.png" >/dev/null; }
step() { printf '== %s\n' "$*"; }
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0;'
run() { "$VM" ssh "$SESSION $*"; }
# shellcheck disable=SC2016 # expands in the VM
DS='gsettings --schemadir $HOME/.local/share/gnome-shell/extensions/drawer@ubuntu-ostrich/schemas'
DRAWER_SCHEMA=org.gnome.shell.extensions.ubuntu-ostrich.drawer
# shellcheck disable=SC2016 # expands in the VM
OSTRICH='$HOME/.local/bin/ostrich'
# shellcheck disable=SC2016 # expands in the VM
HOST='$HOME/.local/libexec/ubuntu-ostrich/ostrich-drawer'
TOP=32 # GNOME's top bar height at 1080p in the VM

# The drawer's state as shell-friendly lines: "active ID", "shown true", "window W H",
# "bar ID ID...", "set false", "site ID loaded=.. unread=.. width=.. height=..".
read -r -d '' PY_STATE <<'EOF' || true
import json, re, sys
raw = sys.stdin.read()
# gdbus quotes the string with ' or, when it contains a ', with ".
m = re.search(r"<(['\"])(.*)\1>", raw, re.S)
s = json.loads(m.group(2).encode().decode("unicode_escape")) if m else {}
low = lambda v: str(v).lower()
print("active", s.get("active"))
print("shown", low(s.get("shown")))
print("engaged", low(s.get("engaged")))
print("window", *s.get("window", [0, 0]))
print("bar", *s.get("bar", []))
print("set", low(s.get("set")))
print("added", s.get("lastAdded"))
print("error", s.get("lastError"))
print("errors", s.get("errorCount", 0))
for x in s.get("sites", []):
    print("site", x["id"], "loaded=" + low(x["loaded"]), "failed=" + low(x.get("failed")), "unread=%s" % x["unread"],
          "width=%s" % x["width"], "height=%s" % x["height"], "keep=" + low(x["keep"]), "mb=%s" % x.get("mb", 0))
EOF
state() {
	run "gdbus call --session --dest ubuntu_ostrich.drawer --object-path /ubuntu_ostrich/drawer --method org.gtk.Actions.Describe state" |
		python3 -I -c "$PY_STATE"
}
field() { sed -n "s/^$1 //p" <<<"$2" | head -1; }
site_has() { grep -q "^site $1 .*$2" <<<"$3"; }

rm -rf "$OUT"
mkdir -p "$OUT"

step "start from $SNAPSHOT with this checkout's drawer"
"$VM" stop
"$VM" snapshot restore "$SNAPSHOT"
"$VM" start
sleep 10

if ((SITES)); then
	step "recommended sites in WebKitGTK"
	# The probe uses WebKit through gjs, which needs its introspection data (the drawer doesn't).
	"$VM" ssh "dpkg -s gir1.2-webkit-6.0 >/dev/null 2>&1 || { sudo sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources; sudo apt-get update -qq; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gir1.2-webkit-6.0 >/dev/null; }"
	"$VM" copy "$HERE/site-probe.js" /tmp/site-probe.js
	"$VM" copy "$ROOT/tools/drawer-host/data/recommended.toml" /tmp/recommended.toml
	mapfile -t sites < <(python3 -I -c '
import sys, tomllib
for s in tomllib.load(open(sys.argv[1], "rb"))["site"]:
    if s.get("status", "ok") == "ok":
        print(s["id"], s["url"], s.get("user_agent", ""), sep="\t")' "$ROOT/tools/drawer-host/data/recommended.toml")
	: >"$OUT/sites.jsonl"
	for line in "${sites[@]}"; do
		IFS=$'\t' read -r id url ua <<<"$line"
		run "gjs -m /tmp/site-probe.js '$url' 8 '$ua'" >"$OUT/$id.json" 2>"$OUT/$id.err" &
		probe=$!
		sleep 14
		shot "site-$id"
		wait "$probe" || true
		if grep -q '^{' "$OUT/$id.json"; then
			grep '^{' "$OUT/$id.json" >>"$OUT/sites.jsonl"
		else
			printf '{"url": "%s", "error": "no result: %s"}\n' "$url" "$(tail -1 "$OUT/$id.err" | tr -cd '[:alnum:] .,:_-')" >>"$OUT/sites.jsonl"
		fi
		run "pkill -f '[s]ite-probe.js'" || true
	done
	python3 -I - "$OUT/sites.jsonl" <<'EOF'
import json, re, sys
BLOCKED = re.compile(r"browser (is|isn.t) (not )?supported|unsupported browser|update your browser|"
                     r"use a supported browser|switch to (google )?chrome|download (google )?chrome|"
                     r"browser you.re using|not available on this browser", re.I)
bad = 0
for line in open(sys.argv[1]):
    line = line.strip()
    if not line.startswith("{"):
        continue
    r = json.loads(line)
    text = r.get("text", "")
    title = text.split("\n", 1)[0][:50]
    if "error" in r:
        verdict = f"ERROR {r['error']}"
        bad += 1
    elif BLOCKED.search(text):
        verdict = "BLOCKED " + BLOCKED.search(text).group(0)
        bad += 1
    else:
        verdict = "ok"
    print(f"  {verdict:<40} {r['url']:<40} -> {r.get('final', '')[:60]}  [{title}]")
print(f"  {bad} site(s) need a look (screenshots site-*.png)")
EOF
	"$VM" stop
	exit 0
fi

"$ROOT/modules/gnome/extensions/build.sh" drawer focus tray dock blur monitor >/dev/null
for e in drawer focus tray dock blur monitor; do
	"$VM" copy "$ROOT/dist/$e@ubuntu-ostrich.shell-extension.zip" "/tmp/$e.zip"
	run "gnome-extensions install --force /tmp/$e.zip"
done
"$VM" copy "$VM_DIR/tools-bin/ostrich-drawer" /tmp/ostrich-drawer
"$VM" copy "$VM_DIR/tools-bin/ostrich" /tmp/ostrich
run "pkill -x ostrich-drawer; install -m755 /tmp/ostrich-drawer $HOST; install -m755 /tmp/ostrich $OSTRICH"
# No crash-report dialogs mid-test: a crash in another program (xdg-desktop-portal has segfaulted in
# this VM) would take focus and hide the drawer. Crashes still show in the journal.
run "sudo sed -i 's/^enabled=1/enabled=0/' /etc/default/apport; sudo systemctl disable --now apport.service >/dev/null 2>&1; sudo rm -f /var/crash/*.crash" || true
sleep 30 # past the start-up window in which a power-off can make GNOME switch extensions off
"$VM" stop
"$VM" start
sleep 40 # the drawer autostarts hidden; its keep-alive sites load

step "top bar: an icon per pinned site"
s=$(state)
while IFS= read -r l; do echo "    $l"; done <<<"$s"
# At login only the sites kept loaded start (DESIGN.md; council verdict 2026-10-24, M3).
unkept_loaded=$(grep '^site ' <<<"$s" | grep 'loaded=true' | grep -c 'keep=false' || true)
is "at login only kept sites are loaded ($unkept_loaded others)" test "$unkept_loaded" = 0
is "bar has the 4 starters" test "$(field bar "$s")" = "messages chat claude youtube"
# Messaging pages aren't media players: no empty "ostrich-drawer" card in the clock menu (council
# verdict 2026-10-24-motion-now-playing-spotify-colour, M1).
players=$(run "busctl --user list" | grep -c 'org.mpris.MediaPlayer2.ubuntu_ostrich.drawer' || true)
is "no drawer media players at login ($players)" test "$players" = 0
run "$DS set $DRAWER_SCHEMA bar-max 0"
sleep 2
shot 01-no-icons
run "$DS set $DRAWER_SCHEMA bar-max 4"
sleep 2
shot 02-icons
# The icons are what changed in the top bar between the two shots. The group sits fixed beside quick
# settings, as + then the icons, so the + moves left when the icons come: its new place is the first
# changed spot, the icons are the last four.
mapfile -t centers < <(
	python3 -I - "$OUT/01-no-icons.png" "$OUT/02-icons.png" "$TOP" <<'EOF' 2>/dev/null || true
import sys
from PIL import Image, ImageChops
a, b = (Image.open(f).convert("L") for f in sys.argv[1:3])
top = int(sys.argv[3])
d = ImageChops.difference(a.crop((0, 0, a.width, top)), b.crop((0, 0, b.width, top)))
# Right of the clock only: the system monitor's numbers and the clock change meanwhile.
cols = [x for x in range(d.width * 3 // 5, d.width) if max(d.getpixel((x, y)) for y in range(4, top - 4)) > 40]
segs, start, prev = [], None, None
for x in cols:
    if start is None:
        start = prev = x
    elif x - prev > 6:
        segs.append((start, prev)); start = x
    prev = x
if start is not None:
    segs.append((start, prev))
for s, e in segs:
    print((s + e) // 2)
EOF
)
echo "    icon centres: ${centers[*]:-none}"
is "the + and 4 site icons in the top bar (no ⌄ menu: every site has an icon)" test "${#centers[@]}" = 5
plus=${centers[0]:-0}
centers=("${centers[@]:1}")
cx() { echo "${centers[$1]:-0}"; }
step "order: + then the sites, all against quick settings"
is "the + is left of the sites ($plus < $(cx 0))" test "$plus" -lt "$(cx 0)"
is "the sites are next to quick settings (last one at $(cx 3))" test "$(cx 3)" -gt $((1920 - 230))

step "click: Claude drops down under its icon, at the wide size; click again folds it"
"$VM" click "$(cx 2)" 15
sleep 3
s=$(state)
shot 03-claude
is "Claude active and shown" test "$(field active "$s") $(field shown "$s")" = "claude true"
read -r ww wh <<<"$(field window "$s")"
is "wide size (960 x 629, got $ww x $wh)" test "$ww" -ge 940 -a "$ww" -le 980 -a "$wh" -ge 610 -a "$wh" -le 650
"$VM" click "$(cx 2)" 15
sleep 2
is "folded up" test "$(field shown "$(state)")" = false

step "unloaded icons are grey; a middle click unloads a loaded site"
# Mean colour saturation of one icon: a loaded site's favicon has colour, an unloaded one is grey.
sat() { # png x
	python3 -I - "$1" "$2" <<'PYEND'
import sys
from PIL import Image
x = int(sys.argv[2])
v = list(Image.open(sys.argv[1]).convert("RGB").crop((x - 9, 8, x + 9, 24)).convert("HSV").getdata())
print(round(sum(p[1] for p in v) / len(v)))
PYEND
}
shot 03a-claude-loaded
is "Claude is loaded" site_has claude "loaded=true" "$(state)"
loaded_sat=$(sat "$OUT/03a-claude-loaded.png" "$(cx 2)")
"$VM" click "$(cx 2)" 15 middle
sleep 3
shot 03b-claude-unloaded
is "a middle click unloaded Claude" site_has claude "loaded=false" "$(state)"
grey_sat=$(sat "$OUT/03b-claude-unloaded.png" "$(cx 2)")
is "the unloaded icon is greyer (saturation $loaded_sat -> $grey_sat)" test $((loaded_sat - grey_sat)) -ge 20

step "one size for every site: Messages opens as wide as Claude; dragging the grip resizes them all"
"$VM" click "$(cx 0)" 15
sleep 3
s=$(state)
read -r ww wh <<<"$(field window "$s")"
is "same size as the other sites (960 wide, got $ww x $wh)" test "$ww" -ge 940 -a "$ww" -le 980
shot 04-messages
# The drawer sits centred under the icon, inside the screen; the grip is at the bottom middle.
x0=$(python3 -I -c "print(max(8, min(1920 - $ww - 8, $(cx 0) - $ww // 2)))")
gx=$((x0 + ww / 2)) gy=$((TOP + wh - 5))
"$VM" drag "$gx" "$gy" "$gx" $((gy + 100))
sleep 2
s=$(state)
read -r _ nh <<<"$(field window "$s")"
shot 05-resized
is "taller by about 100 px ($wh -> $nh)" test $((nh - wh)) -ge 80 -a $((nh - wh)) -le 120
saved=$(run "$DS get $DRAWER_SCHEMA size" | tr -dc '0-9 ,' | awk -F'[ ,]+' '{print $NF}')
is "the size is kept for all sites ($saved, window $nh)" test "${saved:-0}" -ge $((nh - 4)) -a "${saved:-0}" -le $((nh + 4))
# Another site while it is open: no resize and no move (that was the stutter).
"$VM" click "$(cx 3)" 15
sleep 1
read -r sw sh <<<"$(field window "$(state)")"
is "switching sites keeps the window ($ww x $nh -> $sw x $sh)" test "$sw" = "$ww" -a "$sh" = "$nh"
"$VM" key esc
sleep 2
"$VM" click "$(cx 2)" 15
sleep 3
read -r cw ch <<<"$(field window "$(state)")"
is "another site opens at the same size ($cw x $ch)" test "$cw" = "$ww" -a "$ch" = "$nh"
"$VM" key esc
sleep 2

step "an image copied elsewhere can be pasted into a page"
"$VM" copy "$HERE/paste-server.py" /tmp/paste-server.py
"$VM" copy "$HERE/clip-owner.js" /tmp/clip-owner.js
"$VM" copy "$HERE/clip-check.js" /tmp/clip-check.js
run "rm -f /tmp/paste.log; setsid -f python3 /tmp/paste-server.py 8766 /tmp/paste.log </dev/null >/dev/null 2>&1"
# Another app owns the clipboard (a small window that copies a PNG when clicked), as a screenshot tool does.
run "setsid -f timeout 90 gjs -m /tmp/clip-owner.js </dev/null >/dev/null 2>&1"
# Its window takes a while to appear on a busy machine: click it until the clipboard holds the image.
for try in 1 2 3 4 5 6; do
	sleep 4
	"$VM" move 960 560
	"$VM" click 960 560
	sleep 1
	run "timeout 20 gjs -m /tmp/clip-check.js 2>&1" | grep -q "image/png" && break
	shot "30-clip-owner-$try"
done
is "another app put an image on the clipboard" run "timeout 20 gjs -m /tmp/clip-check.js 2>&1 | grep -q image/png"
run "$HOST --add http://localhost:8766/"
run "$HOST --show localhost >/dev/null 2>&1 &"
sleep 8
"$VM" click 960 $((TOP + 200))
sleep 1
"$VM" key ctrl-v
sleep 3
p=$(run "cat /tmp/paste.log 2>/dev/null || true")
echo "    page saw: ${p:-nothing}"
is "the page got an image from the paste" grep -q "image%2Fpng" <<<"$p"
is "and as a file" grep -q "files=1" <<<"$p"
run "$HOST --remove localhost"
run "kill \$(pgrep -f 'paste-serve[r].py') 2>/dev/null; kill \$(pgrep -f 'clip-owne[r].js') 2>/dev/null; true"
"$VM" key esc
sleep 2

step "unread badge"
run "mkdir -p /tmp/site && printf '<title>(3) Test inbox</title><p>hi</p>' > /tmp/site/t.html && (cd /tmp/site && setsid -f python3 -m http.server 8765 >/dev/null 2>&1)"
sleep 1
run "$HOST --add http://localhost:8765/t.html"
run "gdbus call --session --dest ubuntu_ostrich.drawer --object-path /ubuntu_ostrich/drawer --method org.gtk.Actions.Activate keep \"[<('localhost', true)>]\" {}" >/dev/null
run "$DS set $DRAWER_SCHEMA bar-max 5"
sleep 5
s=$(state)
is "unread count from the page title" site_has localhost "unread=3" "$s"
shot 06-badge
# Back to the 4 starters, so the icons are where they were found.
run "$HOST --remove localhost"
run "$DS set $DRAWER_SCHEMA bar-max 4"
sleep 2

step "a page that leaves its site opens in the browser; the drawer stays"
# A script sending the page elsewhere (council verdict 2026-10-24, T13 and M5).
# (The address is the page's title, which keeps the quoting simple.)
run "printf '<title>http://example.org/</title><script>setTimeout(function(){location=document.title},1500)</script>' > /tmp/site/nav.html"
run "pkill -f '[f]irefox' || true"
run "$HOST --add http://localhost:8765/nav.html"
run "$HOST --show localhost >/dev/null 2>&1 &"
sleep 8
browsers=$(run "pgrep -fc '[f]irefox' || true")
# Had the drawer gone there itself, nothing would have started the browser.
is "the foreign page opened in the browser ($browsers processes)" test "${browsers:-0}" -gt 0
shot 06b-left-site
run "pkill -f '[f]irefox' || true"
run "$HOST --remove localhost"
sleep 1
is "the drawer's data folder is private" test "$(run 'stat -c %a ~/.local/share/ubuntu-ostrich/drawer')" = 700
# Its cookies and storage are cleared at once; the folder goes at the drawer's next start.
run "pkill -f '[o]strich-drawer' || true"
sleep 1
run "$HOST --hidden >/dev/null 2>&1 &"
sleep 4
is "a removed site's data is gone after a restart" test "$(run 'test -e ~/.local/share/ubuntu-ostrich/drawer/localhost && echo kept')" = ""

step "a kept site shows what it costs (measured 30 s after it loads)"
# Messages is kept loaded only on a machine with 12 GB or more; keep it here, so the check doesn't
# depend on the VM's memory (the restart above left nothing loaded on a fresh install).
run "gdbus call --session --dest ubuntu_ostrich.drawer --object-path /ubuntu_ostrich/drawer --method org.gtk.Actions.Activate keep \"[<('messages', true)>]\" {}" >/dev/null
for _ in $(seq 25); do
	site_has messages "mb=[1-9]" "$(state)" && break
	sleep 3
done
is "Messages has a memory figure ($(state | grep -o 'site messages.*' | grep -o 'mb=[0-9]*'))" site_has messages "mb=[1-9]" "$(state)"

step "focus hides the drawer icons"
"$VM" key meta_l-alt-f
sleep 2
shot 07-focus
d=$(
	python3 -I - "$OUT/01-no-icons.png" "$OUT/07-focus.png" "$(cx 0)" "$(cx 3)" <<'EOF' 2>/dev/null || true
import sys
from PIL import Image, ImageChops, ImageStat
a, b = (Image.open(f).convert("L") for f in sys.argv[1:3])
x0, x1 = int(sys.argv[3]) - 12, int(sys.argv[4]) + 12
print(round(ImageStat.Stat(ImageChops.difference(a.crop((x0, 4, x1, 28)), b.crop((x0, 4, x1, 28)))).mean[0]))
EOF
)
is "no icons where they were (diff ${d:-?})" test "${d:-99}" -le 3
"$VM" key meta_l-alt-f
sleep 2

step "power saver unloads sites that aren't kept loaded"
# Messages is kept loaded by default only with ~12 GB of memory or more (the VM has less): keep it
# here, through the same command Ostrich Settings' switch uses.
run "$HOST --keep messages"
sleep 6
"$VM" click "$(cx 3)" 15
sleep 4
"$VM" key esc
sleep 2
is "YouTube loaded" site_has youtube "loaded=true" "$(state)"
# Media sites may still be players (they're the ones a media card should control). Informational:
# YouTube only registers once its page has media, which needs the network.
echo "    drawer media players with YouTube open: $(run "busctl --user list" | grep -c 'org.mpris.MediaPlayer2.ubuntu_ostrich.drawer' || true)"
run "sudo powerprofilesctl set power-saver"
sleep 4
s=$(state)
is "YouTube unloaded in power saver" site_has youtube "loaded=false" "$s"
is "Messages (kept loaded) still loaded" site_has messages "loaded=true" "$s"
run "sudo powerprofilesctl set balanced"

step "a quick pass over the icons opens nothing; clicking away folds it up"
"$VM" move 960 600
sleep 1
for x in "$(cx 0)" "$(cx 1)" "$(cx 2)" "$(cx 3)"; do
	"$VM" move "$x" 15
	sleep 0.15
done
"$VM" move 960 600
sleep 1
is "sweeping across the icons opened nothing" test "$(field shown "$(state)")" = false
"$VM" click "$(cx 2)" 15
sleep 3
"$VM" click 300 900 # the wallpaper
sleep 2
is "a click on the wallpaper folded it up" test "$(field shown "$(state)")" = false

step "hover opens, leaving closes; a click inside keeps it open"
"$VM" move 960 600 # off the icons first: the last click left the pointer on one
sleep 1
shot 08-before-hover
"$VM" move "$(cx 3)" 15
sleep 3 # past the open animation and the page's first paint
s=$(state)
is "hover opened YouTube" test "$(field active "$s") $(field shown "$s")" = "youtube true"
shot 08-hover
# Under its icon, not wherever the last site was or the middle: the screen changed below the
# icon, and not at the far side of the screen from it.
far=$(($(cx 3) > 960 ? 100 : 1820))
moved=$(
	python3 -I - "$OUT/08-before-hover.png" "$OUT/08-hover.png" "$(cx 3)" "$far" "$((TOP + 80))" <<'EOF'
import sys
from PIL import Image
from PIL import ImageChops, ImageStat
a, b = Image.open(sys.argv[1]).convert("L"), Image.open(sys.argv[2]).convert("L")
ix, fx, y = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
# A block, not a pixel: a loading page is nearly the colour of what it covers.
d = lambda x: ImageStat.Stat(ImageChops.difference(a.crop((x - 20, y - 20, x + 20, y + 20)), b.crop((x - 20, y - 20, x + 20, y + 20)))).mean[0]
print(f"{int(d(ix) > 4)} {int(d(fx) > 4)}")
EOF
)
is "the hover-opened drawer is under its icon (under icon, far side changed: $moved)" test "$moved" = "1 0"
"$VM" move 960 1000
sleep 1.5
is "pointer left: folded up" test "$(field shown "$(state)")" = false
"$VM" move "$(cx 3)" 15
sleep 1
read -r ww wh <<<"$(field window "$(state)")"
"$VM" click "$(cx 3)" $((TOP + wh / 2))
sleep 1
"$VM" move 960 1000
sleep 1.5
s=$(state)
is "clicked inside: stays open after the pointer leaves" test "$(field shown "$s") $(field engaged "$s")" = "true true"
"$VM" key esc
sleep 2

step "environments: their own drawer sites"
run "setsid -f gtk-launch org.gnome.Nautilus.desktop </dev/null >/dev/null 2>&1"
sleep 4
run "$OSTRICH env save Drawer env" | sed 's/^/    /'
run "$OSTRICH env drawer drawer-env clear; $OSTRICH env drawer drawer-env add claude; $OSTRICH env drawer drawer-env add youtube --keep" | sed 's/^/    /'
run "nautilus -q" || true
sleep 2
run "$OSTRICH env open drawer-env"
sleep 5
s=$(state)
shot 09-env
is "bar is the environment's (claude youtube)" test "$(field bar "$s") $(field set "$s")" = "claude youtube true"
is "its kept site is loaded" site_has youtube "keep=true" "$s"
run "$OSTRICH env close drawer-env"
sleep 3
s=$(state)
is "closed: the normal sites are back" test "$(field bar "$s") $(field set "$s")" = "messages chat claude youtube false"

step "closing only hides it, and it isn't in the overview"
"$VM" move 960 600
sleep 1
"$VM" click "$(cx 2)" 15
sleep 3
"$VM" key alt-f4
sleep 2
s=$(state)
is "Alt+F4 folded it up" test "$(field shown "$s")" = false
is "the drawer is still running" run "pgrep -x ostrich-drawer >/dev/null"
"$VM" click "$(cx 2)" 15
sleep 3
"$VM" key meta_l
sleep 2
shot 10-overview # visual: no drawer window among the overview's windows
"$VM" key esc
sleep 2

step "+ adds sites, and says when it can't"
# The button itself: its menu opens under it, and a name typed there adds the site.
"$VM" move 960 600
sleep 1
shot 12-before-add
"$VM" click "$plus" 15
sleep 2
shot 12-add-menu
opened=$(
	python3 -I - "$OUT/12-before-add.png" "$OUT/12-add-menu.png" "$plus" <<'EOF'
import sys
from PIL import Image, ImageChops, ImageStat
a, b, x = Image.open(sys.argv[1]).convert("L"), Image.open(sys.argv[2]).convert("L"), int(sys.argv[3])
box = (max(0, x - 150), 45, min(a.width, x + 150), 200)
print(round(ImageStat.Stat(ImageChops.difference(a.crop(box), b.crop(box))).mean[0], 1))
EOF
)
is "+ opens its menu (diff under it $opened)" python3 -I -c "import sys; sys.exit(0 if float('$opened') > 8 else 1)"
"$VM" key w h a t s a p p
"$VM" key ret
sleep 2
s=$(state)
is "a name typed in its menu adds the site" test "$(field added "$s")" = whatsapp
"$VM" key esc
act() { run "gdbus call --session --dest ubuntu_ostrich.drawer --object-path /ubuntu_ostrich/drawer --method org.gtk.Actions.Activate $1 \"[<'$2'>]\" {}" >/dev/null; }
act remove whatsapp
sleep 1
act add whatsapp
sleep 2
s=$(state)
is "added WhatsApp from the catalog" test "$(field added "$s")" = whatsapp
act add 'not a site'
sleep 1
s=$(state)
is "a bad address is reported ($(field error "$s"))" test "$(field error "$s")" != None
act add spotify
sleep 1
is "a DRM site is refused" grep -q "DRM" <<<"$(field error "$(state)")"
n=$(field errors "$(state)")
act add 'not a site'
sleep 1
is "the same mistake twice is reported again" test "$(field errors "$(state)")" -gt "$n"
act remove whatsapp
sleep 1
# What the + menu shows: a bad address gets a line under the field, and an address added
# while offline says it will load later.
"$VM" click "$plus" 15
sleep 2
shot 13-menu-empty
"$VM" key n o t spc a spc s i t e
"$VM" key ret
sleep 2
shot 13-menu-error
grew=$(
	python3 -I - "$OUT/13-menu-empty.png" "$OUT/13-menu-error.png" "$plus" <<'EOF'
import sys
from PIL import Image, ImageChops, ImageStat
a, b, x = Image.open(sys.argv[1]).convert("L"), Image.open(sys.argv[2]).convert("L"), int(sys.argv[3])
box = (max(0, x - 200), 104, min(a.width, x + 200), 132)  # the line under the address field
print(round(ImageStat.Stat(ImageChops.difference(a.crop(box), b.crop(box))).mean[0], 1))
EOF
)
is "a typed bad address shows a message under the field (diff $grew)" python3 -I -c "import sys; sys.exit(0 if float('$grew') > 4 else 1)"
"$VM" key esc
# Offline as GLib sees it: no default route (turning networking off would cut this SSH too).
gw=$(run "ip route show default | awk '{print \$3; exit}'")
run "sudo ip route del default" || true
sleep 2
"$VM" click "$plus" 15
sleep 2
"$VM" key e x a m p l e dot o r g
"$VM" key ret
sleep 2
shot 13-menu-offline
s=$(state)
is "an address typed while offline is added" test "$(field added "$s")" = example
still=$(
	python3 -I - "$OUT/12-before-add.png" "$OUT/13-menu-offline.png" "$plus" <<'EOF'
import sys
from PIL import Image, ImageChops, ImageStat
a, b, x = Image.open(sys.argv[1]).convert("L"), Image.open(sys.argv[2]).convert("L"), int(sys.argv[3])
box = (max(0, x - 150), 45, min(a.width, x + 150), 200)
print(round(ImageStat.Stat(ImageChops.difference(a.crop(box), b.crop(box))).mean[0], 1))
EOF
)
is "the menu stays open to say so (diff $still)" python3 -I -c "import sys; sys.exit(0 if float('$still') > 8 else 1)"
"$VM" key esc
run "sudo ip route add default via $gw" || true
act remove example
sleep 1
# A page that can't load says so (never a blank panel). .invalid names never resolve, so it fails
# at once, unlike a cut network (the VM's DNS answers without a route).
run "$HOST --add https://nothing.invalid/"
run "$HOST --show nothing >/dev/null 2>&1 &"
for _ in $(seq 15); do
	site_has nothing "failed=true" "$(state)" && break
	sleep 2
done
shot 13b-failed-load
is "a page that can't load says so" site_has nothing "failed=true" "$(state)"
"$VM" key esc
act remove nothing
sleep 1

step "keys: Super+Alt+Tab opens the next site (Shift: the previous); Ctrl+Tab and Ctrl+2 switch inside the drawer"
s=$(state)
read -ra bar_ids <<<"$(field bar "$s")"
"$VM" key meta_l-alt-tab
sleep 3
s=$(state)
is "Super+Alt+Tab opened the drawer on a site ($(field active "$s"), shown $(field shown "$s"))" test "$(field shown "$s")" = true
now=$(field active "$s")
"$VM" key ctrl-tab
sleep 2
s=$(state)
after=$(field active "$s")
want=$(python3 -I -c "b='${bar_ids[*]}'.split(); print(b[(b.index('$now') + 1) % len(b)])")
is "Ctrl+Tab inside the drawer goes to the next site ($now -> $after, wanted $want)" test "$after" = "$want"
"$VM" key ctrl-2
sleep 2
is "Ctrl+2 goes to the second site (${bar_ids[1]})" test "$(field active "$(state)")" = "${bar_ids[1]}"
"$VM" key meta_l-alt-shift-tab
sleep 2
want=$(python3 -I -c "b='${bar_ids[*]}'.split(); print(b[(b.index('${bar_ids[1]}') - 1) % len(b)])")
is "Super+Alt+Shift+Tab goes back ($want)" test "$(field active "$(state)")" = "$want"
"$VM" key esc
sleep 2

step "an app pinned to the drawer opens in the same floating window; middle click quits it"
# Nothing else out, so the shots below differ only by the app.
[[ $(field shown "$(state)") == true ]] && "$VM" key meta_l-alt-d && sleep 2
# The pointer off the top bar: a new icon shifts the others, and a pointer resting on one would
# hover-open whatever site slides under it.
"$VM" move 960 700
sleep 1
shot 20-before-pin
run "$DS set $DRAWER_SCHEMA pinned-apps \"['org.gnome.Calculator.desktop']\""
sleep 3
shot 21-pinned
# The app's icon is the last one that appeared (the group sits against quick settings).
app_x=$(
	python3 -I - "$OUT/20-before-pin.png" "$OUT/21-pinned.png" "$TOP" <<'PYEND'
import sys
from PIL import Image, ImageChops
a, b = (Image.open(f).convert("L") for f in sys.argv[1:3])
top = int(sys.argv[3])
d = ImageChops.difference(a.crop((0, 0, a.width, top)), b.crop((0, 0, b.width, top)))
cols = [x for x in range(d.width * 3 // 5, d.width) if max(d.getpixel((x, y)) for y in range(4, top - 4)) > 40]
segs, start, prev = [], None, None
for x in cols:
    if start is None:
        start = prev = x
    elif x - prev > 6:
        segs.append((start, prev)); start = x
    prev = x
if start is not None:
    segs.append((start, prev))
print((segs[-1][0] + segs[-1][1]) // 2 if segs else 0)
PYEND
)
is "the pinned app has an icon in the top bar (x $app_x)" test "${app_x:-0}" -gt 1500
# Not running yet: grey. One click launches it into the drawer's place, under its icon.
"$VM" click "$app_x" 15
sleep 8
shot 22-app-out
changed() { # png png x y: did the pixel at x,y change
	python3 -I - "$@" <<'PYEND'
import sys
from PIL import Image
a, b = Image.open(sys.argv[1]).convert("RGB"), Image.open(sys.argv[2]).convert("RGB")
x, y = int(sys.argv[3]), int(sys.argv[4])
print(int(sum(abs(p - q) for p, q in zip(a.getpixel((x, y)), b.getpixel((x, y)))) > 30))
PYEND
}
is "the app's window is out under its icon" test "$(changed "$OUT/21-pinned.png" "$OUT/22-app-out.png" "$((app_x - 100))" "$((TOP + 200))")" = 1
is "and not at the far side of the screen" test "$(changed "$OUT/21-pinned.png" "$OUT/22-app-out.png" 100 "$((TOP + 200))")" = 0
"$VM" click "$app_x" 15
sleep 3
shot 23-app-away
is "its icon again puts it away" test "$(changed "$OUT/21-pinned.png" "$OUT/23-app-away.png" "$((app_x - 100))" "$((TOP + 200))")" = 0
"$VM" click "$app_x" 15 middle
sleep 4
is "a middle click quit the app" test "$(run 'pgrep -c -x gnome-calculator || true')" = 0
run "$DS set $DRAWER_SCHEMA pinned-apps \"@as []\""
sleep 2
shot 24-unpinned
is "unpinning removes its icon" test "$(changed "$OUT/21-pinned.png" "$OUT/24-unpinned.png" "$app_x" 15)" = 1

step "crashes"
# Including xdg-desktop-portal: it crashed on every drawer page while the app id had a dash before
# its last dot (fixed 2026-10-31; see DECISIONS).
c=$(run 'journalctl -b -o cat | grep -E "segfault|dumped core|g_propagate_error" || true')
is "no crashes, the desktop portal's included" test -z "$c"
[[ -z $c ]] || while IFS= read -r l; do echo "    $l"; done <<<"$c"

step "no JS errors"
n=$(run 'journalctl --user -b -o cat /usr/bin/gnome-shell | grep -c "JS ERROR" || true')
if [[ $n == 0 ]]; then ok "no JS errors"; else bad "$n JS errors"; fi
run 'journalctl --user -b -o cat /usr/bin/gnome-shell | grep -A3 "JS ERROR" | head -20' || true

journal_gate
"$VM" stop
echo
if ((failures == 0)); then echo "PASS (screenshots in $OUT)"; else echo "$failures FAILED (screenshots in $OUT)"; fi
((failures == 0))
