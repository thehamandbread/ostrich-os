#!/usr/bin/env bash
# tests/vm/build-tools.sh: build the Rust tools in the dev VM (snapshot 'dev-tools' if there is
# one, else 'dev': the Rust, GTK 4, WebKitGTK and libadwaita toolchain) and copy the release
# binaries to $VM_DIR/tools-bin, where e2e.sh picks them up. Nothing is built on the host, and the
# snapshot itself isn't changed.
#
#   build-tools.sh [--check]   --check: cargo fmt --check, clippy (warnings are errors) and the
#                              tests first; stops at the first that fails
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VM="$HERE/vm.sh"
PROJECT="ubuntu-ostrich"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
OUT="$VM_DIR/tools-bin"
# shellcheck source=lib/tools-build.sh
source "$ROOT/lib/tools-build.sh"
BINS=("${TOOLS_BINS[@]}")

CHECK=0
[[ ${1:-} == --check ]] && CHECK=1
SNAPSHOT=dev
qemu-img snapshot -l "$VM_DIR/disk.qcow2" 2>/dev/null | awk '{print $2}' | grep -qx dev-tools && SNAPSHOT=dev-tools

log() { printf '[build-tools] %s\n' "$*" >&2; }
die() {
	log "$*"
	"$VM" stop
	exit 1
}

"$VM" stop
"$VM" snapshot restore "$SNAPSHOT"
"$VM" start
# The working tree, including files not committed yet (but nothing git ignores).
# tools/, plus the extension stylesheet templates the theme tool compiles in.
stamp=$(tools_stamp "$ROOT") # what is sent, so the installer can tell a stale build
git -C "$ROOT" ls-files -co --exclude-standard -- tools 'modules/gnome/extensions/*/stylesheet.css.in' | (cd "$ROOT" && tar -cf - -T -) |
	"$VM" ssh 'rm -rf ~/build && mkdir ~/build && tar -xf - -C ~/build'
# libadwaita-1-dev and clippy arrived after the dev snapshot was made. They go in together with
# cargo: installing clippy on its own removes cargo.
"$VM" ssh "dpkg -s libadwaita-1-dev rust-clippy >/dev/null 2>&1 || { sudo sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources && sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cargo rustc libadwaita-1-dev rustfmt rust-clippy >/dev/null; }"
if ((CHECK)); then
	log "cargo fmt --check"
	# shellcheck disable=SC2016 # expands in the VM
	"$VM" ssh 'source ~/.cargo/env 2>/dev/null; cd ~/build/tools && cargo fmt --all --check' || die "not formatted (cargo fmt --all)"
	log "cargo clippy"
	# shellcheck disable=SC2016 # expands in the VM
	"$VM" ssh 'source ~/.cargo/env 2>/dev/null; cd ~/build/tools && cargo clippy --workspace --all-targets --locked -q -- -D warnings' || die "clippy found problems"
	log "cargo test"
	# shellcheck disable=SC2016 # expands in the VM
	"$VM" ssh 'source ~/.cargo/env 2>/dev/null; cd ~/build/tools && cargo test --workspace --locked -q 2>&1 | grep -E "test result|FAILED|panicked|^error"; exit ${PIPESTATUS[0]}' || die "tests failed"
fi
log "cargo build --release --workspace --locked"
# shellcheck disable=SC2016 # expands in the VM
"$VM" ssh 'source ~/.cargo/env 2>/dev/null; cd ~/build/tools && cargo build --release --workspace --locked 2>&1 | tail -3'
rm -rf "$OUT"
mkdir -p "$OUT"
for b in "${BINS[@]}"; do
	"$VM" ssh "cat ~/build/tools/target/release/$b" >"$OUT/$b"
	chmod 755 "$OUT/$b"
done
echo "$stamp" >"$OUT/.tools-stamp"
"$VM" stop
log "binaries in $OUT"
