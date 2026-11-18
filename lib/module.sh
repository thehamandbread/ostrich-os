#!/usr/bin/env bash
# lib/module.sh: shared entry for modules/*/install.sh. Source as the first thing in a module:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../../lib/module.sh"   (adjust depth)
#   module_init "$@"
#
# Gives the module: --dry-run/-n, logging to the installer log, backups, detection and package helpers.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "$LIB_DIR/logging.sh"
# shellcheck source=lib/backup.sh
source "$LIB_DIR/backup.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/pkg.sh
source "$LIB_DIR/pkg.sh"
# shellcheck source=lib/helper.sh
source "$LIB_DIR/helper.sh"

STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ubuntu-ostrich}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/install.log}"

module_init() {
	MODULE_NAME="${MODULE_NAME:-$(basename "$(dirname "$(realpath "${BASH_SOURCE[1]}")")")}"
	while (($# > 0)); do
		case $1 in
		-n | --dry-run) DRY_RUN=1 ;;
		*) die "$MODULE_NAME: unknown option: $1" ;;
		esac
		shift
	done
	((EUID != 0)) || die "$MODULE_NAME: run as your normal user, not root"
	log_init
	info "module $MODULE_NAME: start (dry-run=$DRY_RUN)"
}

module_done() { info "module $MODULE_NAME: done"; }
