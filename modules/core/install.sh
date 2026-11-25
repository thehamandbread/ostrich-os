#!/usr/bin/env bash
# modules/core/install.sh: base packages, Flatpak with Flathub, and a quiet text console.
set -euo pipefail
# shellcheck source=lib/module.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/module.sh"
module_init "$@"

CORE_PACKAGES=(curl ca-certificates git jq unzip flatpak)
FLATHUB_URL="https://dl.flathub.org/repo/flathub.flatpakrepo"

apt_install "${CORE_PACKAGES[@]}"

if command -v flatpak >/dev/null 2>&1 || ((DRY_RUN)); then
	flatpak_add_remote flathub "$FLATHUB_URL"
	flatpak_fetch_catalogue flathub
fi

# Kernel errors (a dock's USB audio, a touchpad's short report) print to the text console, which
# shows for a moment on every wake from suspend before the lock screen takes over (owner,
# 2026-11-25: "error codes on the screen"). Only critical ones go there now; all stay in the journal
# (journalctl -k). Ubuntu's own value, from 10-console-messages.conf, is 4 4 1 7.
CONSOLE_SYSCTL="${CONSOLE_SYSCTL:-/etc/sysctl.d/60-ostrich-os-console.conf}"
quiet_console() {
	local conf
	conf=$(mktemp)
	printf '# Ostrich OS: only critical kernel messages on the text console (they stay in the journal).\nkernel.printk = 3 4 1 3\n' >"$conf"
	if ! { [[ -f $CONSOLE_SYSCTL ]] && cmp -s "$conf" "$CONSOLE_SYSCTL"; }; then
		sudo_install "$conf" "$CONSOLE_SYSCTL" 0644
		run_cmd "$SUDO" sysctl -q -p "$CONSOLE_SYSCTL" || warn "kernel console level applies after a restart"
	fi
	rm -f "$conf"
}
[[ -d ${CONSOLE_SYSCTL%/*} ]] && quiet_console

module_done
