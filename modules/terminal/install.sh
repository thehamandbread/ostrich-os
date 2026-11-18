#!/usr/bin/env bash
# modules/terminal/install.sh: Ghostty from the Ubuntu archive. Its config and the default-terminal
# setting (xdg-terminals.list) come from the dotfiles module.
set -euo pipefail
# shellcheck source=lib/module.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/module.sh"
module_init "$@"

apt_install ghostty

module_done
