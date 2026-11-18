#!/usr/bin/env bash
# tests/vm/ppd-three.sh: give the running test VM three power profiles (performance, balanced,
# power-saver), as on a laptop like the owner's Dell. power-profiles-daemon has a fake driver for
# tests (POWER_PROFILE_DAEMON_FAKE_DRIVER); a systemd drop-in turns it on. --off removes it again.
# The VM's own daemon offers only two profiles (no platform driver), and GNOME's Power Mode tile
# behaves differently with three (council 2026-11-09, test 1).
#
#   ppd-three.sh [--off]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
DROPIN=/etc/systemd/system/power-profiles-daemon.service.d/ostrich-fake-driver.conf

case ${1:-} in
--off) "$VM" ssh "sudo rm -f $DROPIN" ;;
'') "$VM" ssh "sudo mkdir -p ${DROPIN%/*} && printf '[Service]\nEnvironment=POWER_PROFILE_DAEMON_FAKE_DRIVER=1\n' | sudo tee $DROPIN >/dev/null" ;;
*)
	echo "usage: ppd-three.sh [--off]" >&2
	exit 2
	;;
esac
"$VM" ssh "sudo systemctl daemon-reload && sudo systemctl restart power-profiles-daemon && sleep 1 && powerprofilesctl list | grep -c ':$' | sed 's/^/profiles: /'"
