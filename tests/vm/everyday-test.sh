#!/usr/bin/env bash
# tests/vm/everyday-test.sh: what opens everyday files on a fresh install (council verdict
# 2026-10-24, the everyday seat: "which default player" is the owner's question 5, so this reports
# rather than decides).
#
#   everyday-test.sh [--snapshot NAME]       (default: try-me)
#
# For web pages, mail links, PDFs, office documents, photos, music and video: the app GNOME opens
# them with (`gio mime`, which also sees the system's defaults), and whether that app is installed; then whether printing is set up (CUPS).
# Fails only when a web page or a PDF has nothing to open it: those every newcomer meets on day one.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
SNAPSHOT=try-me
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	*)
		echo "usage: everyday-test.sh [--snapshot NAME]" >&2
		exit 2
		;;
	esac
	shift
done

# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0;'
"$VM" stop >/dev/null 2>&1 || true
"$VM" snapshot restore "$SNAPSHOT"
"$VM" start
sleep 30

# shellcheck disable=SC2016 # runs in the VM
# The desktop session's XDG_DATA_DIRS (an ssh shell lacks snaps' and Flatpaks' app folders).
out=$("$VM" ssh "$SESSION"'export $(tr "\0" "\n" </proc/$(pgrep -u "$(id -u)" -x gnome-shell | head -1)/environ | grep ^XDG_DATA_DIRS=)
for t in "web page:x-scheme-handler/https" "mail link:x-scheme-handler/mailto" "PDF:application/pdf" \
	"document (odt):application/vnd.oasis.opendocument.text" "document (docx):application/vnd.openxmlformats-officedocument.wordprocessingml.document" \
	"photo (jpeg):image/jpeg" "music (mp3):audio/mpeg" "music (flac):audio/flac" "video (mp4):video/mp4"; do
	what=${t%%:*} mime=${t#*:}
	app=$(gio mime "$mime" 2>/dev/null | sed -n "s/^Default application for .*: //p")
	if [ -z "$app" ]; then echo "none|$what|nothing opens it"; continue; fi
	found=no
	for d in ~/.local/share/applications /usr/share/applications /var/lib/snapd/desktop/applications /var/lib/flatpak/exports/share/applications ~/.local/share/flatpak/exports/share/applications; do
		[ -f "$d/$app" ] && found=yes
	done
	[ $found = yes ] || app="$app (not installed)"
	echo "$found|$what|$app"
done
printers=$(lpstat -e 2>/dev/null | wc -l)
cups=$(systemctl is-active cups 2>/dev/null || true)
echo "info|printing|CUPS $cups, $printers printer(s) set up"')
"$VM" stop >/dev/null

failures=0
while IFS='|' read -r state what app; do
	case $state in
	yes) printf '  ok: %-16s %s\n' "$what" "$app" ;;
	info) printf '  %-20s %s\n' "$what:" "$app" ;;
	*)
		if [[ $what == "web page" || $what == PDF ]]; then
			printf '  FAIL: %-14s %s\n' "$what" "$app"
			failures=$((failures + 1))
		else
			printf '  missing: %-11s %s\n' "$what" "$app"
		fi
		;;
	esac
done <<<"$out"
echo
if ((failures == 0)); then echo PASS; else
	echo "$failures FAILED"
	exit 1
fi
