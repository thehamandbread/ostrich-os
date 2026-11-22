#!/usr/bin/env bash
# tests/vm/shell-bench.sh: gnome-shell CPU under a scripted workload, in the running test VM.
#
#   shell-bench.sh <workload> [seconds] [runs]
#
# Workloads:
#   idle      nothing happens
#   overview  open/close the overview every 1.5 s (Super key via the QEMU monitor)
#   drawer    open/close the drawer every 1.5 s (Super+Alt+D; council experiment E2: its slide
#             should cost no more than the overview's)
#
# Prints one line per run: "<workload> run=<n> shell_cpu_pct=<x>", then the median.
# The guest renders with llvmpipe, so compositing/blur work shows up as gnome-shell CPU.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
PROJECT="ostrich-os"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
MONITOR="$VM_DIR/monitor.sock"

WORKLOAD=${1:-}
SECONDS_PER_RUN=${2:-60}
RUNS=${3:-3}

die() {
	printf '[bench] ERROR: %s\n' "$*" >&2
	exit 1
}
[[ $WORKLOAD == idle || $WORKLOAD == overview || $WORKLOAD == drawer ]] || die "usage: shell-bench.sh idle|overview|drawer [seconds] [runs]"
[[ -S $MONITOR ]] || die "VM is not running"

sendkey() { printf 'sendkey %s\n' "$1" | socat -t 0.2 - "UNIX-CONNECT:$MONITOR" >/dev/null; }

# Prints "<gnome-shell utime+stime ticks> <CLK_TCK>".
shell_ticks() {
	# Expands inside the VM.
	# shellcheck disable=SC2016
	"$VM" ssh 'pid=$(pgrep -u "$(id -u)" -x gnome-shell | head -1); awk "{print \$14 + \$15}" /proc/$pid/stat; getconf CLK_TCK' | paste -sd' '
}

results=()
for ((run = 1; run <= RUNS; run++)); do
	read -r t0 hz < <(shell_ticks)
	start=$(date +%s.%N)
	if [[ $WORKLOAD == overview || $WORKLOAD == drawer ]]; then
		key=meta_l
		[[ $WORKLOAD == drawer ]] && key=meta_l-alt-d
		end=$(($(date +%s) + SECONDS_PER_RUN))
		while (($(date +%s) < end)); do
			sendkey "$key"
			sleep 1.5
		done
		# Leave it closed: an even number of presses isn't guaranteed.
		sendkey esc
	else
		sleep "$SECONDS_PER_RUN"
	fi
	read -r t1 _ < <(shell_ticks)
	elapsed=$(awk -v s="$start" -v e="$(date +%s.%N)" 'BEGIN { print e - s }')
	pct=$(awk -v d=$((t1 - t0)) -v hz="$hz" -v w="$elapsed" 'BEGIN { printf "%.2f", 100 * d / hz / w }')
	results+=("$pct")
	echo "$WORKLOAD run=$run shell_cpu_pct=$pct"
	sleep 5
done
printf '%s\n' "${results[@]}" | sort -g | awk -v w="$WORKLOAD" '{ v[NR] = $1 } END { printf "%s median shell_cpu_pct=%s\n", w, v[int((NR + 1) / 2)] }'
