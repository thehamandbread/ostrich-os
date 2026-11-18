#!/usr/bin/env bash
# tests/vm/replicate-current.sh: copy this machine's current GNOME setup into the test VM ("pre" state).
#
# Read-only on the host: it only reads dconf and the user extension directory.
# What it copies (into the VM only, never into the repo):
#   - every user-installed GNOME extension that is currently enabled
#   - extension settings and selected desktop/mutter/power gsettings
# What it skips: wallpaper, accounts, browser profiles, app data, snaps/flatpaks
# (they don't run at idle), autostart apps (they need personal accounts).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
PROJECT="ubuntu-ostrich"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
EXT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions"

# Whole subtrees copied with dconf dump.
DCONF_TREES=(
	/org/gnome/shell/extensions/blur-my-shell/
	/org/gnome/shell/extensions/vitals/
	/org/gnome/shell/extensions/space-bar/
	/org/gnome/shell/extensions/just-perfection/
	/org/gnome/shell/extensions/dash-to-dock/
	/org/gnome/shell/extensions/tiling-assistant/
)

# Single keys copied with dconf read.
DCONF_KEYS=(
	/org/gnome/shell/enabled-extensions
	/org/gnome/shell/disabled-extensions
	/org/gnome/desktop/interface/color-scheme
	/org/gnome/desktop/interface/gtk-theme
	/org/gnome/desktop/interface/icon-theme
	/org/gnome/desktop/interface/accent-color
	/org/gnome/desktop/interface/clock-format
	/org/gnome/desktop/interface/show-battery-percentage
	/org/gnome/desktop/notifications/show-banners
	/org/gnome/desktop/wm/preferences/num-workspaces
	/org/gnome/mutter/dynamic-workspaces
	/org/gnome/mutter/edge-tiling
	/org/gnome/desktop/peripherals/mouse/accel-profile
	/org/gnome/desktop/peripherals/mouse/speed
	/org/gnome/desktop/peripherals/touchpad/click-method
	/org/gnome/desktop/session/idle-delay
	/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type
	/org/gnome/settings-daemon/plugins/power/ambient-enabled
)

log() { printf '[replicate] %s\n' "$*" >&2; }

# Rewrites a `dconf dump <tree>` so it can be loaded at the root with `dconf load /`.
rebase_dump() {
	local tree=${1#/}
	tree=${tree%/}
	awk -v tree="$tree" '
		/^\[\/\]$/ { print "[" tree "]"; next }
		/^\[.*\]$/ { print "[" tree "/" substr($0, 2, length($0) - 2) "]"; next }
		{ print }
	'
}

build_settings() {
	local out=$1 tree key value
	: >"$out"
	for tree in "${DCONF_TREES[@]}"; do
		dconf dump "$tree" | rebase_dump "$tree" >>"$out"
		printf '\n' >>"$out"
	done
	for key in "${DCONF_KEYS[@]}"; do
		value=$(dconf read "$key")
		[[ -n $value ]] || continue
		printf '[%s]\n%s=%s\n\n' "$(dirname "${key#/}")" "$(basename "$key")" "$value" >>"$out"
	done
}

enabled_user_extensions() {
	local uuid
	gsettings get org.gnome.shell enabled-extensions | tr -d "[]' " | tr ',' '\n' |
		while read -r uuid; do
			[[ -n $uuid && -d $EXT_DIR/$uuid ]] && printf '%s\n' "$uuid"
		done
}

main() {
	local stage="$VM_DIR/replica"
	rm -rf "$stage"
	mkdir -p "$stage/extensions"

	build_settings "$stage/settings.ini"
	log "settings: $(grep -c '^\[' "$stage/settings.ini") sections"

	local -a exts
	mapfile -t exts < <(enabled_user_extensions)
	((${#exts[@]} > 0)) || log "no user extensions enabled"
	local uuid
	for uuid in "${exts[@]}"; do
		cp -r "$EXT_DIR/$uuid" "$stage/extensions/"
		log "extension: $uuid"
	done

	tar -C "$stage" -czf "$VM_DIR/replica.tar.gz" .
	"$VM" copy "$VM_DIR/replica.tar.gz" /tmp/replica.tar.gz

	# Vitals reads sensors through libgtop.
	"$VM" ssh 'bash -s' <<'EOF'
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gir1.2-gtop-2.0 >/dev/null
rm -rf /tmp/replica && mkdir -p /tmp/replica && tar -C /tmp/replica -xzf /tmp/replica.tar.gz
mkdir -p ~/.local/share/gnome-shell/extensions
cp -r /tmp/replica/extensions/. ~/.local/share/gnome-shell/extensions/
dconf load / </tmp/replica/settings.ini
rm -rf /tmp/replica /tmp/replica.tar.gz
EOF
	rm -rf "$stage" "$VM_DIR/replica.tar.gz"

	# GNOME on Wayland only loads new extensions at login.
	"$VM" stop
	"$VM" start
	sleep 20
	"$VM" ssh 'gnome-extensions list --enabled' | sed 's/^/[replicate] enabled in VM: /' >&2
	log "done; next: vm.sh stop && vm.sh snapshot save pre"
}

main "$@"
