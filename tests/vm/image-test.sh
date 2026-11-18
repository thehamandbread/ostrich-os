#!/usr/bin/env bash
# tests/vm/image-test.sh: install from the Ubuntu Ostrich image in a throwaway VM and check it.
#
#   image-test.sh [--keep] [--portable]
#
# Builds an --unattended-test image (image/build-iso.sh; the answers a person would give are filled
# in), installs it onto a fresh disk in its own VM directory (the main test VM and its snapshots
# are not touched), then waits for the first-login finish to run the installer from the image and
# checks the result like e2e.sh. The throwaway disk is deleted afterwards unless --keep.
# --portable builds the image for a USB drive (image/to-usb.sh) and then boots the disk twice with
# empty firmware settings (two PCs it has never been in): it must boot, and add no boot entry.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VM="$HERE/vm.sh"
PROJECT="ubuntu-ostrich"
MAIN_VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
IMG="$MAIN_VM_DIR/image-test"
KEEP=0
PORTABLE=()
for a in "$@"; do
	case $a in
	--keep) KEEP=1 ;;
	--portable) PORTABLE=(--portable) ;;
	*) echo "usage: image-test.sh [--keep] [--portable]" >&2 && exit 1 ;;
	esac
done

log() { printf '[image-test] %s\n' "$*" >&2; }
fail() {
	log "FAIL: $*"
	exit 1
}
v() { VM_DIR="$IMG" "$VM" "$@"; }

"$VM" stop >/dev/null 2>&1 || true # the main VM uses the same ports
v stop >/dev/null 2>&1 || true
rm -rf "$IMG"
mkdir -p "$IMG"
# The same throwaway login as the main test VM (its key and password, never the user's own).
cp "$MAIN_VM_DIR/id_ed25519" "$MAIN_VM_DIR/id_ed25519.pub" "$MAIN_VM_DIR/password" "$IMG/"

log "building the unattended test image"
VM_DIR="$MAIN_VM_DIR" "$ROOT/image/build-iso.sh" --unattended-test "${PORTABLE[@]}" --out "$IMG/ostrich-test.iso" >&2
v create >&2
log "installing from the image (20-40 min)"
VM_ISO="$IMG/ostrich-test.iso" VM_SEED=0 v install >&2
v start >&2

# shellcheck disable=SC2016 # expands in the VM
state='$HOME/.local/state/ubuntu-ostrich'
log "waiting for the first-login finish (it runs the installer from /opt/ubuntu-ostrich)"
for ((i = 0; i < 90; i++)); do
	if v ssh "test -e $state/firstboot-done" 2>/dev/null; then
		break
	fi
	if v ssh "grep -q '\[ERROR\]' $state/install.log 2>/dev/null"; then
		v ssh "tail -20 $state/install.log" >&2 || true
		fail "the installer reported an error"
	fi
	sleep 20
done
v ssh "test -e $state/firstboot-done" || fail "the first-login finish didn't complete in 30 minutes"

log "checks"
EXTS=$(find "$ROOT/modules/gnome/extensions" -mindepth 1 -maxdepth 1 -type d ! -name _lib -printf '%f ' | sort)
v ssh "EXTS='$EXTS' bash -s" <<'EOF' || fail "post-install checks failed"
set -euo pipefail
check() { if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
check "image payload in /opt" '[ -x /opt/ubuntu-ostrich/firstboot/finish.sh ] && [ -f /opt/ubuntu-ostrich/release/SHA256SUMS ]'
check "managed copy with GitHub as origin (for ostrich update)" 'git -C ~/.local/share/ubuntu-ostrich/src remote get-url origin | grep -q github.com/thehamandbread/ubuntu-ostrich'
check "tools came from the image's release" 'grep -q "from file:///opt/ubuntu-ostrich/release" ~/.local/state/ubuntu-ostrich/install.log'
check "ostrich command" '~/.local/bin/ostrich help | grep -q store'
check "extensions installed" 'for u in $EXTS; do [ -f ~/.local/share/gnome-shell/extensions/$u@ubuntu-ostrich/metadata.json ] || exit 1; done'
check "wizard autostarts" '[ -f ~/.config/autostart/ostrich-setup.desktop ]'
EOF

log "logging in again"
v stop >&2
v start >&2
sleep 10
v ssh "EXTS='$EXTS' bash -s" <<'EOF' || fail "checks after re-login failed"
set -euo pipefail
[ "$(gsettings get org.gnome.shell disable-user-extensions)" = false ] || { echo "  FAIL: GNOME disabled user extensions"; exit 1; }
for u in $EXTS; do
	s=$(gnome-extensions info $u@ubuntu-ostrich | sed -n "s/^ *State: //p")
	[ "$s" = ACTIVE ] && echo "  ok: $u active" || { echo "  FAIL: $u state=$s"; exit 1; }
done
pgrep -f "[f]irstboot/finish.sh" >/dev/null && { echo "  FAIL: the finish ran again"; exit 1; }
echo "  ok: the first-login finish didn't run again"
EOF

v stop >&2

if ((${#PORTABLE[@]})); then
	for pc in 1 2; do
		log "portable: booting with empty firmware settings (PC $pc)"
		cp /usr/share/OVMF/OVMF_VARS_4M.fd "$IMG/OVMF_VARS.fd"
		v start >&2
		v ssh 'bash -s' <<'EOF' || fail "portable boot $pc"
set -euo pipefail
sudo test -e /boot/efi/EFI/BOOT/grubx64.efi || { echo "  FAIL: no grub beside shim"; exit 1; }
! sudo test -e /boot/efi/EFI/BOOT/fbx64.efi || { echo "  FAIL: fbx64.efi is back"; exit 1; }
entries=$(sudo efibootmgr) # its own line, so a failing efibootmgr fails the check
if grep -qi ubuntu <<<"$entries"; then echo "  FAIL: a boot entry was added:"; echo "$entries"; exit 1; fi
echo "  ok: booted; no boot entry added to this PC"
EOF
		v stop >&2
	done
fi

if ((KEEP)); then
	log "PASS (kept $IMG)"
else
	rm -f "$IMG/disk.qcow2" "$IMG/ostrich-test.iso"
	log "PASS (throwaway disk deleted; --keep keeps it)"
fi
