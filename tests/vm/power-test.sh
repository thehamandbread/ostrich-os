#!/usr/bin/env bash
# tests/vm/power-test.sh: the power-mode knobs in the test VM.
#
#   power-test.sh [--snapshot NAME]
#
# Needs a snapshot with Ubuntu Ostrich installed (default: post-fresh). Switches power saver on
# through power-profiles-daemon, as the user would, and checks the monitor extension had the helper
# set the knobs this VM has (PCIe ASPM, audio codec, USB, NMI watchdog, writeback) and the saver
# desktop (screen off after 2 min; animations stay on). Then checks balanced puts every value back, and
# that performance sets its own values (through the helper directly when the VM's
# power-profiles-daemon has no performance profile). CPU, RAPL, Wi-Fi, SATA and NVIDIA knobs need
# real hardware; the helper's unit tests cover them with sysfs fixtures.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
SNAPSHOT=post-fresh
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	*)
		echo "usage: power-test.sh [--snapshot NAME]" >&2
		exit 2
		;;
	esac
	shift
done

failures=0
ok() { printf '  ok: %s\n' "$*"; }
bad() {
	printf '  FAIL: %s\n' "$*"
	failures=$((failures + 1))
}
step() { printf '== %s\n' "$*"; }
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus;'
run() { "$VM" ssh "$SESSION $*"; }
HELPER=/usr/libexec/ubuntu-ostrich/system-helper

# One "name value" line per knob the VM has.
knobs() {
	run 'bash -s' <<'EOF'
sel() { sed -n 's/.*\[\(.*\)\].*/\1/p' "$1"; }
f=/sys/module/pcie_aspm/parameters/policy; [ -r $f ] && echo "aspm $(sel $f)"
f=/sys/module/snd_hda_intel/parameters/power_save; [ -r $f ] && echo "hda $(cat $f)"
for d in /sys/bus/usb/devices/*/; do
	[ -r "$d/power/control" ] && [ -r "$d/bInterfaceClass" -o -r "$d/bDeviceClass" ] || continue
	echo "usb:$(basename "$d") $(cat "$d/power/control")"
done
echo "nmi $(cat /proc/sys/kernel/nmi_watchdog)"
echo "writeback $(cat /proc/sys/vm/dirty_writeback_centisecs)"
echo "animations $(gsettings get org.gnome.desktop.interface enable-animations)"
echo "idle $(gsettings get org.gnome.desktop.session idle-delay | sed 's/uint32 //')"
EOF
}
val() { sed -n "s/^$1 //p" <<<"$2" | head -1; }
expect() { # name want state
	local got
	got=$(val "$1" "$3")
	if [[ -z $got ]]; then
		echo "  (no $1 in this VM)"
	elif [[ $got == "$2" ]]; then
		ok "$1 = $got"
	else
		bad "$1 = $got, want $2"
	fi
}
set_profile() {
	# As root: polkit lets only the active local session switch profiles, and SSH is not that.
	run "sudo powerprofilesctl set $1"
	sleep 6
}

step "start from $SNAPSHOT"
"$VM" stop
"$VM" snapshot restore "$SNAPSHOT"
"$VM" start
sleep 30
run "powerprofilesctl list" | sed 's/^/    /'
set_profile balanced
base=$(knobs)
while IFS= read -r l; do echo "    $l"; done <<<"$base"

step "power saver"
set_profile power-saver
s=$(knobs)
expect aspm powersupersave "$s"
expect hda 1 "$s"
expect nmi 0 "$s"
expect writeback 1500 "$s"
expect animations true "$s" # animations stay on in power saver (owner, 2026-11-01)
# Dims after 2 minutes, unless the screen never blanks (idle-delay 0): that choice is kept.
if [[ $(val idle "$base") == 0 ]]; then expect idle 0 "$s"; else expect idle 120 "$s"; fi
grep '^usb:' <<<"$s" | while IFS= read -r l; do echo "    $l (HID and audio devices stay on)"; done || true
run "journalctl --user -b -o cat /usr/bin/gnome-shell | grep -i 'power' | tail -3" | sed 's/^/    /' || true

step "balanced puts everything back"
set_profile balanced
b=$(knobs)
if [[ $b == "$base" ]]; then ok "all values as before"; else
	bad "values differ:"
	diff <(echo "$base") <(echo "$b") | sed 's/^/    /' || true
fi

step "performance"
if run "powerprofilesctl list" | grep -q performance; then
	set_profile performance
else
	echo "  (no performance profile in this VM: running the helper directly)"
	run "sudo $HELPER power apply performance" | sed 's/^/    /'
fi
p=$(knobs)
expect aspm performance "$p"
expect hda 0 "$p"
expect nmi "$(val nmi "$base")" "$p"
expect writeback "$(val writeback "$base")" "$p"
run "sudo $HELPER power apply balanced" >/dev/null
set_profile balanced
b=$(knobs)
if [[ $b == "$base" ]]; then ok "back to balanced: all values as before"; else
	bad "values differ after performance:"
	diff <(echo "$base") <(echo "$b") | sed 's/^/    /' || true
fi

step "locked screen: the monitor is off (nothing runs, no rule), and back at unlock (the low-battery rule is checked at every start)"
ext_state() { run "gnome-extensions info monitor@ubuntu-ostrich | sed -n 's/^ *State: //p'"; }
run "gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.Lock" >/dev/null
sleep 4
state=$(ext_state)
if [[ $state != ACTIVE ]]; then ok "locked: the monitor is $state, so nothing of ours runs"; else bad "locked: the monitor is still ACTIVE"; fi
run "gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.SetActive false" >/dev/null
sleep 5
state=$(ext_state)
if [[ $state == ACTIVE ]]; then ok "unlocked: the monitor is ACTIVE again"; else bad "unlocked: the monitor is $state"; fi

step "no JS errors"
n=$(run 'journalctl --user -b -o cat /usr/bin/gnome-shell | grep -c "JS ERROR" || true')
if [[ $n == 0 ]]; then ok "no JS errors"; else bad "$n JS errors"; fi

echo
if ((failures == 0)); then echo PASS; else echo "$failures FAILED"; fi
((failures == 0))
