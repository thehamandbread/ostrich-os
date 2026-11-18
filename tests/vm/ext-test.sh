#!/usr/bin/env bash
# tests/vm/ext-test.sh: install built extensions in the test VM and check they behave.
#
#   ext-test.sh [--snapshot NAME] [--cycles N] [--menus] <name>...   (names as in modules/gnome/extensions/)
#
# Per extension, after a re-login (Wayland loads new extensions only at login):
#   - state ACTIVE, no "JS ERROR" for its uuid, disable-user-extensions still false
#   - two rounds of N disable/enable cycles (default 20): still ACTIVE, still no errors, and the
#     second round grows gnome-shell RSS by under RSS_LIMIT_MB (default 15; the first settles caches)
#   - with --menus, each cycle also opens and closes the clock menu and quick settings, so widgets
#     built on open are counted (council 2026-11-09: baseline +12 MB, then +0 over 2 x 20)
# Leaves the VM running so behaviour checks can follow; stop it with vm.sh stop.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VM="$HERE/vm.sh"
SNAPSHOT=stock
CYCLES=20
MENUS=0
RSS_LIMIT_MB="${RSS_LIMIT_MB:-15}"

log() { printf '[ext-test] %s\n' "$*" >&2; }
fail() {
	log "FAIL: $*"
	exit 1
}

names=()
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	--cycles) CYCLES=$2 && shift ;;
	--menus) MENUS=1 ;;
	*) names+=("$1") ;;
	esac
	shift
done
((${#names[@]} > 0)) || fail "usage: ext-test.sh [--snapshot NAME] [--cycles N] [--menus] <name>..."

"$ROOT/modules/gnome/extensions/build.sh" "${names[@]}" >&2
uuids=()
for n in "${names[@]}"; do
	uuids+=("$(sed -n 's/^ *"uuid": *"\([^"]*\)".*/\1/p' "$ROOT/modules/gnome/extensions/$n/metadata.json")")
done

"$VM" stop
"$VM" snapshot restore "$SNAPSHOT"
"$VM" start
for u in "${uuids[@]}"; do
	"$VM" copy "$ROOT/dist/$u.shell-extension.zip" "/tmp/$u.zip"
	"$VM" ssh "gnome-extensions install --force /tmp/$u.zip"
done
# The shell doesn't know these yet, so enable them in one gsettings write (separate
# `gnome-extensions enable` calls race on the same key). They load at the next login.
"$VM" ssh "python3 - ${uuids[*]}" <<'PY'
import ast, subprocess, sys
cur = ast.literal_eval(subprocess.check_output(["gsettings", "get", "org.gnome.shell", "enabled-extensions"], text=True).replace("@as ", ""))
new = cur + [u for u in sys.argv[1:] if u not in cur]
subprocess.check_call(["gsettings", "set", "org.gnome.shell", "enabled-extensions", str(new)])
PY
"$VM" stop
"$VM" start
sleep 20
# Keep the screen awake: the run is longer than the 5-minute idle lock, and GNOME switches off
# every extension that doesn't run on the lock screen when it locks, which looked like an
# extension going INACTIVE by itself (the dock and the drawer, each third in a long run).
"$VM" ssh "gsettings set org.gnome.desktop.session idle-delay 0; gsettings set org.gnome.desktop.screensaver lock-enabled false"

# Runs inside the VM: prints "ok" or a reason. (This and shell_rss_kb expand in the VM.)
# shellcheck disable=SC2016
check_script='
u=$1
# A login can take a while to enable everything: wait for ACTIVE up to 30 s before calling it a failure
# (the monitor was seen INITIALIZED at the first look, with no error, and ACTIVE seconds later).
for _ in $(seq 30); do
	state=$(gnome-extensions info "$u" | sed -n "s/^ *State: //p")
	[ "$state" = ACTIVE ] && break
	sleep 1
done
[ "$state" = ACTIVE ] || { echo "state=$state screen-locked=$(gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.GetActive 2>/dev/null) enabled-extensions=$(gsettings get org.gnome.shell enabled-extensions)"; journalctl --user -b -o cat /usr/bin/gnome-shell | grep -i "${u%@*}" | tail -8; exit 0; }
[ "$(gsettings get org.gnome.shell disable-user-extensions)" = false ] || { echo "disable-user-extensions=true"; exit 0; }
errs=$(journalctl --user -b -o cat /usr/bin/gnome-shell | grep -c "JS ERROR.*$u" || true)
[ "$errs" = 0 ] || { echo "js_errors=$errs"; journalctl --user -b -o cat /usr/bin/gnome-shell | grep -A3 "JS ERROR.*$u" | head -12; exit 0; }
echo ok
'
# shellcheck disable=SC2016
shell_rss_kb() { "$VM" ssh 'awk "/^VmRSS:/{print \$2}" /proc/$(pgrep -u $(id -u) -x gnome-shell | head -1)/status'; }

for u in "${uuids[@]}"; do
	r=$("$VM" ssh "bash -s -- $u" <<<"$check_script")
	[[ $r == ok ]] || fail "$u after login: $r"
	log "$u: active, no errors"

	# GJS frees memory lazily, so compare readings taken after warm-up and 30 s idle each; a real
	# leak keeps growing, GC lag doesn't.
	# Each toggle waits for the shell to reach the state (up to 5 s): firing them 0.3 s apart let a
	# slow teardown under llvmpipe swallow the last enable, which looked like an extension bug.
	# shellcheck disable=SC2016 # expands in the VM
	toggle="settle() { for _ in \$(seq 50); do gnome-extensions info $u | grep -q \"State: \$1\" && return; sleep 0.1; done; echo \"$u stuck before \$1\" >&2; }; gnome-extensions disable $u; settle INACTIVE; gnome-extensions enable $u; settle ACTIVE"
	cycle() { "$VM" ssh "for i in \$(seq $1); do $toggle; done"; }
	if ((MENUS)); then
		# The same toggles one at a time, opening and closing both menus after each enable (the
		# clock at the bar's centre, quick settings at its right end, as ui-test.sh clicks them).
		cycle() {
			local i
			for ((i = 0; i < $1; i++)); do
				"$VM" ssh "$toggle"
				"$VM" click 960 15 >/dev/null && sleep 0.8 && "$VM" key esc >/dev/null && sleep 0.3
				"$VM" click 1880 15 >/dev/null && sleep 0.8 && "$VM" key esc >/dev/null && sleep 0.3
			done
		}
	fi
	# Two equal rounds: caches and GC lag settle in the first, a leak keeps growing in the second
	# (blur measured 13-21 MB over 20 cycles but 26 MB over 80: settling, not leaking).
	cycle 5
	sleep 30
	rss0=$(shell_rss_kb)
	cycle "$CYCLES"
	sleep 30
	rss1=$(shell_rss_kb)
	cycle "$CYCLES"
	sleep 30
	rss2=$(shell_rss_kb)
	r=$("$VM" ssh "bash -s -- $u" <<<"$check_script")
	[[ $r == ok ]] || fail "$u after $((2 * CYCLES)) cycles: $r"
	first=$(((rss1 - rss0) / 1024)) second=$(((rss2 - rss1) / 1024))
	((second < RSS_LIMIT_MB)) || fail "$u: gnome-shell RSS kept growing: ${first} MB then ${second} MB over two rounds of $CYCLES cycles"
	log "$u: $((2 * CYCLES)) disable/enable cycles clean (RSS change ${first} MB, then ${second} MB)"
done
log "PASS: ${uuids[*]}"
