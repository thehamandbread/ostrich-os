#!/usr/bin/env bats
# tests/icons.bats: our app icons (tools/icons/, docs/council/2026-10-24-round-2-and-whole-os.md M2).

setup() {
	ROOT="$BATS_TEST_DIRNAME/.."
}

@test "the committed icons are what tools/icons/export.sh makes" {
	run "$ROOT/tools/icons/export.sh" --check
	[ "$status" -eq 0 ]
}

@test "every icon has its 16 px symbolic" {
	for f in "$ROOT"/modules/tools/icons/ostrich-*.svg; do
		[[ $f == *-symbolic.svg ]] && continue
		[ -f "${f%.svg}-symbolic.svg" ]
	done
}

# Icon= names in the desktop entries we write: ours must have a file; others must be on this list
# of names every Ubuntu 26.04 icon theme has. ({icon} is the drawer's per-site favicon path; {} is a
# GitHub app's own icon file, or application-x-executable.)
@test "every Icon= we ship resolves" {
	allowed="application-x-executable {icon} {}"
	names=$(grep -rhoE 'Icon=[^\\"[:space:]]+' "$ROOT/modules" "$ROOT/tools"/*/src | sed 's/^Icon=//' | sort -u)
	[ -n "$names" ]
	for n in $names; do
		[[ $n == /* ]] && continue # a file's path (a test's fake app icon)
		if [[ $n == ostrich-* ]]; then
			[ -f "$ROOT/modules/tools/icons/$n.svg" ] || {
				echo "Icon=$n has no modules/tools/icons/$n.svg"
				return 1
			}
		else
			[[ " $allowed " == *" $n "* ]] || {
				echo "Icon=$n is neither ours nor on the allowed list"
				return 1
			}
		fi
	done
}

@test "both sets exist, with the same names, and the light one has the rim" {
	for f in "$ROOT"/modules/tools/icons/ostrich-*.svg; do
		[ -f "$ROOT/modules/tools/icons-light/$(basename "$f")" ]
	done
	! grep -l '{{\|@NAME@' "$ROOT"/modules/tools/icons*/*.svg
	grep -q 'stroke-width="2"' "$ROOT/modules/tools/icons-light/ostrich-store.svg"
}

@test "ostrich-icon-style puts the set for the colour scheme into the icon theme" {
	export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
	mkdir -p "$XDG_DATA_HOME/ostrich-os/icons" "$XDG_DATA_HOME/icons/hicolor/scalable/apps" "$BATS_TEST_TMPDIR/bin"
	cp -r "$ROOT/modules/tools/icons" "$XDG_DATA_HOME/ostrich-os/icons/dark"
	cp -r "$ROOT/modules/tools/icons-light" "$XDG_DATA_HOME/ostrich-os/icons/light"
	for scheme in prefer-dark default; do
		printf '#!/bin/sh\necho "%s"\n' "'$scheme'" >"$BATS_TEST_TMPDIR/bin/gsettings"
		chmod +x "$BATS_TEST_TMPDIR/bin/gsettings"
		PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$ROOT/modules/tools/ostrich-icon-style" apply
		[ "$status" -eq 0 ]
		want=dark
		[ "$scheme" = default ] && want=light
		cmp "$XDG_DATA_HOME/icons/hicolor/scalable/apps/ostrich-store.svg" "$XDG_DATA_HOME/ostrich-os/icons/$want/ostrich-store.svg"
	done
}

@test "export.sh refuses a different look without ICONS_OUT (it would overwrite the committed icons)" {
	run env TEMPLATE="$ROOT/tools/icons/template-light.svg" "$ROOT/tools/icons/export.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"ICONS_OUT"* ]]
	run "$ROOT/tools/icons/export.sh" --check
	[ "$status" -eq 0 ]
}
