#!/usr/bin/env bash
# image/to-usb.sh: install Ostrich OS onto a USB drive, as a whole system you carry between PCs.
#
#   image/to-usb.sh DEVICE          run the installer (image/build-iso.sh --portable) onto DEVICE
#   image/to-usb.sh --boot DEVICE   boot the installed drive in a window (first login, checks)
#
# The installer runs in a QEMU window whose only disk is DEVICE, so this machine's own disks can't
# be picked. Every run starts with empty firmware settings, like a PC the drive has never been in.
# It refuses anything that isn't a whole, unmounted USB disk, and never runs sudo: it prints the
# one command that lets you write to DEVICE (the permission goes away when the drive is unplugged).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ISO="${ISO:-$ROOT/dist/ostrich-os-26.04-amd64.iso}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}" # the same firmware as tests/vm/vm.sh; tests swap in fakes
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
LSBLK="${LSBLK:-lsblk}" # tests swap in a fake

die() {
	echo "to-usb: $*" >&2
	exit 1
}
usage="usage: image/to-usb.sh [--boot] DEVICE   (find DEVICE with: lsblk -d -o NAME,TRAN,SIZE,MODEL)"
BOOT=0
[[ ${1:-} == --boot ]] && BOOT=1 && shift
(($# == 1)) || die "$usage"
dev=$(readlink -f "$1")

read -r type tran size model < <("$LSBLK" -dn -o TYPE,TRAN,SIZE,MODEL "$dev" 2>/dev/null) ||
	die "$dev: no such disk"
[[ $type == disk ]] || die "$dev is not a whole disk (it is a $type); give the disk, e.g. /dev/sdb"
[[ $tran == usb ]] || die "$dev is not a USB drive (connection: ${tran:-unknown}); refusing"
[[ $size != 0B ]] || die "$dev has no media in it (an empty card reader?)"
# Lists the disk's partitions and anything stacked on them (LUKS, LVM), including / and swap.
if "$LSBLK" -n -o MOUNTPOINTS "$dev" | grep -q .; then
	die "$dev is in use (mounted). Unmount its partitions (udisksctl unmount -b PARTITION; keep it plugged in), then run this again"
fi
[[ -w $dev ]] || die "no permission to write to $dev. Run this once, then run this again:
  sudo setfacl -m u:$(id -un):rw $dev"
for c in qemu-system-x86_64 "$OVMF_CODE" "$OVMF_VARS_TEMPLATE"; do
	command -v "$c" >/dev/null || [[ -e $c ]] || die "$c not found (see: tests/vm/vm.sh check)"
done

cdrom=()
if ((!BOOT)); then
	[[ -f $ISO ]] || die "no image at $ISO (build it: image/build-iso.sh --portable)"
	echo "The installer will ERASE everything on $dev: ${model:-unknown model}, $size."
	read -r -p "Type ERASE to continue: " answer
	[[ $answer == ERASE ]] || die "stopped; nothing was changed"
	cdrom=(-cdrom "$ISO")
fi

vars=$(mktemp)
trap 'rm -f "$vars"' EXIT
cp "$OVMF_VARS_TEMPLATE" "$vars"
echo "Opening a window. Install: pick 'Erase disk' (the USB drive is the only disk listed),"
echo "encryption recommended. After the restart, log in once to finish setup, then shut down."
qemu-system-x86_64 -name ostrich-os-usb \
	-machine q35,accel=kvm -cpu host -smp "${VM_CPUS:-4}" -m "${VM_MEM:-6G}" \
	-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
	-drive "if=pflash,format=raw,file=$vars" \
	-drive "file=$dev,if=virtio,format=raw,cache=none" \
	"${cdrom[@]}" \
	-nic user,model=virtio-net-pci -device virtio-tablet-pci \
	-device virtio-vga -display gtk
echo "Done. Shut down cleanly before unplugging; to check it: image/to-usb.sh --boot $1"
