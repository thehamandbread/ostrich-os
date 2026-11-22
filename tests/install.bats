#!/usr/bin/env bats
# tests/install.bats: tests for the install.sh bootstrap.

setup() {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	INSTALL="$BATS_TEST_DIRNAME/../install.sh"
	export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
	export BUILD_DIR="$BATS_TEST_TMPDIR/no-build" # not the checkout's own (maybe partial) build
	export OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os-release"
	printf 'ID=ubuntu\nVERSION_ID="26.04"\n' >"$OS_RELEASE_FILE"
	# Nothing reaches the real desktop session: gsettings, dconf and xdg-mime write through it, not
	# through $HOME.
	local safe="$BATS_TEST_TMPDIR/safe-bin" c
	mkdir -p "$safe"
	for c in gsettings dconf xdg-mime; do
		printf '#!/usr/bin/env bash\necho "%s $*" >>"$BATS_TEST_TMPDIR/session-calls"\n' "$c" >"$safe/$c"
		chmod +x "$safe/$c"
	done
	export PATH="$safe:$PATH"
}

@test "--help prints usage and exits 0" {
	run "$INSTALL" --help
	[ "$status" -eq 0 ]
	[[ $output == *"Usage: install.sh"* ]]
}

@test "unknown option fails" {
	run "$INSTALL" --bogus
	[ "$status" -eq 1 ]
	[[ $output == *"Unknown option: --bogus"* ]]
}

@test "--dry-run succeeds on Ubuntu 26.04 and writes the log file" {
	run "$INSTALL" --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"dry-run=1"* ]]
	grep -q "OS check passed" "$XDG_STATE_HOME/ostrich-os/install.log"
}

@test "refuses to run on another OS" {
	printf 'ID=debian\nVERSION_ID="13"\n' >"$OS_RELEASE_FILE"
	run "$INSTALL" --dry-run
	[ "$status" -eq 1 ]
	[[ $output == *"supports Ubuntu 26.04 only"* ]]
}

@test "refuses to run on another Ubuntu release" {
	printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$OS_RELEASE_FILE"
	run "$INSTALL" --dry-run
	[ "$status" -eq 1 ]
}

@test "--force overrides the OS check with a warning" {
	printf 'ID=debian\nVERSION_ID="13"\n' >"$OS_RELEASE_FILE"
	run "$INSTALL" --dry-run --force
	[ "$status" -eq 0 ]
	[[ $output == *"[WARN] Unsupported OS"* ]]
}

@test "os-release variables do not leak into the installer" {
	printf 'ID=ubuntu\nVERSION_ID="26.04"\nDRY_RUN=0\n' >"$OS_RELEASE_FILE"
	run "$INSTALL" --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"Dry run:"* ]]
}

@test "--dry-run runs implemented modules and skips stubs" {
	run "$INSTALL" --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"module core: start (dry-run=1)"* ]]
	[[ $output == *"module terminal: start (dry-run=1)"* ]]
	[[ $output == *"module gnome: start (dry-run=1)"* ]]
	[[ $output == *"module dev: not implemented yet, skipping"* ]]
}

@test "piped run without a checkout fetches the repo first" {
	[[ -d $BATS_TEST_DIRNAME/../.git ]] && command -v git >/dev/null || skip "needs a git checkout"
	export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
	export REPO_URL="$BATS_TEST_DIRNAME/.." REPO_REF="$(git -C "$BATS_TEST_DIRNAME/.." branch --show-current)"
	run bash -c 'bash < "$0" -s -- --dry-run' "$INSTALL"
	[ "$status" -eq 0 ]
	[[ $output == *"Fetching"* ]]
	[ -f "$XDG_DATA_HOME/ostrich-os/src/lib/module.sh" ]
}

@test "--dry-run from wget asks for git and curl instead of installing them" {
	# Every command but git, curl and sudo, as on a fresh desktop (sudo would be a change).
	local bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"
	ln -s /usr/bin/* "$bin/"
	rm -f "$bin"/{git,curl,sudo}
	cp "$INSTALL" "$BATS_TEST_TMPDIR/install.sh" # no checkout around it: the piped case
	PATH="$bin" run bash "$BATS_TEST_TMPDIR/install.sh" --dry-run </dev/null
	[ "$status" -eq 0 ]
	[[ $output == *"sudo apt-get install git curl"* ]]
}

@test "run from an earlier name's source copy: copies itself to the new src and re-execs once, in the process that installs" {
	export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
	export INSTALL_STOP_AFTER=relocate
	old="$XDG_DATA_HOME/ubuntu-ostrich/src"
	mkdir -p "$old"
	cp -a "$BATS_TEST_DIRNAME/../install.sh" "$BATS_TEST_DIRNAME/../lib" "$BATS_TEST_DIRNAME/../VERSION" "$old/"
	run bash "$old/install.sh"
	[ "$status" -eq 0 ]
	[ "$(grep -c "continuing from" <<<"$output")" -eq 1 ]
	[ "$(grep -c "RELOCATE-DONE" <<<"$output")" -eq 1 ]
	new="$XDG_DATA_HOME/ostrich-os/src"
	[ -f "$new/install.sh" ]
	line=$(grep "RELOCATE-DONE" <<<"$output")
	[[ $line == *"script=$new/install.sh"* ]]
	# a plain process, not a command substitution: $$ and BASHPID agree
	pid=${line##*pid=}
	pid=${pid%% *}
	[[ $line == *"bashpid=$pid" ]]
	# run again, from the new path: no second re-exec
	run bash "$new/install.sh"
	[ "$status" -eq 0 ]
	[[ $output != *"continuing from"* ]]
	[ "$(grep -c "RELOCATE-DONE" <<<"$output")" -eq 1 ]
}
