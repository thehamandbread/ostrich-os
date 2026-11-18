#!/usr/bin/env bash
# tests/vm/polkit-test.sh: the system helper's polkit actions in the test VM. From the desktop
# session, as any app could, applying a power mode and the touchscreen run with no prompt (so the
# switch to power saver at low battery never stops at a password); changing the graphics mode
# asks for a password, and cancelling it changes nothing.
#
#   polkit-test.sh [--snapshot NAME] [--out DIR]     (default: post-fresh, $VM_DIR/polkit-test)
#
# This checkout's policy is installed over the snapshot's before the checks.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ubuntu-ostrich/vm}"
SNAPSHOT=post-fresh
OUT="$VM_DIR/polkit-test"
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	--out) OUT=$2 && shift ;;
	*)
		echo "usage: polkit-test.sh [--snapshot NAME] [--out DIR]" >&2
		exit 2
		;;
	esac
	shift
done
mkdir -p "$OUT"
HELPER=/usr/libexec/ubuntu-ostrich/system-helper
POLICY=org.ubuntu-ostrich.system-helper.policy

failures=0
ok() { printf '  ok: %s\n' "$*"; }
bad() {
	printf '  FAIL: %s\n' "$*"
	failures=$((failures + 1))
}
step() { printf '== %s\n' "$*"; }
shot() { "$VM" screenshot "$OUT/$1.png" >/dev/null; }
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus;'
run() { "$VM" ssh "$SESSION $*"; }
# A command started inside the desktop session (a transient user unit), as an app would; prints its
# exit status. Times out after $2 seconds (a prompt nobody answers).
in_session() { # command timeout
	run "timeout $2 systemd-run --user --wait --pipe --quiet $1 >/dev/null 2>&1; echo \$?"
}

step "start from $SNAPSHOT with this checkout's policy"
"$VM" stop
"$VM" snapshot restore "$SNAPSHOT"
"$VM" start
sleep 40
"$VM" copy "$ROOT/modules/hardware/$POLICY" "/tmp/$POLICY"
"$VM" ssh "sudo install -m 0644 /tmp/$POLICY /usr/share/polkit-1/actions/$POLICY && sudo systemctl restart polkit"
"$VM" ssh "[ -x $HELPER ]" || {
	echo "the helper isn't installed in $SNAPSHOT" >&2
	exit 1
}
run "pkaction | grep ubuntu-ostrich" | sed 's/^/    /'

step "no prompt: power and the touchscreen"
rc=$(in_session "pkexec $HELPER power apply balanced" 20)
if [[ $rc == 0 ]]; then ok "power apply ran with no prompt"; else bad "power apply: exit $rc"; fi
rc=$(in_session "pkexec $HELPER touchscreen status" 20)
if [[ $rc == 0 ]]; then ok "touchscreen ran with no prompt"; else bad "touchscreen: exit $rc"; fi

step "a password for the graphics mode"
"$VM" move 960 900
sleep 1
shot 1-before
run "setsid -f sh -c 'systemd-run --user --wait --pipe --quiet pkexec $HELPER graphics set hybrid >/dev/null 2>&1; echo \$? > /tmp/graphics-rc' </dev/null >/dev/null 2>&1"
sleep 6
shot 2-prompt
diff=$(
	python3 -I - "$OUT/1-before.png" "$OUT/2-prompt.png" <<'EOF'
import sys
from PIL import Image, ImageChops, ImageStat
a, b = (Image.open(p).convert("L") for p in sys.argv[1:3])
box = (a.width // 4, a.height // 4, 3 * a.width // 4, 3 * a.height // 4)  # the dialog is centred
print(round(ImageStat.Stat(ImageChops.difference(a.crop(box), b.crop(box))).mean[0], 1))
EOF
)
if python3 -I -c "import sys; sys.exit(0 if float('$diff') > 10 else 1)"; then
	ok "a password dialog came up (diff $diff)"
else
	bad "no password dialog in the middle of the screen (diff $diff)"
fi
"$VM" key esc
sleep 4
shot 3-cancelled
rc=$(run "cat /tmp/graphics-rc 2>/dev/null || echo none")
if [[ $rc != 0 && $rc != none ]]; then ok "cancelling it changed nothing (exit $rc)"; else bad "graphics set after cancel: exit $rc"; fi

"$VM" stop
echo "screenshots in $OUT"
if ((failures)); then
	echo "polkit-test: $failures failed"
	exit 1
fi
echo "polkit-test: all passed"
