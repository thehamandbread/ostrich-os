#!/usr/bin/env bash
# tests/vm/compare.sh: the same scenes with the original extensions and with ours, side by side.
#
#   compare.sh [--originals SNAPSHOT] [--ours SNAPSHOT] [--out DIR] [--dark] [--wallpaper FILE]
#              [--checkout] [--scheme ID]
#
# --checkout replaces our side's installed extensions with this checkout's (built first), to look
# at a change before a full install.
# --scheme ID applies a colour scheme on our side with `ostrich theme scheme apply ID` (the tool from
# build-tools.sh; implies --checkout, for extensions that load schemes). Compare it with --originals
# post-fresh, today's look.
# --dark puts both sides in the dark style first (without it, both get the default light style) (the original machine uses it), to compare like
# with like. --wallpaper sets the same picture on both (a path in the VM, e.g. one of Ubuntu's in
# /usr/share/backgrounds/): a busy photo shows how glassy the blur is, a plain one can't.
#
# The originals snapshot (default: pre, the replica of the original machine: Dash to Dock, Blur my
# Shell, Space Bar, Vitals...) and ours (default: post-fresh) each get the same scenes: the desktop
# with a window, the dock shown, the top bar over a window, the quick-settings menu, the overview,
# four named workspaces, the system monitor's popup (Vitals on the left), the clock menu and a
# notification banner. DIR gets one side-by-side image per scene (originals left, ours right)
# for review; nothing here passes or fails.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
PROJECT="ubuntu-ostrich"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
ORIGINALS=pre
OURS=post-fresh
OUT="$VM_DIR/compare"
DARK=0
WALLPAPER=
CHECKOUT=0
SCHEME=
while (($# > 0)); do
	case $1 in
	--originals) ORIGINALS=$2 && shift ;;
	--ours) OURS=$2 && shift ;;
	--out) OUT=$2 && shift ;;
	--dark) DARK=1 ;;
	--wallpaper) WALLPAPER=$2 && shift ;;
	--checkout) CHECKOUT=1 ;;
	--scheme) SCHEME=$2 CHECKOUT=1 && shift ;;
	*)
		echo "usage: compare.sh [--originals SNAPSHOT] [--ours SNAPSHOT] [--out DIR] [--dark] [--wallpaper FILE] [--checkout] [--scheme ID]" >&2
		exit 2
		;;
	esac
	shift
done
STYLE=default
((DARK)) && STYLE=prefer-dark
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0;'
run() { "$VM" ssh "$SESSION $*"; }

# Where each side's system monitor sits in the top bar (Vitals after the workspace numbers;
# ours after the named workspace pills).
MONITOR_X_ORIGINALS=${MONITOR_X_ORIGINALS:-180}
MONITOR_X_OURS=${MONITOR_X_OURS:-265}

scenes() { # snapshot side
	local dir="$OUT/$2" mx=$MONITOR_X_OURS
	[[ $2 == originals ]] && mx=$MONITOR_X_ORIGINALS
	mkdir -p "$dir"
	"$VM" stop
	"$VM" snapshot restore "$1"
	"$VM" start
	if ((CHECKOUT)) && [[ $2 == ours ]]; then
		local zip
		for zip in "$HERE/../../dist"/*@ubuntu-ostrich.shell-extension.zip; do
			"$VM" copy "$zip" /tmp/ext.zip
			"$VM" ssh "gnome-extensions install --force /tmp/ext.zip"
		done
		sleep 30 # past the start-up window in which a power-off can make GNOME switch extensions off
		"$VM" stop
		"$VM" start
	fi
	sleep 40
	if [[ -n $SCHEME && $2 == ours ]]; then
		# Applied live, as Ostrich Settings does: the extensions pick it up without a logout.
		"$VM" copy "$VM_DIR/tools-bin/ostrich-theme" /tmp/ostrich-theme
		run "gsettings set org.gnome.desktop.interface color-scheme $STYLE" # before: the icon theme follows it
		run "/tmp/ostrich-theme scheme apply $SCHEME" >&2
		sleep 3
	fi
	# Without --dark, light on both sides: the snapshots may have been saved in the dark style.
	run "gsettings set org.gnome.desktop.interface color-scheme $STYLE"
	sleep 3
	if [[ -n $WALLPAPER ]]; then
		run "for k in picture-uri picture-uri-dark; do gsettings set org.gnome.desktop.background \$k 'file://$WALLPAPER'; done"
		sleep 3
	fi
	# Four named workspaces, and a Files window on the first.
	run "gsettings set org.gnome.mutter dynamic-workspaces false; gsettings set org.gnome.desktop.wm.preferences num-workspaces 4; gsettings set org.gnome.desktop.wm.preferences workspace-names \"['mail', 'code', 'web', 'music']\""
	run "setsid -f gtk-launch org.gnome.Nautilus.desktop </dev/null >/dev/null 2>&1"
	sleep 5
	"$VM" screenshot "$dir/1-desktop.png" >/dev/null
	"$VM" move 960 1078
	"$VM" nudge 0 20 30
	sleep 1
	"$VM" screenshot "$dir/2-dock.png" >/dev/null
	"$VM" move 960 500
	sleep 1
	"$VM" click 1880 15
	sleep 1
	"$VM" screenshot "$dir/3-menu.png" >/dev/null
	"$VM" key esc
	sleep 1
	"$VM" key meta_l
	sleep 2
	"$VM" screenshot "$dir/4-overview.png" >/dev/null
	"$VM" key esc
	sleep 1
	"$VM" click "$mx" 15
	sleep 3 # a refresh or two, so rates and per-core values are in
	"$VM" screenshot "$dir/5-monitor.png" >/dev/null
	"$VM" key esc
	sleep 1
	"$VM" click 960 15
	sleep 2
	"$VM" screenshot "$dir/6-clock.png" >/dev/null
	"$VM" key esc
	sleep 1
	run "notify-send 'A notification' 'Banners are frosted glass too, like the menus'"
	sleep 2
	"$VM" screenshot "$dir/7-notification.png" >/dev/null
	sleep 6
}

rm -rf "$OUT"
mkdir -p "$OUT"
((CHECKOUT)) && "$HERE/../../modules/gnome/extensions/build.sh" >&2
[[ -z $SCHEME || -x $VM_DIR/tools-bin/ostrich-theme ]] || {
	echo "compare.sh: no ostrich-theme in $VM_DIR/tools-bin (run build-tools.sh)" >&2
	exit 2
}
scenes "$ORIGINALS" originals
scenes "$OURS" ours
"$VM" stop
python3 -I - "$OUT" <<'EOF'
import os, sys
from PIL import Image
out = sys.argv[1]
for name in sorted(os.listdir(os.path.join(out, "originals"))):
    a = Image.open(os.path.join(out, "originals", name))
    b = Image.open(os.path.join(out, "ours", name))
    side = Image.new("RGB", (a.width + b.width + 16, max(a.height, b.height)), "white")
    side.paste(a, (0, 0))
    side.paste(b, (a.width + 16, 0))
    side.save(os.path.join(out, f"side-{name}"))
    print("wrote", os.path.join(out, f"side-{name}"))
EOF
