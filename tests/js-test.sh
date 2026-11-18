#!/usr/bin/env bash
# tests/js-test.sh: run the gjs unit tests (pure extension modules, no GNOME Shell needed).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v gjs >/dev/null 2>&1 || {
	echo "gjs not found (apt install gjs)" >&2
	exit 1
}
status=0
for t in "$ROOT"/tests/js/*.test.js; do
	echo "# $(basename "$t")"
	gjs -m "$t" || status=1
done
exit "$status"
