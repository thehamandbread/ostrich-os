#!/usr/bin/env bats
# tests/appid-lint.bats: tests/appid-lint.sh passes on the tree, and fails on each planted violation.

setup() {
	ROOT="$BATS_TEST_DIRNAME/.."
	LINT="$ROOT/tests/appid-lint.sh"
	REPO="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$REPO/tools/t/src" "$REPO/modules/x"
}

@test "the tree passes, with no exemptions" {
	run "$LINT" "$ROOT"
	[ "$status" -eq 0 ]
	[ "$output" = "appid-lint: ok" ]
}

@test "an underscore form and a dash in the last part pass" {
	echo 'const APP_ID: &str = "ostrich_os.drawer.google-chat";' >"$REPO/tools/t/src/main.rs"
	touch "$REPO/modules/x/ostrich_os.drawer.google-chat.desktop"
	run "$LINT" "$REPO"
	[ "$status" -eq 0 ]
}

@test "a Rust application id with a dash before the last part fails" {
	echo 'fn f() { Application::builder().application_id("ostrich-os.thing").build(); }' >"$REPO/tools/t/src/main.rs"
	run "$LINT" "$REPO"
	[ "$status" -eq 1 ]
	[[ $output == *"ostrich-os.thing"* ]]
}

@test "a Rust APP_ID constant fails" {
	echo 'const APP_ID: &str = "a-b.c.d";' >"$REPO/tools/t/src/main.rs"
	run "$LINT" "$REPO"
	[ "$status" -eq 1 ]
}

@test "a JS app id, prefix or bus name fails" {
	echo "const DRAWER_APP = 'ostrich-os.drawer';" >"$REPO/modules/x/e.js"
	run "$LINT" "$REPO"
	[ "$status" -eq 1 ]
	echo "const DRAWER_APP = 'ostrich_os.drawer';" >"$REPO/modules/x/e.js"
	echo "const BUS_NAME = 'org.ostrich-os.Thing';" >>"$REPO/modules/x/e.js"
	run "$LINT" "$REPO"
	[ "$status" -eq 1 ]
}

@test "a .desktop file name, or one written in a script, fails" {
	touch "$REPO/modules/x/ostrich-os.store.desktop"
	run "$LINT" "$REPO"
	[ "$status" -eq 1 ]
	rm "$REPO/modules/x/ostrich-os.store.desktop"
	echo 'install -m 644 a "$APPS/ostrich-os.setup.desktop"' >"$REPO/modules/x/install.sh"
	run "$LINT" "$REPO"
	[ "$status" -eq 1 ]
}

@test "a polkit action id is not an app id" {
	echo 'ACTION=org.ostrich-os.system-helper.power' >"$REPO/modules/x/install.sh"
	run "$LINT" "$REPO"
	[ "$status" -eq 0 ]
}
