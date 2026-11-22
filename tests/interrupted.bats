#!/usr/bin/env bats
# tests/interrupted.bats: an upgrade from an earlier name that stops half way (the tools step
# fails: a 404 for the release) must leave a consistent state, and running it again must end
# exactly where one uninterrupted run ends. A third run changes nothing.
#
# The installer is the real install.sh over a copy of the repo whose modules are stubs: `tools`
# writes the new launcher and extension the way the real one does, and fails while $STUB_FAIL
# exists. dconf runs on a private session bus against a database inside the fake HOME.

FX="$BATS_TEST_DIRNAME/fixtures/migrate"
OLD=ubuntu-ostrich
OLD_ID=ubuntu_ostrich
NOTE=/org/gnome/desktop/notifications/application

# mkhome <dir>: a fake HOME holding the old install, plus its old launchers.
mkhome() {
	export HOME=$1
	mkdir -p "$HOME"
	[[ $HOME == "$BATS_TEST_TMPDIR"/* ]] || exit 1 # never the real home
	cp -a "$FX/old-ubuntu-ostrich/home/." "$HOME/"
	mkdir -p "$HOME/.local/share/applications" "$HOME/.config/autostart"
	printf '[Desktop Entry]\nName=Chat\nExec=%s/.local/libexec/%s/ostrich-drawer --site chat\n' "$HOME" "$OLD" \
		>"$HOME/.local/share/applications/$OLD_ID.drawer.chat.desktop"
	cp "$HOME/.local/share/applications/$OLD_ID.drawer.chat.desktop" "$HOME/.config/autostart/$OLD_ID.drawer.desktop"
	local f
	for f in "$FX"/old-ubuntu-ostrich/dconf-*.ini; do
		sess "dconf load / <'$f'"
	done
}

sess() { dbus-run-session -- bash -c "$@"; }

# run_install: the installer, from the copy of the repo, on a private bus.
run_install() { dbus-run-session -- bash "$REPO/install.sh" </dev/null; }

# state: everything the upgrade decides, minus what differs per run (times, log text).
state() {
	(
		cd "$HOME" || exit 1
		find . -path ./.cache -prune -o \( -name install.log -o -name date -o -name migrated-from \) -prune -o -type f -exec sha256sum {} + | sort
		find . -path ./.cache -prune -o -type d -print | sort
	)
	dbus-run-session -- dconf dump /
}

setup() {
	unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME DCONF_PROFILE LOG_FILE STATE_DIR
	export SUDO="" DRY_RUN=0 BUILD_DIR="$BATS_TEST_TMPDIR/no-build"
	export OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os-release"
	printf 'ID=ubuntu\nVERSION_ID="26.04"\n' >"$OS_RELEASE_FILE"
	export STUB_FAIL="$BATS_TEST_TMPDIR/fail-tools"
	export MIGRATE_ROOT="$BATS_TEST_TMPDIR/root"
	REPO="$BATS_TEST_TMPDIR/repo"
	export REPO
	mkdir -p "$REPO/modules/tools"
	cp -a "$BATS_TEST_DIRNAME/../install.sh" "$BATS_TEST_DIRNAME/../lib" "$BATS_TEST_DIRNAME/../VERSION" "$REPO/"
	cat >"$REPO/modules/tools/install.sh" <<'STUB'
#!/usr/bin/env bash
if [[ -e $STUB_FAIL ]]; then echo "tools: HTTP 404 (release not found)" >&2; exit 1; fi
d=${XDG_DATA_HOME:-$HOME/.local/share}
mkdir -p "$d/applications" "$d/gnome-shell/extensions/dock@ostrich-os"
printf '[Desktop Entry]\nName=Chat\nExec=ostrich-drawer --site chat\n' >"$d/applications/ostrich_os.drawer.chat.desktop"
printf '{}\n' >"$d/gnome-shell/extensions/dock@ostrich-os/metadata.json"
exit 0
module_init
STUB
	# Nothing else may reach the real session or the network.
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	local c
	for c in gsettings xdg-mime update-desktop-database; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/$c"
		chmod +x "$BATS_TEST_TMPDIR/bin/$c"
	done
	export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "a failed tools step leaves a consistent state; the re-run ends where an uninterrupted run does; a third run changes nothing" {
	# the reference: one uninterrupted run, in its own home
	mkhome "$BATS_TEST_TMPDIR/clean"
	run run_install
	[ "$status" -eq 0 ]
	state >"$BATS_TEST_TMPDIR/clean.state"
	cp "$HOME/.local/state/ostrich-os/install.log" "$BATS_TEST_TMPDIR/clean.log"

	# the interrupted one
	mkhome "$BATS_TEST_TMPDIR/hurt"
	touch "$STUB_FAIL"
	run run_install
	[ "$status" -ne 0 ]
	[[ $output == *"module tools failed"* ]]
	# consistent: data moved whole, nothing half-moved, nothing of the old tree split in two
	[ ! -e "$HOME/.local/share/$OLD/drawer" ]
	cmp "$HOME/.local/share/ostrich-os/drawer/chat/data/cookies.sqlite" "$FX/old-ubuntu-ostrich/home/.local/share/$OLD/drawer/chat/data/cookies.sqlite"
	[ ! -e "$HOME/.local/state/$OLD" ]
	[ -f "$HOME/.local/state/ostrich-os/restore/original/version" ]
	# their removal comes after the failed step: old children and launchers are still there
	[ -f "$HOME/.local/share/applications/$OLD_ID.drawer.chat.desktop" ]
	[ -f "$HOME/.config/autostart/$OLD_ID.drawer.desktop" ]
	run sess "dconf read /org/gnome/desktop/notifications/application-children"
	[[ $output == *"$OLD-drawer-chat"* ]]
	[ ! -e "$HOME/.local/share/applications/ostrich_os.drawer.chat.desktop" ]

	# re-run with tools working
	rm "$STUB_FAIL"
	run run_install
	[ "$status" -eq 0 ]
	state >"$BATS_TEST_TMPDIR/hurt.state"
	# the same final state as the uninterrupted run (the homes differ only in their path)
	diff <(sed "s|$BATS_TEST_TMPDIR/clean||g" "$BATS_TEST_TMPDIR/clean.state") <(sed "s|$BATS_TEST_TMPDIR/hurt||g" "$BATS_TEST_TMPDIR/hurt.state")
	[ ! -e "$HOME/.local/share/applications/$OLD_ID.drawer.chat.desktop" ]
	[ ! -e "$HOME/.config/autostart/$OLD_ID.drawer.desktop" ]
	run sess "dconf read /org/gnome/desktop/notifications/application-children"
	[ "$output" = "['update-manager', 'ostrich-os-drawer-chat']" ]
	run sess "dconf read $NOTE/ostrich-os-drawer-chat/application-id"
	[ "$output" = "'ostrich_os.drawer.chat.desktop'" ]
	[ -f "$HOME/.local/state/ostrich-os/migrated-from" ]
	# one restore point; one joined log that still holds both histories
	[ "$(find "$HOME/.local/state/ostrich-os/restore" -name dconf.ini | wc -l)" -eq 1 ]
	[ "$(find "$HOME/.local/state" -name 'install.log*' | wc -l)" -eq 1 ]
	grep -q "log from $OLD" "$HOME/.local/state/ostrich-os/install.log"
	grep -q "module tools failed" "$HOME/.local/state/ostrich-os/install.log"

	# a third run: nothing changes
	run run_install
	[ "$status" -eq 0 ]
	state >"$BATS_TEST_TMPDIR/third.state"
	diff "$BATS_TEST_TMPDIR/hurt.state" "$BATS_TEST_TMPDIR/third.state"
}
