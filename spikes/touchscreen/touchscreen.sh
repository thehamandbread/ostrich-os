#!/usr/bin/env bash
# spikes/touchscreen/touchscreen.sh: throwaway prototype of system-helper's touchscreen toggle.
#
#   touchscreen.sh status
#   touchscreen.sh off [--level hid|transport] [--persist]    (root)
#   touchscreen.sh on                                          (root)
#
# Finds touchscreens by the udev property ID_INPUT_TOUCHSCREEN=1 (never by name or position), then
# unbinds a driver above them in sysfs:
#   hid        the nearest ancestor with a driver (e.g. hid-multitouch): input stops
#   transport  one driver further up (e.g. i2c_hid_acpi), if it only serves this touchscreen:
#              the controller can power down too
# --persist writes a udev rule that unbinds it again when it appears (boot, rebind).
# State lives in $STATE (what was unbound, so `on` can rebind it exactly).
set -euo pipefail

SYS="${SYS:-/sys}"
STATE="${STATE:-/var/lib/ubuntu-ostrich/touchscreen.state}"
RULE="${RULE:-/etc/udev/rules.d/90-ubuntu-ostrich-touchscreen.rules}"

die() {
	echo "touchscreen: $*" >&2
	exit 1
}

# Prints the realpath of each touchscreen event node.
touchscreens() {
	local ev
	for ev in "$SYS"/class/input/event*; do
		[[ -e $ev ]] || continue
		udevadm info -q property -p "$ev" 2>/dev/null | grep -qx 'ID_INPUT_TOUCHSCREEN=1' && realpath "$ev"
	done
	return 0
}

# Prints the bound ancestors of a sysfs path, nearest first: "<devpath> <driver-path>".
bound_ancestors() {
	local x=$1
	while [[ $x != "$SYS" && $x != / ]]; do
		[[ -L $x/driver ]] && echo "$x $(readlink -f "$x/driver")"
		x=$(dirname "$x")
	done
}

# Number of driver-bound child devices directly below a sysfs device. A touch controller is one
# HID device even when it exposes several inputs (touch, pen, vendor collections).
bound_children() {
	local n=0 c
	for c in "$1"/*/; do
		[[ -L ${c}driver ]] && n=$((n + 1))
	done
	echo "$n"
}

pick_target() {
	local ev=$1 level=$2
	mapfile -t anc < <(bound_ancestors "$ev")
	((${#anc[@]} > 0)) || die "no bound driver above $ev"
	if [[ $level == transport && ${#anc[@]} -ge 2 ]]; then
		read -r dev _ <<<"${anc[1]}"
		if (($(bound_children "$dev") == 1)); then
			echo "${anc[1]}"
			return
		fi
		echo "touchscreen: transport serves other devices; using the hid level" >&2
	fi
	echo "${anc[0]}"
}

cmd_status() {
	local ev dev drv found=0
	while read -r ev; do
		found=1
		echo "on: $(cat "$(dirname "$ev")/name" 2>/dev/null || basename "$ev")"
		local -a anc
		mapfile -t anc < <(bound_ancestors "$ev")
		local line
		for line in "${anc[@]:0:2}"; do
			read -r dev drv <<<"$line"
			echo "  $(basename "$dev") -> $(basename "$drv")"
		done
	done < <(touchscreens)
	if [[ -s $STATE ]]; then
		while read -r dev drv; do echo "off: $(basename "$dev") (unbound from $(basename "$drv"))"; done <"$STATE"
		found=1
	fi
	((found)) || echo "no touchscreen"
}

cmd_off() {
	local level=transport persist=0
	while (($# > 0)); do
		case $1 in
		--level) level=$2 && shift ;;
		--persist) persist=1 ;;
		*) die "unknown option $1" ;;
		esac
		shift
	done
	((EUID == 0)) || die "off needs root"
	local -a evs
	mapfile -t evs < <(touchscreens)
	((${#evs[@]} > 0)) || die "no touchscreen found (already off?)"
	mkdir -p "$(dirname "$STATE")"
	local ev dev drv name subsys
	for ev in "${evs[@]}"; do
		read -r dev drv < <(pick_target "$ev" "$level")
		name=$(basename "$dev")
		echo "$name" >"$drv/unbind"
		echo "$dev $drv" >>"$STATE"
		echo "off: unbound $name from $(basename "$drv")"
		if ((persist)); then
			subsys=$(basename "$(readlink -f "$dev/subsystem")")
			printf 'ACTION=="add|bind", SUBSYSTEM=="%s", KERNEL=="%s", DRIVER=="%s", RUN+="/bin/sh -c '"'"'echo %%k > %s/unbind'"'"'"\n' \
				"$subsys" "$name" "$(basename "$drv")" "$drv" >>"$RULE"
		fi
	done
	((persist)) && udevadm control --reload && echo "persisted in $RULE"
	return 0
}

cmd_on() {
	((EUID == 0)) || die "on needs root"
	rm -f "$RULE"
	udevadm control --reload
	[[ -s $STATE ]] || die "nothing to turn back on"
	local dev drv
	while read -r dev drv; do
		basename "$dev" >"$drv/bind"
		echo "on: rebound $(basename "$dev") to $(basename "$drv")"
	done <"$STATE"
	rm -f "$STATE"
}

case ${1:-} in
status) cmd_status ;;
off) shift && cmd_off "$@" ;;
on) cmd_on ;;
*) die "usage: touchscreen.sh status | off [--level hid|transport] [--persist] | on" ;;
esac
