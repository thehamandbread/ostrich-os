#!/usr/bin/env bats
# tests/migrate.bats: lib/migrate.sh on fake HOMEs (tests/fixtures/migrate). dconf runs on a private
# session bus per call (dbus-run-session), against a dconf database inside the fake HOME, so
# neither the real settings nor the real home are ever touched.

FX="$BATS_TEST_DIRNAME/fixtures/migrate"
LIB="$BATS_TEST_DIRNAME/../lib/migrate.sh"

# sess <script>: run it on a private session bus with lib/migrate.sh sourced.
sess() { dbus-run-session -- bash -c 'source "$1"; shift; eval "$*"' _ "$LIB" "$@"; }

# fixture <name>: HOME from tests/fixtures/migrate/<name>/home, dconf from its dconf-*.ini.
fixture() {
	cp -a "$FX/$1/home/." "$HOME/"
	local f
	for f in "$FX/$1"/dconf-*.ini; do
		[[ -e $f ]] || continue
		sess "dconf load / <'$f'"
	done
}

dconf_get() { sess "dconf read '$1'"; }
snapshot() {
	# dconf's own runtime cache (~/.cache/dconf) appears on first use and is not ours
	(cd "$HOME" && find . -path ./.cache -prune -o -type f -exec sha256sum {} + | sort && find . -path ./.cache -prune -o -type d -print | sort)
	sess 'dconf dump /'
}

setup() {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	[[ $HOME == "$BATS_TEST_TMPDIR"/* ]] || exit 1 # never the real home
	unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME DCONF_PROFILE
	export LOG_FILE="$BATS_TEST_TMPDIR/log/install.log"
	export DRY_RUN=0 SUDO="" MIGRATE_ROOT="$BATS_TEST_TMPDIR/root"
	# The real machine may have a drawer running: a fake pgrep says there is none.
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/pgrep"
	chmod +x "$BATS_TEST_TMPDIR/bin/pgrep"
	export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "map_id: old ids (dash, underscore, any slug) map to ostrich_os, others don't" {
	run sess 'migrate_map_id ubuntu_ostrich.drawer.chat.desktop; migrate_map_id ostrich-ubuntu.store.desktop; migrate_map_id cleanest_ubuntu_setup.setup; migrate_map_id ubuntu_ostrich.drawer'
	[ "$output" = $'ostrich_os.drawer.chat.desktop\nostrich_os.store.desktop\nostrich_os.setup\nostrich_os.drawer' ]
	run sess 'migrate_map_id org.gnome.Nautilus.desktop'
	[ "$status" -eq 1 ]
	run sess 'migrate_map_id ostrich_os.drawer.desktop'
	[ "$status" -eq 1 ]
}

@test "child_name: .desktop dropped, dots and underscores become dashes (the verified rule)" {
	run sess 'migrate_child_name ubuntu_ostrich.drawer.chat.desktop; migrate_child_name ostrich_os.drawer.google-chat.desktop'
	[ "$output" = $'ubuntu-ostrich-drawer-chat\nostrich-os-drawer-google-chat' ]
}

# check_migrated <fixture> <slug>: everything one old install must end up as.
check_migrated() {
	local fx=$1 s=$2 old="$FX/$1/home/.local/share/$2/drawer/chat/data"
	[ ! -e "$HOME/.config/$s" ]
	[ ! -e "$HOME/.local/share/$s" ]
	[ ! -e "$HOME/.local/state/$s" ]
	[ ! -e "$HOME/.local/libexec/$s" ]
	grep -q "from $s" "$HOME/.config/ostrich-os/drawer.toml"
	[ -f "$HOME/.config/ostrich-os/schemes/mine.json" ]
	cmp "$HOME/.local/share/ostrich-os/drawer/chat/data/cookies.sqlite" "$old/cookies.sqlite"
	cmp "$HOME/.local/share/ostrich-os/drawer/chat/data/cookies.sqlite-wal" "$old/cookies.sqlite-wal"
	grep -q "log from $s" "$HOME/.local/state/ostrich-os/install.log"
	[ -f "$HOME/.local/state/ostrich-os/restore/original/version" ]
	[ -f "$HOME/.local/libexec/ostrich-os/ostrich-drawer" ]
	# dconf copied; the old path is empty; the dock's prefix list follows the id
	[ "$(dconf_get /org/gnome/shell/extensions/ostrich-os/dock/icon-size)" = "40" ]
	[ "$(dconf_get /org/gnome/shell/extensions/ostrich-os/dock/hidden-app-prefixes)" = "['ostrich_os.drawer']" ]
	[ -z "$(dconf_get "/org/gnome/shell/extensions/$s/dock/icon-size")" ]
	# extension lists: renamed in place, a disabled one stays disabled
	[ "$(dconf_get /org/gnome/shell/enabled-extensions)" = "['plain@example.com', 'dock@ostrich-os', 'tiling@ostrich-os']" ]
	[ "$(dconf_get /org/gnome/shell/disabled-extensions)" = "['monitor@ostrich-os']" ]
	[ "$(dconf_get /org/gnome/shell/favorite-apps)" = "['org.gnome.Nautilus.desktop', 'ostrich_os.drawer.desktop', 'firefox.desktop']" ]
	# per-site notification settings followed the id, every key
	[ "$(dconf_get /org/gnome/desktop/notifications/application-children)" = "['update-manager', 'ostrich-os-drawer-chat']" ]
	run sess 'dconf dump /org/gnome/desktop/notifications/application/ostrich-os-drawer-chat/'
	[[ $output == *"application-id='ostrich_os.drawer.chat.desktop'"* ]]
	[[ $output == *"enable=false"* && $output == *"show-banners=false"* && $output == *"enable-sound-alerts=false"* ]]
	[ -z "$(dconf_get "/org/gnome/desktop/notifications/application/$s-drawer-chat/application-id")" ]
}

@test "an install under cleanest-ubuntu-setup migrates" {
	fixture old-cleanest
	run sess migrate_run
	[ "$status" -eq 0 ]
	check_migrated old-cleanest cleanest-ubuntu-setup
}

@test "an install under ostrich-ubuntu migrates" {
	fixture old-ostrich-ubuntu
	run sess migrate_run
	[ "$status" -eq 0 ]
	check_migrated old-ostrich-ubuntu ostrich-ubuntu
}

@test "an install under ubuntu-ostrich migrates" {
	fixture old-ubuntu-ostrich
	run sess migrate_run
	[ "$status" -eq 0 ]
	check_migrated old-ubuntu-ostrich ubuntu-ostrich
}

@test "log out message when the extension lists changed; the marker records where from" {
	fixture old-ubuntu-ostrich
	run sess migrate_run
	[[ $output == *"log out and back in to finish"* ]]
	grep -qx 'from_slugs=ubuntu-ostrich' "$HOME/.local/state/ostrich-os/migrated-from"
	grep -qx 'from_version=0.4.0' "$HOME/.local/state/ostrich-os/migrated-from"
}

@test "running twice changes nothing the second time" {
	fixture old-ubuntu-ostrich
	run sess migrate_run
	[ "$status" -eq 0 ]
	before=$(snapshot)
	run sess migrate_run
	[ "$status" -eq 0 ]
	[[ $output == *"0 change(s)"* ]]
	[[ $output != *"log out and back in"* ]]
	[ "$before" = "$(snapshot)" ]
}

@test "an already migrated home is left alone and gets no marker" {
	fixture migrated
	before=$(snapshot)
	run sess migrate_run
	[ "$status" -eq 0 ]
	[[ $output == *"0 change(s)"* ]]
	[ "$before" = "$(snapshot)" ]
	[ ! -e "$HOME/.local/state/ostrich-os/migrated-from" ]
}

@test "--dry-run prints every action and changes nothing" {
	fixture old-ubuntu-ostrich
	before=$(snapshot)
	run sess 'DRY_RUN=1 migrate_run'
	[ "$status" -eq 0 ]
	[[ $output == *"[WOULD] migrate: move"*".config/ubuntu-ostrich"* ]]
	[[ $output == *"[WOULD] migrate: dconf /org/gnome/shell/extensions/ubuntu-ostrich/"* ]]
	[[ $output == *"[WOULD] migrate: /org/gnome/shell/favorite-apps"* ]]
	[[ $output == *"[WOULD] migrate: notification settings ubuntu-ostrich-drawer-chat -> ostrich-os-drawer-chat"* ]]
	[ "$before" = "$(snapshot)" ]
}

@test "the standalone script takes --dry-run and --verbose" {
	fixture old-ubuntu-ostrich
	before=$(snapshot)
	run dbus-run-session -- "$BATS_TEST_DIRNAME/../lib/migrate.sh" --dry-run --verbose
	[ "$status" -eq 0 ]
	[[ $output == *"[WOULD]"* ]]
	[ "$before" = "$(snapshot)" ]
}

@test "a disabled extension is never enabled, even when its old name was enabled" {
	fixture old-ubuntu-ostrich
	sess "dconf write /org/gnome/shell/enabled-extensions \"['dock@ubuntu-ostrich', 'monitor@ubuntu-ostrich']\""
	sess "dconf write /org/gnome/shell/disabled-extensions \"['monitor@ubuntu-ostrich']\""
	run sess migrate_run
	[ "$(dconf_get /org/gnome/shell/enabled-extensions)" = "['dock@ostrich-os']" ]
	[ "$(dconf_get /org/gnome/shell/disabled-extensions)" = "['monitor@ostrich-os']" ]
}

@test "favorite-apps keeps its order and other entries" {
	fixture old-ubuntu-ostrich
	sess "dconf write /org/gnome/shell/favorite-apps \"['a.desktop', 'ubuntu_ostrich.store.desktop', 'b.desktop', 'ubuntu_ostrich.drawer.desktop', 'ubuntu_ostrich.setup.desktop']\""
	run sess migrate_run
	[ "$(dconf_get /org/gnome/shell/favorite-apps)" = "['a.desktop', 'ostrich_os.store.desktop', 'b.desktop', 'ostrich_os.drawer.desktop', 'ostrich_os.setup.desktop']" ]
}

@test "an old extension folder goes only when the new one is installed" {
	fixture old-ubuntu-ostrich
	e="$HOME/.local/share/gnome-shell/extensions"
	mkdir -p "$e/tiling@ubuntu-ostrich" "$e/tiling@ostrich-os"
	run sess migrate_run
	[ ! -e "$e/tiling@ubuntu-ostrich" ]
	[ -d "$e/dock@ubuntu-ostrich" ] # no dock@ostrich-os yet: the installer hasn't put it there
}

@test "cookies.sqlite is byte-identical after the move" {
	fixture old-ubuntu-ostrich
	sha=$(sha256sum <"$HOME/.local/share/ubuntu-ostrich/drawer/chat/data/cookies.sqlite")
	run sess migrate_run
	[ "$sha" = "$(sha256sum <"$HOME/.local/share/ostrich-os/drawer/chat/data/cookies.sqlite")" ]
}

@test "two slugs: the newest wins, the older adds what is missing" {
	fixture mixed
	run sess migrate_run
	[ "$status" -eq 0 ]
	cmp "$HOME/.local/share/ostrich-os/drawer/chat/data/cookies.sqlite" "$FX/mixed/home/.local/share/ubuntu-ostrich/drawer/chat/data/cookies.sqlite"
	cmp "$HOME/.local/share/ostrich-os/drawer/mail/data/cookies.sqlite" "$FX/mixed/home/.local/share/ostrich-ubuntu/drawer/mail/data/cookies.sqlite"
	[ -f "$HOME/.config/ostrich-os/older-only.txt" ]
	grep -q "from ubuntu-ostrich" "$HOME/.config/ostrich-os/drawer.toml"
	# drawer.toml differed: the older copy stays where it was, and is logged
	grep -q "from ostrich-ubuntu" "$HOME/.config/ostrich-ubuntu/drawer.toml"
	[[ $output == *"conflict"* ]]
	# one site, two old children: the newer install's wins; the new list names it once
	[ "$(dconf_get /org/gnome/desktop/notifications/application-children)" = "['update-manager', 'ostrich-ubuntu-drawer-chat', 'ostrich-os-drawer-chat']" ]
}

@test "a conflict keeps the old directory and says so" {
	fixture conflict
	run sess migrate_run
	[ "$status" -eq 0 ]
	[[ $output == *"conflict"*"cookies.sqlite"* || $output == *"conflict"*"drawer/chat"* ]]
	# the site that exists in both stays in the old tree, untouched; the new one is untouched
	cmp "$HOME/.local/share/ubuntu-ostrich/drawer/chat/data/cookies.sqlite" "$FX/conflict/home/.local/share/ubuntu-ostrich/drawer/chat/data/cookies.sqlite"
	cmp "$HOME/.local/share/ostrich-os/drawer/chat/data/cookies.sqlite" "$FX/conflict/home/.local/share/ostrich-os/drawer/chat/data/cookies.sqlite"
	grep -q "muted = \[\]  # new" "$HOME/.config/ostrich-os/drawer.toml"
	grep -q "from ubuntu-ostrich" "$HOME/.config/ubuntu-ostrich/drawer.toml"
	# the parts that did not conflict still moved
	[ -f "$HOME/.config/ostrich-os/schemes/mine.json" ]
}

@test "the drawer running: its data stays, the rest moves" {
	fixture old-ubuntu-ostrich
	printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/pgrep"
	run sess migrate_run
	[ "$status" -eq 0 ]
	[[ $output == *"the drawer is running"* ]]
	[ -f "$HOME/.local/share/ubuntu-ostrich/drawer/chat/data/cookies.sqlite" ]
	[ -f "$HOME/.config/ostrich-os/drawer.toml" ]
}

@test "the log file follows the state directory" {
	fixture old-ubuntu-ostrich
	run sess "LOG_FILE=\$HOME/.local/state/ubuntu-ostrich/install.log; log_init; migrate_run; echo LOG=\$LOG_FILE; info after"
	[[ $output == *"LOG=$HOME/.local/state/ostrich-os/install.log"* ]]
	grep -q "after" "$HOME/.local/state/ostrich-os/install.log"
	[ ! -e "$HOME/.local/state/ubuntu-ostrich" ]
}

# --- root items: a fake root under $MIGRATE_ROOT and a fake systemctl/udevadm on PATH ---

root_fixture() {
	local r=$MIGRATE_ROOT s=ubuntu-ostrich bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$r/usr/libexec/$s" "$r/usr/libexec/ostrich-os" "$r/usr/share/polkit-1/actions" "$r/etc/systemd/system" "$r/etc/udev/rules.d" "$r/var/lib/$s" "$bin"
	echo old >"$r/usr/libexec/$s/system-helper"
	echo new >"$r/usr/libexec/ostrich-os/system-helper"
	echo old >"$r/usr/share/polkit-1/actions/org.$s.system-helper.policy"
	echo old >"$r/etc/systemd/system/$s-power.service"
	echo new >"$r/etc/systemd/system/ostrich-os-power.service"
	echo old >"$r/etc/udev/rules.d/90-$s-touchscreen.rules"
	echo new >"$r/etc/udev/rules.d/90-ostrich-os-touchscreen.rules"
	echo on >"$r/var/lib/$s/touchscreen.state"
	printf '#!/bin/sh\necho "systemctl $*" >>"%s/calls"\n' "$BATS_TEST_TMPDIR" >"$bin/systemctl"
	printf '#!/bin/sh\necho "udevadm $*" >>"%s/calls"\n' "$BATS_TEST_TMPDIR" >"$bin/udevadm"
	chmod +x "$bin/systemctl" "$bin/udevadm"
	export PATH="$bin:$PATH"
}

@test "root: an old file goes only once the new one is in place; state data moves" {
	root_fixture
	r=$MIGRATE_ROOT
	run sess migrate_root
	[ "$status" -eq 0 ]
	[ ! -e "$r/usr/libexec/ubuntu-ostrich" ]
	[ -f "$r/usr/libexec/ostrich-os/system-helper" ]
	[ ! -e "$r/etc/systemd/system/ubuntu-ostrich-power.service" ]
	[ ! -e "$r/etc/udev/rules.d/90-ubuntu-ostrich-touchscreen.rules" ]
	# the new polkit policy was not installed, so the old one stays
	[ -f "$r/usr/share/polkit-1/actions/org.ubuntu-ostrich.system-helper.policy" ]
	[ "$(cat "$r/var/lib/ostrich-os/touchscreen.state")" = on ]
	[ ! -e "$r/var/lib/ubuntu-ostrich" ]
	grep -q "systemctl disable ubuntu-ostrich-power.service" "$BATS_TEST_TMPDIR/calls"
	grep -q "systemctl daemon-reload" "$BATS_TEST_TMPDIR/calls"
	grep -q "udevadm control --reload" "$BATS_TEST_TMPDIR/calls"
}

@test "root: --dry-run changes nothing, and twice is a no-op" {
	root_fixture
	before=$(find "$MIGRATE_ROOT" | sort)
	run sess 'DRY_RUN=1 migrate_root'
	[[ $output == *"[WOULD] migrate: remove"* ]]
	[ "$before" = "$(find "$MIGRATE_ROOT" | sort)" ]
	[ ! -e "$BATS_TEST_TMPDIR/calls" ]
	sess migrate_root
	after=$(find "$MIGRATE_ROOT" | sort)
	: >"$BATS_TEST_TMPDIR/calls"
	run sess migrate_root
	[ "$after" = "$(find "$MIGRATE_ROOT" | sort)" ]
	[ ! -s "$BATS_TEST_TMPDIR/calls" ]
}
