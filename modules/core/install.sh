#!/usr/bin/env bash
# modules/core/install.sh: base packages and Flatpak with Flathub.
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

module_done
