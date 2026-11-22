#!/usr/bin/env bash
# tests/vm/release-suite.sh: the VM part of docs/RELEASING.md, one suite at a time (they share one VM).
#
#   release-suite.sh [--from N] [--only N[,N...]] [--snapshot NAME]     (default snapshot: try-me-0.4.0)
#
# 1. builds the tools (build-tools.sh --check) and installs this checkout's commit in a fresh VM from
#    'pre', saving it as the snapshot the suites run on (commit before running: the install is `git
#    archive HEAD`); 2. runs every suite on that snapshot; 3. the pipe-install round trips (what a user
#    types, then `ostrich uninstall`, each ending with the machine as it was). A failing suite doesn't
#    stop the run: each one's log goes to $VM_DIR/release-suite/N-name.log and the table at the end says
#    which failed. --from N / --only N resume or repeat steps by their number in that table.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ostrich-os/vm}"
OUT="$VM_DIR/release-suite"
SNAP=try-me-0.4.0
FROM=1
ONLY=""
while (($# > 0)); do
	case $1 in
	--from) FROM=$2 && shift ;;
	--only) ONLY=$2 && shift ;;
	--snapshot) SNAP=$2 && shift ;;
	*)
		echo "usage: release-suite.sh [--from N] [--only N[,N...]] [--snapshot NAME]" >&2
		exit 2
		;;
	esac
	shift
done

EXTENSIONS=(blur dock drawer focus holder-monitor monitor search-new-window tiling tray tweaks workspaces)
# name | command (run from the repo root)
STEPS=(
	"build|tests/vm/build-tools.sh --check"
	"install|tests/vm/e2e.sh --from pre $SNAP"
	"extensions|tests/vm/ext-test.sh --snapshot $SNAP ${EXTENSIONS[*]}"
	"drawer|tests/vm/drawer-test.sh --snapshot $SNAP"
	"polkit|tests/vm/polkit-test.sh --snapshot $SNAP"
	"dconf|tests/vm/dconf-test.sh --snapshot $SNAP"
	"store|tests/vm/store-test.sh --snapshot $SNAP"
	"motion|tests/vm/motion-test.sh --snapshot $SNAP"
	"nowplaying|tests/vm/nowplaying-test.sh --snapshot $SNAP"
	"bluetooth|tests/vm/bluetooth-test.sh --snapshot $SNAP"
	"topbar|tests/vm/topbar-test.sh --snapshot $SNAP"
	"powerrow|tests/vm/powerrow-test.sh --snapshot $SNAP"
	"quiet|tests/vm/quiet-test.sh --snapshot $SNAP"
	"blur|tests/vm/blur-test.sh --snapshot $SNAP"
	"env|tests/vm/env-test.sh --snapshot $SNAP"
	"power|tests/vm/power-test.sh --snapshot $SNAP"
	"look|tests/look-check.sh --vm $SNAP"
	"ui|tests/vm/ui-test.sh"
	"standalone|tests/vm/standalone-test.sh"
	"pipe|tests/vm/e2e.sh --pipe --from pre --uninstall"
	"pipe-keep|tests/vm/e2e.sh --pipe --from pre --mode keep --uninstall"
	"pipe-clean|tests/vm/e2e.sh --pipe --from pre --mode clean --uninstall"
)

mkdir -p "$OUT"
cd "$ROOT" || exit 1
if ! git diff --quiet || ! git diff --cached --quiet; then
	echo "release-suite: commit first (the install is the committed tree)" >&2
	exit 1
fi
results=()
n=0
for step in "${STEPS[@]}"; do
	n=$((n + 1))
	name=${step%%|*}
	cmd=${step#*|}
	if [[ -n $ONLY ]]; then
		[[ ,$ONLY, == *,$n,* ]] || continue
	elif ((n < FROM)); then
		continue
	fi
	log="$OUT/$n-$name.log"
	printf '[release-suite] %d %s: %s\n' "$n" "$name" "$cmd" >&2
	"$VM" stop >/dev/null 2>&1 || true
	start=$(date +%s)
	if bash -c "$cmd" >"$log" 2>&1; then verdict=PASS; else verdict=FAIL; fi
	results+=("$(printf '%2d  %-11s %-5s %4d s  %s' "$n" "$name" "$verdict" $(($(date +%s) - start)) "$log")")
	printf '[release-suite] %d %s %s\n' "$n" "$name" "$verdict" >&2
	# Without the tools or the install the rest has nothing to run on.
	if [[ $verdict == FAIL && ($name == build || $name == install) ]]; then
		echo "[release-suite] $name failed: stopping" >&2
		break
	fi
done
"$VM" stop >/dev/null 2>&1 || true
printf '\n%s\n' "${results[@]}" | tee "$OUT/summary.txt"
! printf '%s\n' "${results[@]}" | grep -q ' FAIL '
