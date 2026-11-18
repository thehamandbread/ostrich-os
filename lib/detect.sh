#!/usr/bin/env bash
# lib/detect.sh: OS and hardware detection. Source, don't execute. Read-only.
#
# SYSFS_ROOT, UDEV_DATA and OS_RELEASE_FILE can be pointed at fixtures in tests.

SYSFS_ROOT="${SYSFS_ROOT:-/sys}"
UDEV_DATA="${UDEV_DATA:-/run/udev/data}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

# os_id_version: prints "<ID> <VERSION_ID>" without leaking os-release variables.
os_id_version() {
	[[ -r $OS_RELEASE_FILE ]] || {
		echo "unknown unknown"
		return 0
	}
	(
		# shellcheck disable=SC1090
		. "$OS_RELEASE_FILE"
		printf '%s %s\n' "${ID:-unknown}" "${VERSION_ID:-unknown}"
	)
}

# pci_display_vendors: vendor IDs of PCI display controllers (class 0x03xxxx), one per line.
pci_display_vendors() {
	local dev
	for dev in "$SYSFS_ROOT"/bus/pci/devices/*; do
		[[ -r $dev/class && -r $dev/vendor ]] || continue
		[[ $(<"$dev/class") == 0x03* ]] && cat "$dev/vendor"
	done
}

# Hybrid: an NVIDIA GPU plus an Intel (0x8086) or AMD (0x1002) one.
is_hybrid_graphics() {
	local vendors
	vendors=$(pci_display_vendors)
	grep -qx 0x10de <<<"$vendors" && grep -qxE '0x8086|0x1002' <<<"$vendors"
}

dmi_field() {
	local f="$SYSFS_ROOT/class/dmi/id/$1"
	[[ -r $f ]] && tr -d '\n' <"$f"
}

is_dell() { [[ $(dmi_field sys_vendor) == "Dell Inc." ]]; }

has_touchscreen() { grep -qsl '^E:ID_INPUT_TOUCHSCREEN=1$' "$UDEV_DATA"/* 2>/dev/null; }
