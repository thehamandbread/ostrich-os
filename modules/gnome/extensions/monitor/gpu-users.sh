#!/bin/sh
# Ported from the user-authored nvidia-power extension (SPDX-License-Identifier: GPL-2.0-or-later).
# Lists the processes holding the NVIDIA GPU open, one "pid<TAB>comm<TAB>cgroup" line each.
# Arguments: the device paths to look for (find -lname globs). Reading /proc never wakes the GPU.

n=$#
for node in "$@"; do
	set -- "$@" -o -lname "$node"
done
shift "$n"

find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 \( -false "$@" \) 2>/dev/null |
	cut -d/ -f3 | sort -un |
	while read -r pid; do
		comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
		cgroup=$(head -n1 "/proc/$pid/cgroup" 2>/dev/null | cut -d: -f3)
		printf '%s\t%s\t%s\n' "$pid" "$comm" "$cgroup"
	done
