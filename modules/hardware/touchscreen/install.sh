#!/usr/bin/env bash
# modules/hardware/touchscreen/install.sh: the system helper and polkit policy behind the
# Touchscreen quick-settings tile. Only on machines with a touchscreen.
set -euo pipefail
# shellcheck source=lib/module.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/module.sh"
module_init "$@"

if ! has_touchscreen; then
	info "no touchscreen detected; skipping"
	module_done
	exit 0
fi
if ! have_helper_build; then
	info "system helper not built ($HELPER_SRC); skipping (the tools module stages it)"
	module_done
	exit 0
fi
install_system_helper
module_done
