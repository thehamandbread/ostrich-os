#!/usr/bin/env bats
# tests/token-lint.bats: the look's lint (.claude/skills/ostrich-design/scripts/token-lint.sh,
# council 2026-11-05 M7): the tree passes it, and each rule fails on a planted violation.

setup() {
	ROOT="$BATS_TEST_DIRNAME/.."
	LINT="$ROOT/.claude/skills/ostrich-design/scripts/token-lint.sh"
	# A tiny repo: the real tokens, one extension stylesheet, one Rust file.
	REPO="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$REPO/tools/icons" "$REPO/tools/t/src" "$REPO/modules/gnome/extensions/x"
	cp "$ROOT/tools/icons/tokens.toml" "$REPO/tools/icons/"
	CSS="$REPO/modules/gnome/extensions/x/stylesheet.css.in"
	printf '%s\n' '.ost-x-button { padding: [[space_s]]; color: {{text}}; }' '.ost-x-button:focus { box-shadow: inset 0 0 0 2px {{text}}; }' >"$CSS"
	echo 'fn main() {}' >"$REPO/tools/t/src/main.rs"
}

@test "the tree passes" {
	run "$LINT" "$ROOT"
	[ "$status" -eq 0 ]
}

@test "a clean stylesheet passes" {
	run "$LINT" "$REPO"
	[ "$status" -eq 0 ]
}

@test "a padding that equals a space token fails, in a .css too" {
	echo '.ost-x-card { padding: 6px; }' >>"$CSS"
	run "$LINT" "$REPO"
	[ "$status" -eq 1 ]
	[[ $output == *"padding: 6px"* ]]
	mv "$CSS" "${CSS%.in}"
	run "$LINT" "$REPO"
	[ "$status" -eq 1 ]
}

@test "a radius that equals a radius token fails; one that doesn't is fine" {
	echo '.ost-x-card { border-radius: 6px; }' >>"$CSS"
	run "$LINT" "$REPO"
	[ "$status" -eq 0 ]
	echo '.ost-x-card { border-radius: 16px; }' >>"$CSS"
	run "$LINT" "$REPO"
	[ "$status" -eq 1 ]
}

@test "min-height equal to target_min fails" {
	echo '.ost-x-card { min-height: 24px; }' >>"$CSS"
	run "$LINT" "$REPO"
	[ "$status" -eq 1 ]
}

@test "a fixed hex colour fails; a translucent neutral does not" {
	echo '.ost-x-card { background-color: rgba(127, 127, 127, 0.1); }' >>"$CSS"
	run "$LINT" "$REPO"
	[ "$status" -eq 0 ]
	echo '.ost-x-card { color: #c01c28; }' >>"$CSS"
	run "$LINT" "$REPO"
	[ "$status" -eq 1 ]
	[[ $output == *"#c01c28"* ]]
}

@test "an allow comment or an off/on block exempts, a comment alone does not" {
	echo '.ost-x-card { color: #c01c28; } /* token-lint: allow the one red */' >>"$CSS"
	run "$LINT" "$REPO"
	[ "$status" -eq 0 ]
	printf '%s\n' '/* token-lint: off a fixed card */' '.ost-x-card { padding: 6px; color: #fff; }' '/* token-lint: on */' >>"$CSS"
	run "$LINT" "$REPO"
	[ "$status" -eq 0 ]
	echo '/* padding: 6px; color: #fff; only in a comment */' >>"$CSS"
	run "$LINT" "$REPO"
	[ "$status" -eq 0 ]
}

@test "a button class with no :focus rule fails; a row of buttons is not a button" {
	echo '.ost-x-buttons { padding: [[space_s]]; }' >>"$CSS"
	run "$LINT" "$REPO"
	[ "$status" -eq 0 ]
	echo '.ost-y-button { padding: [[space_s]]; }' >>"$CSS"
	run "$LINT" "$REPO"
	[ "$status" -eq 1 ]
	[[ $output == *".ost-y-button has no :focus rule"* ]]
}

@test "dim-label in Rust fails" {
	echo 'fn f() { w.add_css_class("dim-label"); }' >>"$REPO/tools/t/src/main.rs"
	run "$LINT" "$REPO"
	[ "$status" -eq 1 ]
	[[ $output == *"use dimmed"* ]]
}
