#!/usr/bin/env bash
# modules/hardware/dell/install.sh: Dell laptops. Only on Dell hardware.
#
# Dell's thermal modes (quiet, cool, balanced, performance) are the kernel's platform_profile,
# which power-profiles-daemon already drives from the power mode, so nothing extra is installed.
# This module reports what it found so the log shows the profiles are in use.
set -euo pipefail
# shellcheck source=lib/module.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/module.sh"
module_init "$@"

if ! is_dell; then
	info "not a Dell; skipping"
	module_done
	exit 0
fi
profiles="$SYSFS_ROOT/firmware/acpi/platform_profile_choices"
if [[ -r $profiles ]]; then
	info "Dell $(dmi_field product_name): thermal modes $(<"$profiles") follow the power mode (power-profiles-daemon)"
else
	warn "Dell $(dmi_field product_name) without platform profiles: thermal modes won't follow the power mode"
fi
module_done
