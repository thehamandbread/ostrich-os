#!/usr/bin/env bash
# tools/package.sh: package a release the way the installer expects it.
#
#   tools/package.sh <bin-dir> <zips-dir> <out-dir>
#
# <bin-dir> holds the release binaries (tools/target/release), <zips-dir> the extension zips
# (dist/). Writes ubuntu-ostrich-tools-v<VERSION>-amd64.tar.gz, copies the zips and writes
# SHA256SUMS into <out-dir>. Used by .github/workflows/release.yml and tests/vm/e2e.sh --pipe.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINS=(ostrich ostrich-drawer ostrich-setup ostrich-store ostrich-store-gtk ostrich-theme ostrich-speakers ostrich-system-helper)

(($# == 3)) || {
	echo "usage: tools/package.sh <bin-dir> <zips-dir> <out-dir>" >&2
	exit 2
}
bin_dir=$1 zips_dir=$2 out=$3
version=$(cat "$ROOT/VERSION")
name="ubuntu-ostrich-tools-v$version-amd64"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/$name/bin" "$out"
for b in "${BINS[@]}"; do
	install -m 755 "$bin_dir/$b" "$work/$name/bin/$b"
done
cp "$ROOT/LICENSE" "$work/$name/"
tar -C "$work" -czf "$out/$name.tar.gz" "$name"
shopt -s nullglob
zips=("$zips_dir"/*@ubuntu-ostrich.shell-extension.zip)
((${#zips[@]} > 0)) || {
	echo "package: no extension zips in $zips_dir (run modules/gnome/extensions/build.sh)" >&2
	exit 1
}
[[ $(realpath "$zips_dir") == $(realpath "$out") ]] || cp "${zips[@]}" "$out/"
(cd "$out" && sha256sum "$name.tar.gz" ./*@ubuntu-ostrich.shell-extension.zip | sed 's| \./| |' >SHA256SUMS)
echo "packaged $out/$name.tar.gz (+ ${#zips[@]} extensions, SHA256SUMS)"
