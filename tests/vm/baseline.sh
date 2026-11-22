#!/usr/bin/env bash
# tests/vm/baseline.sh: run measure.sh in the test VM and compare snapshots.
#
#   baseline.sh run <label> [runs]     restore snapshot <label>, boot, measure <runs> times (default 3)
#   baseline.sh report <a> <b>         markdown table of medians, <a> vs <b>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
PROJECT="ostrich-os"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
RESULTS="$VM_DIR/results"

METRICS=(shell_cpu_pct shell_ctxsw_per_s shell_rss_mb shell_pss_mb mem_used_mb wakeups_per_s shell_wakeups_per_s
	processes system_services user_services squashfs_mounts extensions_enabled extensions_active boot_s)

log() { printf '[baseline] %s\n' "$*" >&2; }
die() {
	log "ERROR: $*"
	exit 1
}

cmd_run() {
	local label=${1:-} runs=${2:-3} i
	[[ $label =~ ^[A-Za-z0-9._-]+$ ]] || die "usage: baseline.sh run <label> [runs]"
	mkdir -p "$RESULTS"
	rm -f "$RESULTS/$label".run* # a fresh set: older runs would skew the medians
	"$VM" stop
	"$VM" snapshot restore "$label"
	"$VM" start
	"$VM" copy "$HERE/measure.sh" /tmp/measure.sh
	{
		printf 'host_cpu=%s\n' "$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo)"
		printf 'host_load_start=%s\n' "$(cut -d' ' -f1 /proc/loadavg)"
		printf 'date=%s\n' "$(date -u +%Y-%m-%dT%H:%MZ)"
	} >"$RESULTS/$label.meta"
	for ((i = 1; i <= runs; i++)); do
		log "$label: run $i/$runs (about 7 minutes)"
		"$VM" ssh 'bash /tmp/measure.sh' >"$RESULTS/$label.run$i"
	done
	printf 'host_load_end=%s\n' "$(cut -d' ' -f1 /proc/loadavg)" >>"$RESULTS/$label.meta"
	"$VM" stop
	log "results in $RESULTS/$label.run*"
}

# Median of a metric across a label's runs; "na" if absent.
median() {
	local label=$1 key=$2
	cat "$RESULTS/$label".run* 2>/dev/null | awk -F= -v k="$key" '$1 == k && $2 != "na" { print $2 }' |
		sort -g | awk '{ v[NR] = $1 } END { if (!NR) print "na"; else if (NR % 2) print v[(NR + 1) / 2]; else print (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}

cmd_report() {
	local a=${1:-} b=${2:-} m va vb
	[[ -n $a && -n $b ]] || die "usage: baseline.sh report <a> <b>"
	printf '| Metric | %s | %s | Change |\n|---|---|---|---|\n' "$a" "$b"
	for m in "${METRICS[@]}"; do
		va=$(median "$a" "$m")
		vb=$(median "$b" "$m")
		awk -v m="$m" -v a="$va" -v b="$vb" 'BEGIN {
			c = (a == "na" || b == "na" || a + 0 == 0) ? "" : sprintf("%+.0f%%", 100 * (b - a) / a)
			printf "| %s | %s | %s | %s |\n", m, a, b, c }'
	done
}

case ${1:-} in
run) shift && cmd_run "$@" ;;
report) shift && cmd_report "$@" ;;
*) die "usage: baseline.sh run <label> [runs] | report <a> <b>" ;;
esac
