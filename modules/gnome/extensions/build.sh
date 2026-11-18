#!/usr/bin/env bash
# modules/gnome/extensions/build.sh: build installable zips for every extension in this folder.
#
#   build.sh [name...]     (default: all)
#
# For each extension: copy it plus _lib/ into dist/build/<uuid>/, fill its stylesheet.css.in with the
# palette's colours ({{name}} from tools/icons/palette.toml, or PALETTE=FILE) and the sizes ([[name]]
# from tools/icons/tokens.toml), compile its schemas,
# and pack dist/<uuid>.shell-extension.zip. Writes only inside the repo's dist/ (gitignored).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DIST="${DIST:-$ROOT/dist}"

die() {
	echo "build: $*" >&2
	exit 1
}
command -v gnome-extensions >/dev/null 2>&1 || die "gnome-extensions not found (package gnome-shell)"

uuid_of() { sed -n 's/^ *"uuid": *"\([^"]*\)".*/\1/p' "$1/metadata.json"; }

# The palette's lines (name = "value") as sed expressions that replace {{name}}.
PALETTE="${PALETTE:-$ROOT/tools/icons/palette.toml}"
[[ -f $PALETTE ]] || die "no palette at $PALETTE"
fills=()
while IFS= read -r line; do
	[[ $line =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]] && fills+=(-e "s|{{${BASH_REMATCH[1]}}}|${BASH_REMATCH[2]}|g")
done <"$PALETTE"
TOKENS="$ROOT/tools/icons/tokens.toml"
while IFS= read -r line; do
	[[ $line =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]] && fills+=(-e "s|\\[\\[${BASH_REMATCH[1]}\\]\\]|${BASH_REMATCH[2]}|g")
done <"$TOKENS"

build_one() {
	local src=$1 uuid out
	[[ -f $src/metadata.json && -f $src/extension.js ]] || die "$src is not an extension"
	uuid=$(uuid_of "$src")
	[[ $uuid == *@ubuntu-ostrich ]] || die "$src: uuid must end in @ubuntu-ostrich (got '$uuid')"
	out="$DIST/build/$uuid"
	rm -rf "$out"
	mkdir -p "$out"
	cp -r "$src"/. "$out"/
	cp -r "$HERE/_lib" "$out/_lib"
	cp "$HERE/LICENSE" "$out/LICENSE"
	if [[ -f $out/stylesheet.css.in ]]; then
		sed "${fills[@]}" "$out/stylesheet.css.in" >"$out/stylesheet.css"
		rm "$out/stylesheet.css.in"
		if grep -q '\[\[' "$out/stylesheet.css"; then
			die "$src/stylesheet.css.in uses a size $TOKENS doesn't have: $(grep -o '\[\[[a-z_]*\]\]' "$out/stylesheet.css" | sort -u | tr '\n' ' ')"
		fi
		if grep -q '{{' "$out/stylesheet.css"; then
			die "$src/stylesheet.css.in uses a name $PALETTE doesn't have: $(grep -o '{{[a-z_]*}}' "$out/stylesheet.css" | sort -u | tr '\n' ' ')"
		fi
	fi
	# Everything that gnome-extensions pack doesn't pick up by itself goes in as an extra source.
	local -a extra=()
	local f
	for f in "$out"/*; do
		case $(basename "$f") in
		metadata.json | extension.js | prefs.js | stylesheet.css | schemas) ;;
		*) extra+=("--extra-source=$(basename "$f")") ;;
		esac
	done
	local -a schema=()
	[[ -d $out/schemas ]] && schema=(--schema="$(ls "$out"/schemas/*.gschema.xml)")
	(cd "$out" && gnome-extensions pack --force --out-dir="$DIST" "${extra[@]}" "${schema[@]}" .) >/dev/null
	echo "built $DIST/$uuid.shell-extension.zip"
}

mkdir -p "$DIST"
if (($# > 0)); then
	for name in "$@"; do build_one "$HERE/$name"; done
else
	for dir in "$HERE"/*/; do
		[[ $(basename "$dir") == _lib ]] && continue
		build_one "${dir%/}"
	done
fi
