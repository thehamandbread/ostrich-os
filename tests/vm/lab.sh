#!/usr/bin/env bash
# tests/vm/lab.sh: throwaway copies of the try-me VM for the design council's seats to explore in.
# Two lab slots can run at once, next to (never instead of) the main test VM: each boots its own
# overlay on a copy of try-me, so nothing a seat does there reaches try-me or the main disk, and
# releasing a slot throws everything it changed away. Lab VMs have no sound on the host.
#
#   lab.sh base [SNAPSHOT]         copy try-me (or SNAPSHOT, remembered for later books) into the lab
#   lab.sh book SEAT               take a free slot (waits while both are busy); prints its number
#   lab.sh N ssh 'command'         run a command in slot N's desktop session (as the test user)
#   lab.sh N shot FILE.png         a screenshot of slot N
#   lab.sh N click|move|key|scroll|drag ARGS...   input, as vm.sh takes it
#   lab.sh N reset                 back to fresh try-me (throws away what was changed)
#   lab.sh N release               stop slot N and throw it away
#   lab.sh status                  who holds which slot
#
# Seats use this script only; they never run vm.sh or touch the main VM. Screenshots belong under
# the debate's evidence/lab/<seat>/ folder.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ostrich-os/vm}"
LAB="${LAB_DIR:-$VM_DIR/lab}" # LAB_DIR: a second lab (e.g. a stock-based one) next to the first
SLOTS=2
SNAPSHOT=$(cat "$LAB/snapshot" 2>/dev/null || echo try-me) # set by lab.sh base SNAPSHOT
MIN_FREE_GB=5
STALE_MIN=180 # a booking older than this is taken back (a seat that never released)

die() {
	echo "lab: $*" >&2
	exit 1
}
log() { echo "[lab] $*" >&2; }

# When try-me was saved, read in shared mode (-U), so it works while the main VM is running.
saved_at() {
	qemu-img info -U --output=json "$VM_DIR/disk.qcow2" 2>/dev/null |
		python3 -I -c 'import json, sys; print(next((str(s["date-sec"]) for s in json.load(sys.stdin).get("snapshots", []) if s["name"] == sys.argv[1]), ""))' "$SNAPSHOT"
}
free_gb() { df --output=avail -BG "$VM_DIR" | tail -1 | tr -dc '0-9'; }

cmd_base() {
	mkdir -p "$LAB"
	local stamp
	stamp=$(saved_at)
	[[ -n $stamp ]] || die "there's no $SNAPSHOT snapshot (tests/vm/e2e.sh --from pre try-me makes it)"
	if [[ -f $LAB/base.qcow2 && $(cat "$LAB/base.stamp" 2>/dev/null) == "$stamp" ]]; then
		return 0
	fi
	# A new base replaces the old one: no slot may be running on it.
	local n
	for ((n = 1; n <= SLOTS; n++)); do
		[[ -d $LAB/slot$n.busy ]] && die "slot $n is in use; release it before try-me's copy is renewed"
	done
	rm -f "$LAB/base.qcow2" "$LAB/base.stamp" # the old copy is stale; its space goes to the new one
	(($(free_gb) >= MIN_FREE_GB + 12)) || die "not enough disk for the copy of $SNAPSHOT (need about $((MIN_FREE_GB + 12)) GB free)"
	log "copying $SNAPSHOT into the lab (a few minutes, once per try-me)"
	# -U: read while the main VM may be running; a saved snapshot doesn't change under it.
	qemu-img convert -U -O qcow2 -l "snapshot.name=$SNAPSHOT" "$VM_DIR/disk.qcow2" "$LAB/base.qcow2.tmp"
	mv "$LAB/base.qcow2.tmp" "$LAB/base.qcow2"
	echo "$stamp" >"$LAB/base.stamp"
}

slot_dir() { echo "$LAB/slot$1"; }
vm_in() { # slot vm.sh-args...: vm.sh on that slot (its own folder and SSH port, 5 GB, silent)
	local n=$1
	shift
	VM_DIR="$(slot_dir "$n")" VM_SSH_PORT=$((2230 + n)) VM_MEM=5G VM_AUDIO=0 "$VM" "$@"
}

prepare() { # slot: a fresh overlay on the base, and the keys and firmware vars the VM needs
	local n=$1 d
	d=$(slot_dir "$n")
	vm_in "$n" stop >/dev/null 2>&1 || true
	rm -rf "$d"
	mkdir -p "$d"
	qemu-img create -q -f qcow2 -b "$LAB/base.qcow2" -F qcow2 "$d/disk.qcow2"
	cp "$VM_DIR/OVMF_VARS.fd" "$VM_DIR/id_ed25519" "$VM_DIR/id_ed25519.pub" "$d/"
	[[ -f $VM_DIR/known_hosts ]] && cp "$VM_DIR/known_hosts" "$d/"
	vm_in "$n" start >/dev/null
	# Past the start-up window, and no screen lock while a seat looks around.
	sleep 20
	run_in "$n" "gsettings set org.gnome.desktop.session idle-delay 0; gsettings set org.gnome.desktop.screensaver lock-enabled false; pkill -x ostrich-setup; true" >/dev/null
}

# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0;'
run_in() { vm_in "$1" ssh "$SESSION $2"; }

cmd_book() {
	local seat=${1:?usage: lab.sh book SEAT}
	[[ $seat =~ ^[a-z0-9-]+$ ]] || die "a seat name is lower-case letters, digits and dashes"
	(($(free_gb) >= MIN_FREE_GB)) || die "less than $MIN_FREE_GB GB of disk free; not starting a lab VM"
	cmd_base
	local n busy waited=0
	while true; do
		for ((n = 1; n <= SLOTS; n++)); do
			busy="$LAB/slot$n.busy"
			if [[ -d $busy ]] && [[ -n $(find "$busy" -maxdepth 0 -mmin +$STALE_MIN) ]]; then
				log "slot $n was booked by $(cat "$busy/seat" 2>/dev/null) over $STALE_MIN minutes ago; taking it back"
				vm_in "$n" stop >/dev/null 2>&1 || true
				rm -rf "$busy"
			fi
			if mkdir "$busy" 2>/dev/null; then
				echo "$seat" >"$busy/seat"
				log "slot $n booked for $seat; starting it (about a minute)"
				if ! prepare "$n"; then
					rm -rf "$busy"
					die "slot $n didn't start"
				fi
				echo "$n"
				return 0
			fi
		done
		((waited % 60 == 0)) && log "both slots are busy ($(cat "$LAB"/slot*.busy/seat 2>/dev/null | paste -sd' ')); waiting"
		sleep 10
		waited=$((waited + 10))
		((waited < 3600)) || die "no slot came free in an hour"
	done
}

cmd_release() {
	local n=$1
	vm_in "$n" stop >/dev/null 2>&1 || true
	rm -rf "$(slot_dir "$n")" "$LAB/slot$n.busy"
	log "slot $n released"
}

cmd_status() {
	local n
	for ((n = 1; n <= SLOTS; n++)); do
		if [[ -d $LAB/slot$n.busy ]]; then
			echo "slot $n: $(cat "$LAB/slot$n.busy/seat" 2>/dev/null)"
		else
			echo "slot $n: free"
		fi
	done
	echo "base: $(cat "$LAB/base.stamp" 2>/dev/null || echo none) ($SNAPSHOT saved $(saved_at))"
}

case ${1:-} in
base)
	if [[ -n ${2:-} ]]; then
		SNAPSHOT=$2
		mkdir -p "$LAB" && echo "$SNAPSHOT" >"$LAB/snapshot"
	fi
	cmd_base
	;;
book) cmd_book "${2:-}" ;;
status) cmd_status ;;
[1-9])
	n=$1
	((n <= SLOTS)) || die "there are $SLOTS slots"
	[[ -d $LAB/slot$n.busy ]] || die "slot $n isn't booked (lab.sh book SEAT)"
	touch "$LAB/slot$n.busy" # still in use
	verb=${2:-}
	shift 2 || true
	case $verb in
	ssh) run_in "$n" "$*" ;;
	shot)
		mkdir -p "$(dirname "${1:?usage: lab.sh N shot FILE.png}")"
		vm_in "$n" screenshot "$1"
		;;
	click | move | key | scroll | drag | nudge) vm_in "$n" "$verb" "$@" ;;
	reset) prepare "$n" && log "slot $n is fresh try-me again" ;;
	release) cmd_release "$n" ;;
	*) die "slot commands: ssh, shot, click, move, key, scroll, drag, nudge, reset, release" ;;
	esac
	;;
*)
	sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
	;;
esac
