#!/usr/bin/env bash
# modules/hardware/nvidia-optimus/install.sh: graphics modes on NVIDIA hybrid laptops
# (DESIGN.md: graphics modes). Only when an NVIDIA GPU sits next to an Intel or AMD one.
#
# Installs prime-select (nvidia-prime) and switcheroo-control (launches marked apps on the dGPU),
# the system helper behind the Graphics step and menu, and makes sure the dGPU can power down
# when idle (runtime D3). Hybrid is set once, on the first run; later runs leave the user's choice.
# The NVIDIA driver itself isn't installed here: `sudo ubuntu-drivers install` picks the right one.
set -euo pipefail
# shellcheck source=lib/module.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/module.sh"
module_init "$@"

NVIDIA_PARAMS="${NVIDIA_PARAMS:-/proc/driver/nvidia/params}"
MODPROBE_CONF="${MODPROBE_CONF:-/etc/modprobe.d/ubuntu-ostrich-nvidia-pm.conf}"
HYBRID_MARK="$STATE_DIR/graphics-default-set"

if ! is_hybrid_graphics; then
	info "no NVIDIA hybrid graphics; skipping"
	module_done
	exit 0
fi

apt_install nvidia-prime switcheroo-control

if [[ ! -d $SYSFS_ROOT/module/nvidia ]]; then
	warn "the NVIDIA driver isn't loaded. Install it with: sudo ubuntu-drivers install (then restart). Graphics modes need it."
fi

if have_helper_build; then
	install_system_helper
else
	info "system helper not built ($HELPER_SRC); the Graphics step will say it's missing"
fi

# Runtime D3: the driver's dynamic power management must not be off (0), or the dGPU never sleeps.
if [[ -r $NVIDIA_PARAMS ]] && grep -q '^DynamicPowerManagement: 0$' "$NVIDIA_PARAMS"; then
	conf=$(mktemp)
	printf '# Ubuntu Ostrich: let the NVIDIA GPU power down when idle (runtime D3).\noptions nvidia NVreg_DynamicPowerManagement=0x02\n' >"$conf"
	sudo_install "$conf" "$MODPROBE_CONF" 0644
	rm -f "$conf"
	info "the dGPU's idle power-down takes effect after a restart"
fi

# Hybrid by default, once.
if [[ ! -e $HYBRID_MARK ]] && command -v prime-select >/dev/null 2>&1; then
	mode=$(prime-select query 2>/dev/null || true)
	if [[ $mode != on-demand ]]; then
		changed "graphics mode ${mode:-unset} -> hybrid (on-demand); takes effect after you log out"
		run_cmd "$SUDO" prime-select on-demand
	fi
	((DRY_RUN)) || { mkdir -p "$STATE_DIR" && touch "$HYBRID_MARK"; }
fi

module_done
