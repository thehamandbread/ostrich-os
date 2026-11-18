#!/usr/bin/env bash
# tests/look-check.sh: the look's checks in one command (council 2026-11-05, M7).
#
#   look-check.sh [--vm SNAPSHOT]
#
# Always: the look lint (.claude/skills/ostrich-design/scripts/token-lint.sh): sizes that have a token,
# fixed colours, a :focus rule on every button class, dim-label. It is the one CI runs.
# With --vm SNAPSHOT (a VM snapshot with the Ostrich desktop, e.g. try-me): the VM tests that look at
# the real shell, each of which also fails on a JS error or a warning from our code in the journal:
#   monitor-look-test.sh  focus rings, one popup width, the cap on an open section, visible names
#   text-scale-test.sh    the clock menu and the monitor at 100 % and 200 % text
#   alert-test.sh         the pop-out alert and its confirm question
#   a11y-test.sh          what a screen reader hears
#   qs-contrast-test.sh   text on lit quick-settings tiles at 4.5:1 over a photo (dark, light, saver)
# CI runners have no VM, so only the lint runs there. Not covered by any of them: text contrast over
# glass in light, dark and high contrast (tests/vm/contrast.sh needs boxes drawn on screenshots: run it
# on the shots in $VM_DIR/monitor-look-test and text-scale-test when a colour or tint changes).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SNAPSHOT=""
while (($# > 0)); do
	case $1 in
	--vm) SNAPSHOT=${2:?--vm needs a snapshot name} && shift ;;
	*)
		echo "usage: look-check.sh [--vm SNAPSHOT]" >&2
		exit 2
		;;
	esac
	shift
done

failed=()
run() { # name command...
	local name=$1
	shift
	printf '\n######## %s\n' "$name"
	if "$@"; then echo "-> $name: ok"; else
		echo "-> $name: FAILED"
		failed+=("$name")
	fi
}

run "look lint" "$ROOT/.claude/skills/ostrich-design/scripts/token-lint.sh" "$ROOT"
if [[ -n $SNAPSHOT ]]; then
	for t in monitor-look-test text-scale-test alert-test a11y-test qs-contrast-test; do
		run "$t" "$HERE/vm/$t.sh" --snapshot "$SNAPSHOT"
	done
else
	echo
	echo "(the VM tests were not run: pass --vm SNAPSHOT)"
fi

echo
if ((${#failed[@]} > 0)); then
	echo "FAILED: ${failed[*]}"
	exit 1
fi
echo "look-check: all passed"
