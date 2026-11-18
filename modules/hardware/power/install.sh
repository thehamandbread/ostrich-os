#!/usr/bin/env bash
# modules/hardware/power/install.sh: power modes beyond power-profiles-daemon (DESIGN.md: power
# modes). Only where power-profiles-daemon runs and the machine has knobs the helper manages.
#
# The monitor extension applies the helper's extra knobs (turbo, PCIe ASPM, audio power save)
# whenever the power mode changes; this boot unit re-applies them for the saved mode at startup.
# It hangs off graphical.target: Ubuntu orders power-profiles-daemon after multi-user.target.
set -euo pipefail
# shellcheck source=lib/module.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/module.sh"
module_init "$@"

UNIT=ubuntu-ostrich-power.service
UNIT_DEST="${UNIT_DEST:-/etc/systemd/system/$UNIT}"

has_knobs() {
	[[ -e $SYSFS_ROOT/devices/system/cpu/intel_pstate/no_turbo || -e $SYSFS_ROOT/module/pcie_aspm/parameters/policy ||
		-e $SYSFS_ROOT/module/snd_hda_intel/parameters/power_save ]]
}

if ! command -v powerprofilesctl >/dev/null 2>&1 || ! has_knobs; then
	info "no power-profiles-daemon or no power knobs; skipping"
	module_done
	exit 0
fi
if ! have_helper_build; then
	info "system helper not built ($HELPER_SRC); skipping (the tools module stages it)"
	module_done
	exit 0
fi

install_system_helper

unit=$(mktemp)
trap 'rm -f "$unit"' EXIT
cat >"$unit" <<UNIT
# Ubuntu Ostrich: re-apply the power mode's extra knobs at boot.
[Unit]
Description=Re-apply Ubuntu Ostrich power mode
After=power-profiles-daemon.service
Wants=power-profiles-daemon.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'exec $HELPER_DEST power apply "\$\$(powerprofilesctl get)"'

[Install]
WantedBy=graphical.target
UNIT
if ! { [[ -f $UNIT_DEST ]] && cmp -s "$unit" "$UNIT_DEST"; }; then
	sudo_install "$unit" "$UNIT_DEST" 0644
	run_cmd "$SUDO" systemctl daemon-reload
	# reenable: a changed [Install] section must drop the old target's link
	changed "enable $UNIT"
	run_cmd "$SUDO" systemctl reenable "$UNIT"
elif ! systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then
	changed "enable $UNIT"
	run_cmd "$SUDO" systemctl enable "$UNIT"
fi

module_done
