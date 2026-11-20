#!/usr/bin/env bash
# tests/vm/env-test.sh: environments and focus with an allow-list, in the test VM.
#
#   env-test.sh [--snapshot NAME] [--out DIR]
#
# Needs a snapshot with Ubuntu Ostrich installed (default: post-fresh, saved by
# `e2e.sh --pipe post-fresh`). Opens Files and Text Editor, saves them as a workspace ("environment"
# in the code), closes them, opens it again and checks both windows come back in their places on a
# new workspace named after it; opens Calculator there too, then closes it (`ostrich workspace`):
# every window goes, the workspace and its name go, and the saved file now has Calculator (closing
# saves where you left off). Then checks focus with only Files allowed keeps Text Editor minimised.
# The focus, dock and blur extensions from this checkout replace the installed ones. Window state comes from the extension's D-Bus State method. Screenshots go to DIR.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
ROOT="$(cd "$HERE/../.." && pwd)"
VM="$HERE/vm.sh"
PROJECT="ubuntu-ostrich"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
SNAPSHOT=post-fresh
OUT="$VM_DIR/env-test"
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	--out) OUT=$2 && shift ;;
	*)
		echo "usage: env-test.sh [--snapshot NAME] [--out DIR]" >&2
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
# shellcheck disable=SC2016 # expands in the VM
OSTRICH='$HOME/.local/bin/ostrich'
# shellcheck disable=SC2016 # expands in the VM
FOCUS='gsettings --schemadir $HOME/.local/share/gnome-shell/extensions/focus@ubuntu-ostrich/schemas set org.gnome.shell.extensions.ubuntu-ostrich.focus allowed-apps'
# is MESSAGE COMMAND...: ok or FAIL depending on COMMAND.
is() {
	local msg=$1
	shift
	if "$@"; then ok "$msg"; else bad "$msg"; fi
}
not() { ! "$@"; }
indent() { while IFS= read -r l; do printf '    %s\n' "$l"; done <<<"$1"; }
FILES=org.gnome.Nautilus.desktop
EDITOR=org.gnome.TextEditor.desktop
# The State JSON, as one "app workspace x y w h minimized" line per window, plus "active N" / "open ...".
state() {
	run "gdbus call --session --dest org.ubuntuostrich.Environments --object-path /org/ubuntuostrich/Environments --method org.ubuntuostrich.Environments.State" |
		python3 -I -c '
import ast, json, sys
s = json.loads(ast.literal_eval(sys.stdin.read().strip())[0])
print("active", s["activeWorkspace"])
print("open", " ".join(s["open"]) or "-")
print("count", s.get("workspaces", -1))
for w in s["windows"]:
    print(w["app"], w["workspace"], w["x"], w["y"], w["width"], w["height"], str(w["minimized"]).lower())'
}
count_app() { grep -c "^$1 " <<<"$2" || true; }
quit_apps() {
	run "nautilus -q 2>/dev/null; pkill -f '[g]nome-text-editor'; pkill -f '[g]nome-calculator'; true"
	sleep 2
}

rm -rf "$OUT"
mkdir -p "$OUT"

step "start from $SNAPSHOT"
"$VM" stop
"$VM" snapshot restore "$SNAPSHOT"
"$VM" start
sleep 10
"$ROOT/modules/gnome/extensions/build.sh" focus dock blur >/dev/null
for e in focus dock blur; do
	"$VM" copy "$ROOT/dist/$e@ubuntu-ostrich.shell-extension.zip" "/tmp/$e.zip"
	run "gnome-extensions install --force /tmp/$e.zip"
done
# This checkout's ostrich command too (`ostrich workspace`), from the VM tools build if there is one.
if [[ -x $VM_DIR/tools-bin/ostrich ]]; then
	"$VM" copy "$VM_DIR/tools-bin/ostrich" /tmp/ostrich
	run "install -m 755 /tmp/ostrich \$HOME/.local/bin/ostrich"
fi
sleep 30 # past the start-up window in which a power-off can make GNOME switch extensions off
"$VM" stop
"$VM" start
sleep 30
run "$FOCUS '[]'"

step "save: Files and Text Editor on workspace 1"
run "setsid -f gtk-launch $FILES </dev/null >/dev/null 2>&1; setsid -f gtk-launch $EDITOR </dev/null >/dev/null 2>&1"
sleep 6
shot 01-two-apps
before=$(state)
indent "$before"
out=$(run "$OSTRICH env save Test env" 2>&1) || true
if [[ $out == *"saved"* ]]; then ok "$out"; else bad "save: $out"; fi
apps=$(run "python3 -c 'import json,os; print(len(json.load(open(os.path.expanduser(\"~/.config/ubuntu-ostrich/environments/test-env.json\")))[\"apps\"]))'" 2>&1 || true)
if [[ $apps == 2 ]]; then ok "file has 2 apps"; else bad "file apps: $apps"; fi
list=$(run "$OSTRICH env list" 2>&1 || true)
if [[ $list == *"Test env"*"2 app(s)"* ]]; then ok "listed"; else bad "list: $list"; fi

step "open: both come back on a new workspace, in their places"
quit_apps
run "$OSTRICH env open test-env"
sleep 10
shot 02-env-open
after=$(state)
indent "$after"
is "test-env is marked open" grep -qx "open test-env" <<<"$after"
ws=$(sed -n 's/^active //p' <<<"$after")
if ((ws > 0)); then ok "on workspace $ws"; else bad "still on workspace $ws"; fi
for app in $FILES $EDITOR; do
	read -r _ w0 x0 y0 wd0 h0 _ < <(grep "^$app " <<<"$before" | head -1)
	read -r _ w1 x1 y1 wd1 h1 _ < <(grep "^$app " <<<"$after" | head -1) || true
	if [[ -z ${w1:-} ]]; then
		bad "$app did not come back"
		continue
	fi
	d=$((x1 - x0)) && d=${d#-}
	e=$((y1 - y0)) && e=${e#-}
	f=$((wd1 - wd0)) && f=${f#-}
	g=$((h1 - h0)) && g=${g#-}
	if [[ $w1 == "$ws" ]] && ((d + e + f + g <= 40)); then
		ok "$app back at $x1,$y1 ${wd1}x$h1 (saved $x0,$y0 ${wd0}x$h0)"
	else
		bad "$app at ws $w1 $x1,$y1 ${wd1}x$h1, saved $x0,$y0 ${wd0}x$h0 (ws $w0)"
	fi
	unset w1
done

names() { run "gsettings get org.gnome.desktop.wm.preferences workspace-names"; }
step "named after the saved workspace (note 20261101-225435)"
n=$(names)
if [[ $n == *"'Test env'"* ]]; then ok "workspace $ws is named: $n"; else bad "workspace names: $n"; fi
count_open=$(sed -n 's/^count //p' <<<"$after")

step "close (ostrich workspace): saves where you left off, closes every window, removes the workspace"
CALC=org.gnome.Calculator.desktop
run "setsid -f gtk-launch $CALC </dev/null >/dev/null 2>&1"
sleep 4
run "$OSTRICH workspace close test-env"
sleep 6
closed=$(state)
indent "$closed"
is "windows closed" test "$(count_app $FILES "$closed")$(count_app $EDITOR "$closed")$(count_app $CALC "$closed")" = 000
is "back on workspace 0" grep -qx "active 0" <<<"$closed"
is "nothing open" grep -qx "open -" <<<"$closed"
count_closed=$(sed -n 's/^count //p' <<<"$closed")
if ((count_closed < count_open)); then ok "the workspace went ($count_open -> $count_closed)"; else bad "workspaces: $count_open -> $count_closed"; fi
n=$(names)
if [[ $n != *"'Test env'"* ]]; then ok "its name went ($n)"; else bad "the name stayed: $n"; fi
saved=$(run "python3 -c 'import json,os; print(\" \".join(a[\"app\"] for a in json.load(open(os.path.expanduser(\"~/.config/ubuntu-ostrich/environments/test-env.json\")))[\"apps\"]))'" 2>&1 || true)
if [[ $saved == *"$CALC"* ]]; then ok "closing saved where it was left: $saved"; else bad "the saved layout wasn't updated: $saved"; fi

step "a saved workspace closed by hand takes its name with it"
run "$OSTRICH workspace open test-env"
sleep 10
quit_apps
sleep 4
handclosed=$(state)
is "it counts as closed" grep -qx "open -" <<<"$handclosed"
n=$(names)
if [[ $n != *"'Test env'"* ]]; then ok "no workspace kept its name ($n)"; else bad "a workspace kept the name: $n"; fi

step "what was inside the apps: Files folders, a terminal folder, a browser's pages (owner, 2026-11-20)"
# shellcheck disable=SC2016 # expands in the VM
STATE_FILE='$HOME/.config/ubuntu-ostrich/environments/state-test.json'
# The saved windows of one app, as one line each: "open: URI URI" or "cwd: PATH" or "-".
saved_windows() { # app
	run "python3 -c '
import json, os, sys
env = json.load(open(os.path.expandvars(\"$STATE_FILE\")))
for a in env[\"apps\"]:
    if a[\"app\"] == sys.argv[1]:
        for w in a[\"windows\"]:
            print(\"open: \" + \" \".join(w[\"open\"]) if \"open\" in w else (\"cwd: \" + w[\"cwd\"] if \"cwd\" in w else \"-\"))
' $1"
}
run "mkdir -p /tmp/site && printf '<title>State page one</title><p>1</p>' > /tmp/site/one.html && printf '<title>State page two</title><p>2</p>' > /tmp/site/two.html && (cd /tmp/site && setsid -f python3 -m http.server 8767 </dev/null >/dev/null 2>&1)"
FIREFOX=$(run "ls /usr/share/applications /var/lib/snapd/desktop/applications 2>/dev/null | grep -i -m1 '^firefox'" || true)
GHOSTTY=$(run "ls /usr/share/applications | grep -m1 '^com.mitchellh.ghostty.desktop'" || true)
run "setsid -f nautilus --new-window /usr/share </dev/null >/dev/null 2>&1; sleep 2; setsid -f nautilus --new-window /var/lib </dev/null >/dev/null 2>&1"
[[ -z $GHOSTTY ]] || run "setsid -f ghostty --working-directory=/usr/share/icons </dev/null >/dev/null 2>&1"
[[ -z $FIREFOX ]] || run "setsid -f firefox --new-window http://localhost:8767/one.html --new-tab http://localhost:8767/two.html </dev/null >/dev/null 2>&1"
sleep 25 # Firefox writes its session file every 15 s
shot 05-state-before
out=$(run "$OSTRICH env save State test" 2>&1) || true
if [[ $out == *"saved"* ]]; then ok "saved with what was inside"; else bad "save: $out"; fi
files_saved=$(saved_windows $FILES)
indent "$files_saved"
is "Files: both folders saved" test "$(grep -c '^open: file:///' <<<"$files_saved")" = 2
is "Files: /usr/share is one of them" grep -q "file:///usr/share$" <<<"$files_saved"
if [[ -n $GHOSTTY ]]; then
	term_saved=$(saved_windows com.mitchellh.ghostty.desktop)
	indent "$term_saved"
	is "the terminal's folder saved" grep -q "^cwd: /usr/share/icons$" <<<"$term_saved"
else echo "  (Ghostty isn't in this VM: the terminal's folder isn't checked)"; fi
if [[ -n $FIREFOX ]]; then
	ff_saved=$(saved_windows "$FIREFOX")
	indent "$ff_saved"
	# Firefox adds a tab of its own on a first run, so: both pages, in order, in one window.
	is "Firefox: both pages saved, in order, in one window" test "$(grep -c '^open: http://localhost:8767/one.html http://localhost:8767/two.html' <<<"$ff_saved")" = 1
else echo "  (Firefox isn't in this VM: the pages aren't checked)"; fi
run "nautilus -q 2>/dev/null; pkill -f '[g]hostty'; pkill -f '[f]irefox'; true"
sleep 4
run "$OSTRICH env open state-test"
sleep 25
shot 06-state-reopened
reopened=$(state)
indent "$reopened"
is "both Files windows are back" test "$(count_app $FILES "$reopened")" = 2
# An app started with its saved state has a scope of its own, as a launched app does, not the shell's unit.
[[ -z $GHOSTTY ]] || is "the terminal runs in its own scope, not the shell's" test "$(run 'for p in $(pgrep -x ghostty); do cat /proc/$p/cgroup; done' | grep -c 'org.gnome.Shell')" = 0
# Closing saves where you left off: what the reopened windows show must be what was saved.
run "$OSTRICH workspace close state-test"
sleep 8
files_again=$(saved_windows $FILES)
is "the Files windows show the same folders again" test "$(sort <<<"$files_again")" = "$(sort <<<"$files_saved")"
[[ -z $GHOSTTY ]] || is "the terminal is in the same folder again" test "$(saved_windows com.mitchellh.ghostty.desktop)" = "$term_saved"
[[ -z $FIREFOX ]] || is "Firefox shows the same pages again, in one window" test "$(saved_windows "$FIREFOX" | grep -c '^open: http://localhost:8767/one.html http://localhost:8767/two.html')" = 1
[[ -z $FIREFOX ]] || is "and it is the only Firefox window" test "$(count_app firefox_firefox.desktop "$reopened")" = 1

step "a version 1 file and a hand-edited one"
run "python3 - <<'PYEND'
import json, os
d = os.path.expanduser('~/.config/ubuntu-ostrich/environments')
win = {'monitor': 0, 'x': 10, 'y': 40, 'width': 800, 'height': 600, 'maximized': False}
json.dump({'version': 1, 'name': 'Old one', 'apps': [{'app': '$FILES', 'windows': [win]}]}, open(d + '/old-one.json', 'w'))
evil = dict(win, open=['javascript:alert(1)', 'file:///usr/share', 'about:config'], cwd='relative/path')
json.dump({'version': 2, 'name': 'Edited', 'apps': [{'app': '$FILES', 'windows': [evil]}]}, open(d + '/edited.json', 'w'))
PYEND"
list=$(run "$OSTRICH env list" 2>&1 || true)
is "a version 1 workspace is still listed" grep -q "Old one" <<<"$list"
is "so is the edited one" grep -q "Edited" <<<"$list"
run "$OSTRICH env open edited"
sleep 8
edited=$(state)
is "the edited workspace opens (only its Files window)" test "$(count_app $FILES "$edited")" -ge 1
run "$OSTRICH workspace close edited"
sleep 6
run "$OSTRICH env delete old-one; $OSTRICH env delete edited; $OSTRICH env delete state-test; true"
quit_apps

step "focus with only Files allowed"
run "$FOCUS \"['$FILES']\""
run "setsid -f gtk-launch $FILES </dev/null >/dev/null 2>&1; setsid -f gtk-launch $EDITOR </dev/null >/dev/null 2>&1"
sleep 6
"$VM" key meta_l-alt-f
sleep 2
s=$(state)
indent "$s"
is "Text Editor minimised" grep -q "^$EDITOR .* true$" <<<"$s"
is "Files still shown" grep -q "^$FILES .* false$" <<<"$s"
shot 03-focus-allow
"$VM" key meta_l
sleep 1
"$VM" key t e x t
sleep 2
shot 04-focus-search-text # visual: Text Editor must not be in the results
"$VM" key esc
"$VM" key esc
sleep 1
run "setsid -f gtk-launch $EDITOR </dev/null >/dev/null 2>&1"
sleep 3
s=$(state)
is "launching Text Editor in focus keeps it minimised" not grep -q "^$EDITOR .* false$" <<<"$s"
"$VM" key meta_l-alt-f
sleep 2
s=$(state)
is "focus off: Text Editor back" not grep -q "^$EDITOR .* true$" <<<"$s"
shot 05-focus-off
run "$FOCUS '[]'"
quit_apps

step "no JS errors"
n=$(run 'journalctl --user -b -o cat /usr/bin/gnome-shell | grep -c "JS ERROR" || true')
if [[ $n == 0 ]]; then ok "no JS errors"; else bad "$n JS errors"; fi
"$VM" ssh 'journalctl --user -b -o cat /usr/bin/gnome-shell | grep -A3 "JS ERROR" | head -20' || true

journal_gate
echo
if ((failures == 0)); then echo "PASS (screenshots in $OUT)"; else echo "$failures FAILED (screenshots in $OUT)"; fi
((failures == 0))
