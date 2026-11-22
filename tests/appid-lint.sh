#!/usr/bin/env bash
# tests/appid-lint.sh [REPO]: the portal's dash rule (docs/DECISIONS.md 2026-10-31, plan 01).
# xdg-desktop-portal accepts a dash only in the last part of an app id; a dash anywhere else made
# its Flatpak lookup fail without an error and the portal crashed on every call from that app.
# Fails (exit 1) on an app id, .desktop id, Gio.Application id or D-Bus name with a dash in any
# part but the last. Looked at:
#   - *.desktop names, anywhere (tracked files, and names written in scripts and Rust)
#   - Rust: .application_id("...") and const APP_ID / *_APP_ID / BUS_NAME strings
#   - JS:   const APP_ID / *_APP / *_APP_ID / *_PREFIX / BUS_NAME / *_BUS_NAME strings
# A polkit action (org.ostrich-os.system-helper.*) is not an app id and is not looked at.
# Not looked at: tests/, docs/, spikes/, lib/migrate.sh (they name the old ids on purpose), and
# globs such as ubuntu-ostrich.drawer*.desktop (cleanup of old launchers).
set -euo pipefail
REPO="${1:-$(git rev-parse --show-toplevel)}"

# Known violations, reported on every run, removed when the rename (plan 01) lands. Anything not
# in this list fails the lint. shortcut: a list in the script; delete it with the rename.
PENDING=(ubuntu-ostrich.store ubuntu-ostrich.setup)

bad_id() { # <id>: status 0 if a part other than the last holds a dash
	local id=${1%.desktop} last
	last=${id##*.}
	[[ $id == *.* && ${id%".$last"} == *-* ]]
}

mapfile -t files < <(find "$REPO" -type f \( -name '*.rs' -o -name '*.js' -o -name '*.sh' -o -name '*.desktop' -o -name '*.in' -o -name '*.toml' \) \
	-not -path '*/target/*' -not -path '*/node_modules/*' -not -path '*/dist/*' -not -path '*/.git/*' -not -path '*/graphify-out/*' \
	-not -path "$REPO/tests/*" -not -path "$REPO/docs/*" -not -path "$REPO/spikes/*" -not -path '*/.claude/worktrees/*' \
	-not -path "$REPO/lib/migrate.sh" | sort)

fail=0
seen=""
report() { # <id> <where>
	local id=${1%.desktop} p
	for p in "${PENDING[@]}"; do
		if [[ $id == "$p" ]]; then
			[[ $seen == *"|$id $2|"* ]] || echo "appid-lint: pending rename: $id ($2)"
			seen+="|$id $2|"
			return
		fi
	done
	echo "appid-lint: dash before the last part: $1 ($2)" >&2
	fail=1
}

for f in "${files[@]}"; do
	rel=${f#"$REPO"/}
	ids=()
	# .desktop names: the file's own name, and any name written in a script or source file.
	[[ $f == *.desktop ]] && ids+=("$(basename "$f")")
	mapfile -t found < <(grep -ohE '[A-Za-z0-9_*-]+(\.[A-Za-z0-9_*-]+)+\.desktop' "$f" || true)
	ids+=("${found[@]}")
	case $f in
	*.rs)
		mapfile -t found < <(grep -ohE '(application_id\(|const [A-Z_]*(APP_ID|BUS_NAME)[A-Z_]*: &str = )"[^"]+"' "$f" | grep -oE '"[^"]+"' | tr -d '"' || true)
		ids+=("${found[@]}")
		;;
	*.js)
		mapfile -t found < <(grep -ohE "const [A-Z_]*(APP_ID|_APP|BUS_NAME|_PREFIX)[A-Z_]* = '[^']+'" "$f" | grep -oE "'[^']+'" | tr -d "'" || true)
		ids+=("${found[@]}")
		;;
	esac
	for id in "${ids[@]}"; do
		# a glob (ubuntu-ostrich.drawer*.desktop) is cleanup of old launchers, not an id
		[[ -n $id && $id != *'*'* ]] || continue
		# a bare word with no dot is one part: its last
		bad_id "$id" && report "$id" "$rel"
	done
done

((fail == 0)) && echo "appid-lint: ok"
exit $fail
