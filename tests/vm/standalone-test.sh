#!/usr/bin/env bash
# tests/vm/standalone-test.sh: the extensions we publish on their own (blur, workspaces, monitor), each
# installed alone on a clean Ubuntu (snapshot 'stock'), as a user of extensions.gnome.org would have it.
#
#   standalone-test.sh [--snapshot NAME] [name...]     (default: stock; all three)
#
# For each one: ext-test.sh (ACTIVE, no JS error, 2 x 20 disable/enable cycles), three more rounds of 20
# cycles whose last round must grow gnome-shell by under STEADY_MB (the first rounds only warm caches up:
# blur grew 23, 0, 2, 2 and 1 MB over five rounds on stock, so ext-test's second-round limit is widened
# here and the steady state is what is judged), the journal gate, and the extension's own preferences
# window: it opens (most of the area where the window appears changes; for the monitor, through the
# popup's own Monitor settings button, which has no Ostrich Settings to open on a stock machine). Screenshots go to $VM_DIR/standalone-test.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/vm/journal-gate.sh
source "$HERE/journal-gate.sh"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ubuntu-ostrich/vm}"
OUT="$VM_DIR/standalone-test"
SNAPSHOT=stock
STEADY_MB="${STEADY_MB:-8}"
PREFS_BOX="${PREFS_BOX:-680,270,1310,840}" # where the preferences window opens
names=()
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	-*)
		echo "usage: standalone-test.sh [--snapshot NAME] [name...]" >&2
		exit 2
		;;
	*) names+=("$1") ;;
	esac
	shift
done
((${#names[@]} > 0)) || names=(blur workspaces monitor)

failures=0
ok() { printf '  ok: %s\n' "$*"; }
bad() {
	printf '  FAIL: %s\n' "$*"
	failures=$((failures + 1))
}
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0;'
run() { "$VM" ssh "$SESSION $*"; }
tree() { run "python3 - $*" <"$HERE/a11y-tree.py"; }
# shellcheck disable=SC2016 # expands in the VM
rss_kb() { "$VM" ssh 'awk "/^VmRSS:/{print \$2}" /proc/$(pgrep -u $(id -u) -x gnome-shell | head -1)/status'; }
changed_share() { # before.png after.png x0,y0,x1,y1: the percent of that box's pixels that differ clearly
	python3 -I - "$@" <<'PYEND'
import sys
from PIL import Image, ImageChops
box = tuple(int(v) for v in sys.argv[3].split(","))
a, b = (Image.open(p).convert("L").crop(box) for p in sys.argv[1:3])
diff = ImageChops.difference(a, b).point(lambda v: 255 if v > 20 else 0)
print(round(100 * sum(1 for v in diff.get_flattened_data() if v) / (diff.width * diff.height)))
PYEND
}

rm -rf "$OUT"
mkdir -p "$OUT"
trap '"$VM" stop >/dev/null 2>&1 || true' EXIT
for n in "${names[@]}"; do
	echo "== $n alone on $SNAPSHOT"
	"$VM" stop >/dev/null 2>&1 || true
	if RSS_LIMIT_MB="${RSS_LIMIT_MB:-30}" "$HERE/ext-test.sh" --snapshot "$SNAPSHOT" --cycles 20 "$n" >&2; then
		ok "$n: ACTIVE, no JS error, 40 cycles"
	else
		bad "$n: ext-test failed"
		continue
	fi
	run "gsettings set org.gnome.desktop.session idle-delay 0"
	prev=$(rss_kb)
	for _ in 1 2 3; do
		run "for i in \$(seq 20); do gnome-extensions disable $n@ubuntu-ostrich; sleep 0.4; gnome-extensions enable $n@ubuntu-ostrich; sleep 0.4; done"
		sleep 3
		now=$(rss_kb)
		grew=$(((now - prev) / 1024))
		prev=$now
	done
	if ((grew < STEADY_MB)); then ok "$n: steady state grows $grew MB per 20 cycles"; else bad "$n: still grows $grew MB per 20 cycles after 100 (limit $STEADY_MB)"; fi
	"$VM" move 960 900 >/dev/null
	"$VM" screenshot "$OUT/$n-before.png" >/dev/null
	if [[ $n == monitor ]]; then
		# Its popup's "Monitor settings" button, with no Ostrich Settings on this machine: it opens the
		# extension's own preferences window.
		read -r px py < <(tree where Monitor)
		"$VM" click "$px" "$py"
		sleep 3
		read -r bx by < <(tree showing "'Monitor settings'")
		"$VM" click "$bx" "$by"
	else
		run "setsid -f gnome-extensions prefs $n@ubuntu-ostrich >/dev/null 2>&1"
	fi
	sleep 6
	"$VM" screenshot "$OUT/$n-prefs.png" >/dev/null
	share=$(changed_share "$OUT/$n-before.png" "$OUT/$n-prefs.png" "$PREFS_BOX")
	if ((share >= 40)); then ok "$n: the preferences window opens ($share % of its area changed)"; else bad "$n: the preferences window did not open ($share % changed)"; fi
	journal_gate
done

if ((failures > 0)); then
	echo "FAIL: $failures problem(s); screenshots in $OUT"
	exit 1
fi
echo "PASS (screenshots in $OUT)"
