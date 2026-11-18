#!/usr/bin/env bats
# tests/image.bats: image/to-usb.sh refuses anything but a whole, unmounted, writable USB disk
# (a fake lsblk; no QEMU), and image/portable-esp.sh on a fake ESP.

setup() {
	TO_USB="$BATS_TEST_DIRNAME/../image/to-usb.sh"
	ESP_FIX="$BATS_TEST_DIRNAME/../image/portable-esp.sh"
	export LSBLK="$BATS_TEST_TMPDIR/lsblk"
	export FAKE_DISK="$BATS_TEST_TMPDIR/sdz"
	: >"$FAKE_DISK"
	# CI's container has no QEMU or firmware; the ERASE prompt comes after that check.
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	printf '#!/bin/sh\n' >"$BATS_TEST_TMPDIR/bin/qemu-system-x86_64"
	chmod +x "$BATS_TEST_TMPDIR/bin/qemu-system-x86_64"
	export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
	export OVMF_CODE="$FAKE_DISK" OVMF_VARS_TEMPLATE="$FAKE_DISK"
}

# fake_lsblk TYPE TRAN [MOUNTPOINT]
fake_lsblk() {
	cat >"$LSBLK" <<SH
#!/bin/sh
case "\$*" in
*MOUNTPOINTS*) printf '%s\n' "${3:-}" ;;
*) echo "$1 $2 59.8G Extreme SSD" ;;
esac
SH
	chmod +x "$LSBLK"
}

@test "refuses an internal NVMe disk" {
	fake_lsblk disk nvme
	run "$TO_USB" "$FAKE_DISK"
	[ "$status" -eq 1 ]
	[[ $output == *"not a USB drive"* ]]
}

@test "refuses a partition" {
	fake_lsblk part usb
	run "$TO_USB" "$FAKE_DISK"
	[ "$status" -eq 1 ]
	[[ $output == *"not a whole disk"* ]]
}

@test "refuses a mounted USB disk" {
	fake_lsblk disk usb /media/me/STICK
	run "$TO_USB" "$FAKE_DISK"
	[ "$status" -eq 1 ]
	[[ $output == *"in use"* ]]
}

@test "prints the setfacl command when it can't write" {
	fake_lsblk disk usb
	chmod a-w "$FAKE_DISK"
	run "$TO_USB" "$FAKE_DISK"
	[ "$status" -eq 1 ]
	[[ $output == *"sudo setfacl -m u:"*":rw $FAKE_DISK"* ]]
}

@test "stops without ERASE typed" {
	fake_lsblk disk usb
	ISO="$BATS_TEST_TMPDIR/x.iso" && : >"$ISO" && export ISO
	run "$TO_USB" "$FAKE_DISK" <<<"no"
	[ "$status" -eq 1 ]
	[[ $output == *"nothing was changed"* ]]
}

@test "portable-esp: drops fbx64, puts grub next to shim, idempotent" {
	esp="$BATS_TEST_TMPDIR/boot/efi/EFI"
	mkdir -p "$esp/BOOT" "$esp/ubuntu"
	echo grub >"$esp/ubuntu/grubx64.efi"
	touch "$esp/BOOT/BOOTX64.EFI" "$esp/BOOT/fbx64.efi" "$esp/BOOT/mmx64.efi"
	"$ESP_FIX" "$BATS_TEST_TMPDIR"
	"$ESP_FIX" "$BATS_TEST_TMPDIR"
	[ ! -e "$esp/BOOT/fbx64.efi" ]
	cmp "$esp/ubuntu/grubx64.efi" "$esp/BOOT/grubx64.efi"
	[ -e "$esp/BOOT/BOOTX64.EFI" ]
}

@test "portable-esp: no ESP is a no-op" {
	run "$ESP_FIX" "$BATS_TEST_TMPDIR/none"
	[ "$status" -eq 0 ]
}
