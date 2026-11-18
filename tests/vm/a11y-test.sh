#!/usr/bin/env bash
# tests/vm/a11y-test.sh: what a screen reader hears from our shell extensions, in the test VM
# (council verdict 2026-10-24-motion-now-playing-spotify-colour, Should: accessible names).
#
#   a11y-test.sh [--snapshot NAME]     (default: post-fresh)
#
# Installs this checkout's monitor, dock, workspaces, drawer, focus and tweaks (ext-test.sh, which also checks they
# are ACTIVE with no errors), opens the Monitor popup, then reads GNOME Shell's accessibility tree
# over AT-SPI (a11y-tree.py, in the session) and fails if any of our buttons has no name: the dock,
# the workspace pills, the top-bar menu buttons (drawer icons, Monitor, the now-playing pill if
# present) and the Monitor rows. It also checks the names we build are there.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
SNAPSHOT=post-fresh
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	*)
		echo "usage: a11y-test.sh [--snapshot NAME]" >&2
		exit 2
		;;
	esac
	shift
done

step() { printf '== %s\n' "$*"; }
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0;'
run() { "$VM" ssh "$SESSION $*"; }
tree() { run "python3 - $*" <"$HERE/a11y-tree.py"; }

step "install monitor, dock, workspaces and drawer from this checkout"
"$HERE/ext-test.sh" --snapshot "$SNAPSHOT" --cycles 2 monitor dock workspaces drawer focus tweaks
run "gsettings set org.gnome.desktop.session idle-delay 0"

step "open the Monitor popup (its rows are made when it first opens)"
read -r x y < <(tree where Monitor)
"$VM" click "$x" "$y"
sleep 2

step "names in the accessibility tree"
status=0
tree check || status=1
"$VM" key esc
exit "$status"
