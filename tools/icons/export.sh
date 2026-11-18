#!/usr/bin/env bash
# tools/icons/export.sh: makes the Ubuntu Ostrich app icons. Fills template.svg with each glyph in
# glyphs/ and the colours in palette.toml, and copies each 16 px symbolic from symbolic/, writing
# modules/tools/icons/ostrich-NAME.svg and ostrich-NAME-symbolic.svg (the installer's copies).
# Needs only bash and sed, so it runs headless (and Claude can drive it). With rsvg-convert or
# Inkscape installed it also renders PNG previews at 16, 32, 48 and 128 px into a preview folder.
#
#   export.sh [--check] [--preview DIR]
#     --check     only verify the committed icons match what this would write (CI)
#     --preview   where previews go (default: $XDG_CACHE_HOME/ubuntu-ostrich/icon-previews)
#
# The default look is two sets: modules/tools/icons/ for the dark style (template.svg, dark.toml) and
# modules/tools/icons-light/ for the light one (template-light.svg, light.toml). modules/tools/install.sh
# installs both and ostrich-icon-style swaps them with the colour scheme. Every run of the script
# writes (or, with --check, checks) both.
#
# Environment, for trying another look without touching the committed icons
# (each defaults to the look above):
#   ICONS_OUT      where the icons go (default modules/tools/icons: use a fresh folder, it is emptied)
#   PALETTE        another palette file (a scheme)
#   PALETTE_OVER   a file of name = "#rrggbb" lines that replace single colours of the palette
#   TEMPLATE       another glass-square template (it may use @NAME@, the app's name, in a colour name:
#                  {{body_@NAME@}} is {{body_store}} for the store)
#   GLYPHS         glyphs (default: glyphs/NAME.svg) or symbolic (the 16 px symbolic drawing, scaled
#                  4x into the glyph box, in the glyph colour)
#
# To draw a new icon: add glyphs/NAME.svg (shapes on the 128 px grid, inside 32..96, using
# {{glyph}}, {{accent}} and the other palette names) and symbolic/NAME.svg (one colour, #2e3436,
# 16 px), then run this. Hand-editing in Inkscape works too: open the generated SVG, then copy your
# shapes back into the glyph file.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${ICONS_OUT:-$(cd "$HERE/../.." && pwd)/modules/tools/icons}" # ICONS_OUT: elsewhere (scheme previews)
PREVIEW="${XDG_CACHE_HOME:-$HOME/.cache}/ubuntu-ostrich/icon-previews"
CHECK=0
ARGS=("$@")
while (($# > 0)); do
	case $1 in
	--check) CHECK=1 ;;
	--preview) PREVIEW=$2 && shift ;;
	*)
		echo "usage: export.sh [--check] [--preview DIR]" >&2
		exit 2
		;;
	esac
	shift
done

# No override in the environment: the default look, which is also the light set.
if [[ -z ${ICONS_OUT:-}${TEMPLATE:-}${PALETTE:-}${PALETTE_OVER:-}${GLYPHS:-} ]]; then
	ICONS_OUT="$(cd "$HERE/../.." && pwd)/modules/tools/icons-light" TEMPLATE="$HERE/template-light.svg" \
	PALETTE_OVER="$HERE/light.toml" "${BASH_SOURCE[0]}" "${ARGS[@]}" --preview "$PREVIEW-light"
fi

# A different look must not be written over the committed icons.
if ((!CHECK)) && [[ -z ${ICONS_OUT:-} && -n ${TEMPLATE:-}${PALETTE:-}${PALETTE_OVER:-}${GLYPHS:-} ]]; then
	echo "export: TEMPLATE, PALETTE, PALETTE_OVER and GLYPHS change the look: set ICONS_OUT to a fresh folder too, or the committed icons would be overwritten" >&2
	exit 2
fi

# palette.toml (or PALETTE=FILE, another scheme): lines of name = "#rrggbb", or "currentColor" (a glyph
# that takes the colour a template sets with color= on a group), comments allowed; the
# rgba() ones are for the extensions' stylesheets). PALETTE_OVER=FILE replaces single colours of it.
declare -A colour
read_colours() { # file
	local line
	while IFS= read -r line; do
		if [[ $line =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*\"(#[0-9a-fA-F]{6}|currentColor)\" ]]; then
			colour[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
		fi
	done <"$1"
}
read_colours "${PALETTE:-$HERE/palette.toml}"
read_colours "${PALETTE_OVER:-$HERE/dark.toml}"
TEMPLATE="${TEMPLATE:-$HERE/template.svg}"

fill() { # text on stdin, palette names replaced
	local args=() k
	for k in "${!colour[@]}"; do
		args+=(-e "s/{{$k}}/${colour[$k]}/g")
	done
	sed "${args[@]}"
}

glyph_of() { # name: the glyph's shapes, indented
	if [[ ${GLYPHS:-glyphs} == symbolic ]]; then
		printf '  <g transform="translate(32 32) scale(4)">\n'
		sed -e '1d;$d' -e 's/#2e3436/{{glyph}}/g' -e 's/^/  /' "$HERE/symbolic/$1.svg"
		printf '  </g>\n'
	else
		grep -v '^<!--' "$HERE/glyphs/$1.svg" | sed 's/^/  /'
	fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for g in "$HERE"/glyphs/*.svg; do
	name=$(basename "$g" .svg)
	[[ -f $HERE/symbolic/$name.svg ]] || {
		echo "export: symbolic/$name.svg is missing" >&2
		exit 1
	}
	glyph=$(glyph_of "$name" | sed "s/@NAME@/$name/g" | fill)
	while IFS= read -r line; do
		if [[ $line == *'{{glyph_svg}}'* ]]; then
			printf '%s\n' "$glyph"
		else
			printf '%s\n' "$line"
		fi
	done < <(sed "s/@NAME@/$name/g" "$TEMPLATE" | fill) >"$work/ostrich-$name.svg"
	if grep -q '{{' "$work/ostrich-$name.svg"; then
		echo "export: ostrich-$name.svg uses a name palette.toml doesn't have: $(grep -o '{{[a-z_]*}}' "$work/ostrich-$name.svg" | sort -u | tr '\n' ' ')" >&2
		exit 1
	fi
	cp "$HERE/symbolic/$name.svg" "$work/ostrich-$name-symbolic.svg"
done

if ((CHECK)); then
	diff -r "$work" "$OUT" >/dev/null || {
		echo "export: the icons are out of date; run tools/icons/export.sh" >&2
		diff -r "$work" "$OUT" >&2 || true
		exit 1
	}
	echo "export: icons up to date"
	exit 0
fi
mkdir -p "$OUT"
rm -f "$OUT"/*.svg
cp "$work"/*.svg "$OUT"/
echo "export: wrote $(find "$OUT" -name '*.svg' | wc -l) icons to $OUT"

render=""
if command -v rsvg-convert >/dev/null 2>&1; then
	render=rsvg
elif command -v inkscape >/dev/null 2>&1; then
	render=inkscape
fi
if [[ -z $render ]]; then
	echo "export: no rsvg-convert or inkscape, so no previews (apt install librsvg2-bin)"
	exit 0
fi
mkdir -p "$PREVIEW"
for f in "$OUT"/*.svg; do
	for s in 16 32 48 128; do
		png="$PREVIEW/$(basename "$f" .svg)-$s.png"
		if [[ $render == rsvg ]]; then
			rsvg-convert -w "$s" -h "$s" "$f" -o "$png"
		else
			inkscape "$f" -w "$s" -h "$s" -o "$png" >/dev/null 2>&1
		fi
	done
done
echo "export: previews in $PREVIEW"
