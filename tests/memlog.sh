#!/usr/bin/env bash
# tests/memlog.sh: what fills the memory over days. Read-only: every INTERVAL seconds it appends one
# line per app (all of an app's processes together, e.g. a browser and its tabs) to a file, and
# changes nothing else. Runs on any machine, Ostrich installed or not.
#
#   tests/memlog.sh [INTERVAL]   log every INTERVAL s (default 600) until stopped (Ctrl+C, or kill)
#   tests/memlog.sh --summary    which apps grew most between the first and the last sample
#
# File: ~/.local/share/ostrich-os/memlog.tsv (time, app, memory MB, swap MB; "_system" is the
# machine's used memory and swap).
set -euo pipefail

LOG="${MEMLOG:-${XDG_DATA_HOME:-$HOME/.local/share}/ostrich-os/memlog.tsv}"

# The app a process belongs to, from its systemd unit: app-gnome-firefox_firefox-1234.scope -> firefox_firefox.
app_of() {
	local unit
	unit=$(sed -n 's|^0::.*/||p' "/proc/$1/cgroup" 2>/dev/null) || return 1
	unit=${unit%.scope}
	unit=${unit%.service}
	unit=${unit#app-}
	unit=${unit#gnome-}
	unit=${unit#flatpak-}
	unit=${unit#snap.}
	unit=$(sed -E 's/-[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$//; s/-[0-9]+$//; s/@[0-9]+$//; s/\\x2d/-/g' <<<"$unit")
	echo "${unit:-other}"
}

sample() {
	local now pid app line
	now=$(date '+%Y-%m-%dT%H:%M')
	declare -A pss=() swap=()
	for pid in /proc/[0-9]*; do
		pid=${pid#/proc/}
		[[ -r /proc/$pid/smaps_rollup ]] || continue
		app=$(app_of "$pid") || continue
		line=$(awk '/^Pss:/{p=$2} /^Swap:/{s=$2} END{print p+0, s+0}' "/proc/$pid/smaps_rollup" 2>/dev/null) || continue
		pss[$app]=$((${pss[$app]:-0} + ${line% *}))
		swap[$app]=$((${swap[$app]:-0} + ${line#* }))
	done
	{
		awk -v t="$now" '/^MemTotal:/{mt=$2} /^MemAvailable:/{ma=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
			END{printf "%s\t_system\t%d\t%d\n", t, (mt-ma)/1024, (st-sf)/1024}' /proc/meminfo
		for app in "${!pss[@]}"; do
			((pss[$app] + swap[$app] >= 20480)) || continue # 20 MB and up
			printf '%s\t%s\t%d\t%d\n' "$now" "$app" $((pss[$app] / 1024)) $((swap[$app] / 1024))
		done
	} >>"$LOG"
}

summary() {
	[[ -s $LOG ]] || {
		echo "nothing logged yet in $LOG" >&2
		exit 1
	}
	awk -F'\t' '
		!($2 in first) {first[$2] = $3 + $4; t0[$2] = $1}
		{last[$2] = $3 + $4; t1[$2] = $1}
		END {
			for (a in last) printf "%+7d MB  %6d -> %6d MB  %s (%s to %s)\n", last[a] - first[a], first[a], last[a], a, t0[a], t1[a]
		}' "$LOG" | sort -rn | head -20
}

case ${1:-} in
--summary) summary ;;
-h | --help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' ;;
*)
	interval=${1:-600}
	mkdir -p "$(dirname "$LOG")"
	echo "logging memory per app every ${interval}s to $LOG (Ctrl+C to stop; --summary to read)" >&2
	while :; do
		sample
		sleep "$interval"
	done
	;;
esac
