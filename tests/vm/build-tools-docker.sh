#!/usr/bin/env bash
# tests/vm/build-tools-docker.sh: build the Rust tools in an ubuntu:26.04 container (what the
# release workflow does) and put the release binaries in $TOOLS_OUT (default $VM_DIR/tools-bin-docker)
# with the .tools-stamp the installer checks. Unlike build-tools.sh it never starts or restores the
# main test VM, so it is what tests that must leave that VM alone use.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ostrich-os/vm}"
OUT="${TOOLS_OUT:-$VM_DIR/tools-bin-docker}"
# shellcheck source=lib/tools-build.sh
source "$ROOT/lib/tools-build.sh"

mkdir -p "$OUT" "$ROOT/tools/target"
# The build tree stays in tools/target (git ignores it), so a second run is incremental.
docker run --rm -v "$ROOT:/src" -w /src/tools ubuntu:26.04 bash -ec '
	set -o pipefail
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends cargo rustc pkg-config ca-certificates libgtk-4-dev libwebkitgtk-6.0-dev libadwaita-1-dev >/dev/null
	cargo build --release --workspace --locked 2>&1 | tail -3
	chown -R '"$(id -u):$(id -g)"' target' >&2
for b in "${TOOLS_BINS[@]}"; do install -m 755 "$ROOT/tools/target/release/$b" "$OUT/$b"; done
tools_stamp "$ROOT" >"$OUT/.tools-stamp"
echo "[build-tools-docker] binaries in $OUT" >&2
