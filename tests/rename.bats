#!/usr/bin/env bats
# tests/rename.bats: the earlier names (plan 01) appear only where tests/rename-allowlist.txt says.

PATTERN='ubuntu.?ostrich|ostrich.ubuntu|cleanest|ubuntuostrich'

setup() {
	ROOT="$BATS_TEST_DIRNAME/.."
	cd "$ROOT"
	mapfile -t ALLOWED < <(sed -e 's/[[:space:]]*#.*//' -e '/^[[:space:]]*$/d' tests/rename-allowlist.txt)
	# tracked and new files (not ignored), in a checkout; a plain tree (Docker copy) has no .git
	if git rev-parse --git-dir >/dev/null 2>&1; then
		git ls-files -co --exclude-standard
	else
		find . -type f -not -path './tools/target/*' -not -path './graphify-out/*' -not -path './dist/*' | sed 's|^\./||'
	fi >"$BATS_TEST_TMPDIR/files"
}

allowed() { # <path>
	local a
	for a in "${ALLOWED[@]}"; do
		[[ $1 == "$a" || ($a == */ && $1 == "$a"*) ]] && return 0
	done
	return 1
}

@test "no earlier name outside the allowlist (in file contents)" {
	local f bad=()
	while IFS= read -r f; do
		[[ -f $f ]] || continue
		allowed "$f" && continue
		grep -qIiE "$PATTERN" "$f" && bad+=("$f")
	done <"$BATS_TEST_TMPDIR/files"
	if ((${#bad[@]})); then
		printf 'earlier name in: %s\n' "${bad[@]}" >&2
		return 1
	fi
}

@test "no earlier name in a file or directory name" {
	run bash -c "grep -iE '$PATTERN' '$BATS_TEST_TMPDIR/files' | grep -v '^tests/fixtures/migrate/' | grep -v '^docs/'"
	[ -z "$output" ]
}

@test "every allowlist entry is still needed" {
	local a hit stale=()
	for a in "${ALLOWED[@]}"; do
		[[ $a == tests/rename-allowlist.txt || $a == tests/rename.bats ]] && continue
		if [[ $a == */ ]]; then
			hit=$(grep -rIilE "$PATTERN" "$a" 2>/dev/null | head -n 1 || true)
		else
			hit=$(grep -IilE "$PATTERN" "$a" 2>/dev/null || true)
		fi
		[[ -n $hit ]] || stale+=("$a")
	done
	if ((${#stale[@]})); then
		printf 'allowlist entry with no hit: %s\n' "${stale[@]}" >&2
		return 1
	fi
}
