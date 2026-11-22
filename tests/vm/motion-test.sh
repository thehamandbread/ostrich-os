#!/usr/bin/env bash
# tests/vm/motion-test.sh: our animations in the test VM (_lib/motion.js), the gate for any change
# to them (council verdict 2026-10-24-motion-now-playing-spotify-colour, M3).
#
#   motion-test.sh [--snapshot NAME] [--cycles N]
#
# Installs this checkout's drawer, dock and tiling (ext-test.sh, which also checks they are ACTIVE
# with no errors), then, for each of animations off, on, and on with Reduced Motion:
#   - the drawer's shortcut opens and closes it N times (default 20) and every toggle ends in the
#     right state;
#   - a close followed by an open 50, 100 and 150 ms later (by the shortcut, and by a click on the
#     wallpaper then the shortcut) always ends open: a slide-out cut short never minimises the
#     drawer that was just reopened;
#   - no JS error appears.
# Screenshots of any failure go to $VM_DIR/motion-test. The VM can't show how a slide looks (its
# screenshots lag the keys), so smoothness and cost are judged on real hardware.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ostrich-os/vm}"
OUT="$VM_DIR/motion-test"
SNAPSHOT=post-fresh
CYCLES=20
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	--cycles) CYCLES=$2 && shift ;;
	*)
		echo "usage: motion-test.sh [--snapshot NAME] [--cycles N]" >&2
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
# The drawer's shortcut (Super+Alt+D), straight to QEMU: vm.sh key waits 0.15 s after each key.
toggle() { printf 'sendkey meta_l-alt-d\n' | socat -t 0.3 - "UNIX-CONNECT:$VM_DIR/monitor.sock" >/dev/null; }
shown() {
	run "gdbus call --session --dest ostrich_os.drawer --object-path /ostrich_os/drawer --method org.gtk.Actions.Describe state" |
		grep -o '"shown":[a-z]*' | cut -d: -f2
}
open_drawer() { [[ $(shown) == true ]] || {
	toggle
	sleep 1
}; }
close_drawer() { [[ $(shown) == false ]] || {
	toggle
	sleep 1
}; }
js_errors() { run 'journalctl --user -b -o cat /usr/bin/gnome-shell | grep -c "JS ERROR" || true'; }

rm -rf "$OUT"
mkdir -p "$OUT"

step "install drawer, dock and tiling from this checkout"
"$HERE/ext-test.sh" --snapshot "$SNAPSHOT" --cycles 5 drawer dock tiling
# No crash-report dialog mid-test: it takes focus, which folds the drawer.
run "sudo systemctl stop apport.service >/dev/null 2>&1; pkill -f '[a]pport-gtk'; pkill -x ostrich-setup; true"
run "gsettings set org.gnome.desktop.session idle-delay 0"
"$VM" move 960 700
errors_before=$(js_errors)
# Warm up: with no site kept loaded (machines under ~12 GB), the drawer's first open of the session
# loads a site first, which can take longer than a toggle's 0.6 s here. Motion is what's measured.
toggle
sleep 5
close_drawer

for mode in off on reduce; do
	step "animations $mode"
	case $mode in
	off) run "gsettings set org.gnome.desktop.interface enable-animations false; gsettings set org.gnome.desktop.a11y.interface reduced-motion no-preference" ;;
	on) run "gsettings set org.gnome.desktop.interface enable-animations true; gsettings set org.gnome.desktop.a11y.interface reduced-motion no-preference" ;;
	reduce) run "gsettings set org.gnome.desktop.interface enable-animations true; gsettings set org.gnome.desktop.a11y.interface reduced-motion reduce" ;;
	esac
	sleep 1
	close_drawer
	right=0
	for i in $(seq "$CYCLES"); do
		toggle
		sleep 0.6
		want=$(((i % 2) == 1 ? 1 : 0))
		[[ $(shown) == "$([[ $want == 1 ]] && echo true || echo false)" ]] && right=$((right + 1))
	done
	if ((right == CYCLES)); then ok "$CYCLES toggles, each in the right state"; else bad "$right of $CYCLES toggles in the right state"; fi
	close_drawer
	for how in key click; do
		for gap in 0.05 0.10 0.15; do
			folded=0
			for i in 1 2 3 4 5; do
				open_drawer
				if [[ $how == key ]]; then toggle; else "$VM" click 300 900; fi
				sleep "$gap"
				toggle
				sleep 0.8
				if [[ $(shown) != true ]]; then
					folded=$((folded + 1))
					"$VM" screenshot "$OUT/folded-$mode-$how-$gap-$i.png" >/dev/null
				fi
			done
			if ((folded == 0)); then ok "closed by $how, reopened ${gap}s later: open 5/5"; else bad "closed by $how, reopened ${gap}s later: folded $folded/5"; fi
		done
	done
	close_drawer
done
run "gsettings set org.gnome.desktop.interface enable-animations true; gsettings set org.gnome.desktop.a11y.interface reduced-motion no-preference"

step "no JS errors"
errors_after=$(js_errors)
if [[ $errors_after == "$errors_before" ]]; then ok "no new JS errors ($errors_after)"; else bad "JS errors: $errors_before before, $errors_after after"; fi
journal_gate
"$VM" stop

echo
if ((failures == 0)); then
	echo "PASS"
else
	echo "FAILED: $failures (screenshots in $OUT)"
	exit 1
fi
