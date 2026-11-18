#!/usr/bin/env bash
# image/portable-esp.sh [ROOT]: let an install on a USB drive boot on any PC without writing to
# that PC's firmware. Booted from the boot menu, the drive starts \EFI\BOOT\BOOTX64.EFI (shim),
# which runs fbx64.efi, and fbx64 adds an "ubuntu" boot entry to that PC's NVRAM. Without fbx64,
# shim loads grubx64.efi from its own folder instead, which finds \EFI\ubuntu\grub.cfg as usual.
# Run by the portable image's late-commands and by an apt hook, so shim/grub updates don't undo it.
# Idempotent; does nothing when there is no ESP or no Ubuntu grub.
set -euo pipefail
efi="${1:-}/boot/efi/EFI"
[[ -d $efi ]] || exit 0
boot=$(find "$efi" -maxdepth 1 -type d -iname boot | head -n 1)
grub=$(find "$efi" -maxdepth 2 -ipath '*/ubuntu/grubx64.efi' | head -n 1)
[[ -n $boot && -n $grub ]] || exit 0
cmp -s "$grub" "$boot/grubx64.efi" || cp "$grub" "$boot/grubx64.efi"
find "$boot" -maxdepth 1 -iname fbx64.efi -delete
