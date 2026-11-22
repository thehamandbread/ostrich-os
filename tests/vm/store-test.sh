#!/usr/bin/env bash
# tests/vm/store-test.sh: Ostrich Store's window in a fresh install. The installer fetched Flathub's
# app list; the store opens on Explore; a search lists apps; an app page opens (screenshots, size,
# permissions come from the network); the window stays up and logs no errors. Nothing is installed.
#
#   store-test.sh [--snapshot NAME] [--out DIR]      (default: post-fresh, $VM_DIR/store-test)
#
# Read the screenshots too: what the page looks like isn't checked here.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
PROJECT="ostrich-os"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
SNAPSHOT=post-fresh
OUT="$VM_DIR/store-test"
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	--out) OUT=$2 && shift ;;
	*)
		echo "usage: store-test.sh [--snapshot NAME] [--out DIR]" >&2
		exit 2
		;;
	esac
	shift
done

failures=0
ok() { echo "  ok: $*"; }
bad() {
	echo "  FAIL: $*"
	failures=$((failures + 1))
}
step() { printf '== %s\n' "$*"; }
shot() { "$VM" screenshot "$OUT/$1.png" >/dev/null; }
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0;'
run() { "$VM" ssh "$SESSION $*"; }
# The kernel keeps 15 characters of a program's name; -f would also match this very ssh command.
alive() { run "pgrep -x ostrich-store-g >/dev/null"; }

rm -rf "$OUT"
mkdir -p "$OUT"

step "start from $SNAPSHOT"
"$VM" stop
"$VM" snapshot restore "$SNAPSHOT"
"$VM" start
sleep 40
run "pkill -x ostrich-setup; true" # the first-login tour
sleep 2
# This checkout's store, if one was built (build-tools.sh), over the installed one.
if [[ -x $VM_DIR/tools-bin/ostrich-store-gtk ]]; then
	"$VM" copy "$VM_DIR/tools-bin/ostrich-store-gtk" /tmp/ostrich-store-gtk
	run "install -m755 /tmp/ostrich-store-gtk ~/.local/libexec/ostrich-os/ostrich-store-gtk"
fi

step "the installer fetched Flathub's app list"
if run "test -e /var/lib/flatpak/appstream/flathub/\$(uname -m)/active"; then ok "catalogue on disk"; else bad "no Flathub catalogue: the store would only offer to download it"; fi

step "Explore"
run "setsid -f ~/.local/libexec/ostrich-os/ostrich-store-gtk </dev/null >/tmp/store.log 2>&1"
sleep 12
shot 1-explore
if alive; then ok "the window is up"; else bad "the store exited at start"; fi

step "search as you type"
"$VM" key v l c
sleep 3
shot 2-search
if alive; then ok "still up after a search"; else bad "the store exited on a search"; fi

step "an app page (the first result)"
# The results list starts under the search field; the first row is about 150 px below the top
# of the window's content (1040 x 760, centred).
"$VM" click 960 "${STORE_ROW_Y:-330}"
sleep 10
shot 3-app
if alive; then ok "still up on an app page"; else bad "the store exited opening an app page"; fi

step "no errors logged"
# Less the VM's software-rendering noise (libEGL and Mesa can't find a GPU driver).
log=$(run "cat /tmp/store.log" | grep -Eiv 'libEGL|MESA|ZINK|egl:|dri2')
printf '%s\n' "$log" >"$OUT/store.log"
if grep -Eiq 'critical|panicked|error' <<<"$log"; then
	bad "the store logged problems:"
	grep -Ei 'critical|panicked|error' <<<"$log" | head -8 | sed 's/^/    /'
else
	ok "nothing in its log"
fi
run "pkill -x ostrich-store-g; true"
"$VM" stop

echo
if ((failures == 0)); then
	echo "PASS (screenshots in $OUT)"
else
	echo "$failures FAILED (screenshots in $OUT)"
	exit 1
fi
