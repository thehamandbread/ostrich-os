#!/usr/bin/env bash
# tests/vm/alert-test.sh: the monitor's pop-out alert (_lib/alert.js) for memory nearly full, in the
# test VM (docs/FEATURES.md MON-6, ALERT-1..3).
#
#   alert-test.sh [--snapshot NAME]     (default: try-me-0.1.5b)
#
# Installs the monitor from this checkout (ext-test.sh), turns swap off in the VM so memory fills
# quickly, and runs a "memhog" app (its own app-*.scope, as GNOME launches apps) that takes memory
# until 88 % is used. Then: the pop-out appears with "End memhog" (found by name, as a screen reader
# finds it); the first click asks (a short question, its warning read with it), the second ends the app's scope; nothing logs a JS error. Swap is
# turned back on at the end. Screenshots go to $VM_DIR/alert-test.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ubuntu-ostrich/vm}"
OUT="$VM_DIR/alert-test"
SNAPSHOT=try-me-0.1.5b
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	*)
		echo "usage: alert-test.sh [--snapshot NAME]" >&2
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
shot() { "$VM" screenshot "$OUT/$1.png" >/dev/null; }
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0;'
run() { "$VM" ssh "$SESSION $*"; }
tree() { run "python3 - $*" <"$HERE/a11y-tree.py"; }
js_errors() { run 'journalctl --user -b -o cat /usr/bin/gnome-shell | grep -c "JS ERROR" || true'; }
UNIT=app-gnome-memhog-1.scope

rm -rf "$OUT"
mkdir -p "$OUT"

step "install the monitor from this checkout"
"$HERE/ext-test.sh" --snapshot "$SNAPSHOT" --cycles 2 monitor
run "pkill -x ostrich-setup; gsettings set org.gnome.desktop.session idle-delay 0; true"
errors_before=$(js_errors)
"$VM" move 960 700

step "fill memory with an app"
run "sudo swapoff -a"
# Takes memory in 64 MB steps until 88 % of it is in use, then holds it.
run "setsid -f systemd-run --user --scope --unit=$UNIT python3 -c '
import time
def used():
    m = dict((l.split(\":\")[0], int(l.split()[1])) for l in open(\"/proc/meminfo\"))
    return 1 - m[\"MemAvailable\"] / m[\"MemTotal\"]
hog = []
while used() < 0.88:
    hog.append(bytearray(64 << 20))
time.sleep(600)
' >/dev/null 2>&1"
found=""
for _ in $(seq 20); do
	sleep 2
	if found=$(tree where "'End memhog'" 2>/dev/null); then # quoted for the VM's shell
		break
	fi
	found=""
done
shot 01-alert
if [[ -n $found ]]; then
	ok "the pop-out offers End memhog (at $found)"
else
	bad "no pop-out with End memhog"
	run "journalctl --user -b -o cat /usr/bin/gnome-shell | grep -iE 'monitor|alert|memory' | tail -8; grep -E 'MemTotal|MemAvailable|Swap(Total|Free)' /proc/meminfo; gsettings --schemadir \$HOME/.local/share/gnome-shell/extensions/monitor@ubuntu-ostrich/schemas get org.gnome.shell.extensions.ubuntu-ostrich.monitor memory-warning" | sed 's/^/    /'
fi

if [[ -n $found ]]; then
	step "End asks first, then ends the app"
	read -r x y <<<"$found"
	"$VM" click "$x" "$y"
	sleep 1
	shot 02-confirm
	if run "systemctl --user is-active --quiet $UNIT"; then ok "one click only asks"; else bad "the first click already ended it"; fi
	# The question is short (a long one was cut off in the button, "End memhog? Unsa..."); the warning is
	# in the card's wrapping text and read with it.
	if tree where "'End memhog? Unsaved work is lost.'" >/dev/null 2>&1; then ok "the question and its warning are read together"; else bad "no button named 'End memhog? Unsaved work is lost.'"; fi
	"$VM" click "$x" "$y"
	sleep 3
	if run "systemctl --user is-active --quiet $UNIT"; then bad "memhog still running after confirming"; else ok "memhog ended"; fi
	shot 03-ended
fi

run "systemctl --user stop $UNIT 2>/dev/null; sudo swapon -a; true"

step "no JS errors"
errors_after=$(js_errors)
if [[ $errors_after == "$errors_before" ]]; then ok "no new JS errors"; else bad "JS errors: $errors_before before, $errors_after after"; fi

journal_gate
"$VM" stop
echo
if ((failures == 0)); then echo "PASS (screenshots in $OUT)"; else echo "$failures FAILED (screenshots in $OUT)"; fi
((failures == 0))
