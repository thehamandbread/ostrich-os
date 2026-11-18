#!/usr/bin/env bash
# tests/vm/dconf-test.sh: our settings survive a dump, a reset and a load (the council's experiment
# X3, which decides whether settings can live in the dotfiles as a dconf file). In the test VM:
# change 10 keys across our extensions, `dconf dump` our path, `dconf reset -f` it, `dconf load`
# the dump; every key must come back, and every extension must stay active without a restart.
#
#   dconf-test.sh [--snapshot NAME]     (default: try-me)
#
# Then `ostrich config` (this checkout's build, from build-tools.sh): set, get, export, reset and
# import a setting, and refuse a settings file that sets a command.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ubuntu-ostrich/vm}"
SNAPSHOT=try-me
while (($# > 0)); do
	case $1 in
	--snapshot) SNAPSHOT=$2 && shift ;;
	*)
		echo "usage: dconf-test.sh [--snapshot NAME]" >&2
		exit 2
		;;
	esac
	shift
done
BASE=/org/gnome/shell/extensions/ubuntu-ostrich
# key=value (GVariant text), one per extension or more.
CHANGES=(
	"blur/panel=false"
	"blur/notifications-radius=uint32 55"
	"dock/icon-size=uint32 48"
	"dock/hide-delay=uint32 900"
	"drawer/bar-max=uint32 3"
	"monitor/hide-zeros=false"
	"monitor/section-rows=uint32 12"
	"tiling/tile-left=['<Super><Alt>Left']"
	"tweaks/animation-speed=0.8"
	"tweaks/show-events=true"
	"workspaces/show-empty=false"
)

failures=0
ok() { printf '  ok: %s\n' "$*"; }
bad() {
	printf '  FAIL: %s\n' "$*"
	failures=$((failures + 1))
}
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus;'
run() { "$VM" ssh "$SESSION $*"; }
active() { run "gnome-extensions list --enabled --details | grep -c 'State: ACTIVE'"; }

echo "== start from $SNAPSHOT"
"$VM" stop
"$VM" snapshot restore "$SNAPSHOT"
"$VM" start
sleep 45
before=$(active)
echo "    $before extensions active"

echo "== change 10 keys, dump, reset, load"
for c in "${CHANGES[@]}"; do
	run "dconf write $BASE/${c%%=*} \"${c#*=}\""
done
want=$(for c in "${CHANGES[@]}"; do run "dconf read $BASE/${c%%=*}"; done)
run "dconf dump $BASE/ > /tmp/ostrich.dconf"
run "dconf reset -f $BASE/"
sleep 3
after_reset=$(for c in "${CHANGES[@]}"; do run "dconf read $BASE/${c%%=*}"; done | grep -c . || true)
if [[ $after_reset == 0 ]]; then ok "reset cleared them"; else bad "reset left $after_reset keys"; fi
run "dconf load $BASE/ < /tmp/ostrich.dconf"
sleep 5
got=$(for c in "${CHANGES[@]}"; do run "dconf read $BASE/${c%%=*}"; done)
if [[ $got == "$want" ]]; then
	ok "all 10 keys came back"
else
	bad "keys differ after the load"
	diff <(echo "$want") <(echo "$got") | sed 's/^/    /'
fi
now=$(active)
if [[ $now == "$before" ]]; then ok "all $now extensions still active"; else bad "$now of $before extensions active"; fi
errs=$(run "journalctl --user -b -o cat /usr/bin/gnome-shell | grep -c 'JS ERROR.*ubuntu-ostrich' || true")
if [[ $errs == 0 ]]; then ok "no JS errors"; else bad "$errs JS errors from our extensions"; fi

echo "== ostrich config"
"$VM" copy "$VM_DIR/tools-bin/ostrich" /tmp/ostrich
o="/tmp/ostrich config"
run "$o set dock icon-size 40"
if [[ $(run "$o get dock icon-size") == "uint32 40" ]]; then ok "set and get"; else bad "set/get: $(run "$o get dock icon-size")"; fi
if run "$o set dock icon-size lots" 2>/dev/null; then bad "a value of the wrong type was taken"; else ok "a value of the wrong type is refused"; fi
run "$o export /tmp/mine.dconf" >/dev/null
run "$o reset dock icon-size"
run "$o import /tmp/mine.dconf" >/dev/null
if [[ $(run "$o get dock icon-size") == "uint32 40" ]]; then ok "export, reset, import"; else bad "export/import lost icon-size"; fi
if run "grep -q host-command /tmp/mine.dconf"; then bad "the export has a command key"; else ok "the export leaves out the command key"; fi
run "printf '[drawer]\nhost-command=%s\n' \"'sh -c x'\" > /tmp/evil.dconf"
if run "$o import /tmp/evil.dconf" 2>/dev/null; then bad "a file that sets a command was imported"; else ok "a file that sets a command is refused"; fi
if [[ $(run "$o list dock" | grep -c '^dock ') -gt 5 ]]; then ok "list"; else bad "list printed too little"; fi

"$VM" stop
if ((failures)); then
	echo "dconf-test: $failures failed"
	exit 1
fi
echo "dconf-test: all passed"
