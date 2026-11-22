#!/usr/bin/env bash
# install.sh: bootstrap entry point for Ostrich OS.
#
#   wget -qO- <url>/install.sh | bash             (fetches the repo, then runs from it;
#                                                  wget because a fresh Ubuntu has no curl or git)
#   ./install.sh [--dry-run]                      (from a checkout)
#   ostrich update  (= install.sh --update)       (fetch the latest into the managed copy, re-run)
#   ostrich uninstall (= install.sh --uninstall)  (put everything back as the restore point recorded)
set -euo pipefail

readonly PROJECT="ostrich-os"
readonly TARGET_ID="ubuntu"
readonly TARGET_VERSION="26.04"
REPO_URL="${REPO_URL:-https://github.com/thehamandbread/ostrich-os.git}"
REPO_SLUG="${REPO_SLUG:-thehamandbread/ostrich-os}"
# A tag or branch to fetch. Unset: `main` for a first install, the latest release for --update
# (the tools and extension zips are published per release, so main can be ahead of them).
REPO_REF="${REPO_REF:-}"

# Overridable for tests only.
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$PROJECT"
LOG_FILE="$STATE_DIR/install.log"
SRC_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/src"

# Module order. Hardware modules detect their hardware and no-op elsewhere.
MODULES=(core dotfiles terminal tools gnome dev apps claude-code hardware/nvidia-optimus hardware/dell hardware/power hardware/touchscreen)

DRY_RUN=0
FORCE=0
UPDATE=0
UNINSTALL=0
YES=0
KEEP_NEW_SETTINGS=0
REMOVE_PACKAGES=0
INSTALL_MODE="" # keep | clean (asked when other extensions are installed)
ARGS=("$@")

usage() {
	cat <<EOF
Usage: install.sh [options]

Set up Ostrich OS on Ubuntu ${TARGET_VERSION}. Safe to re-run.

Options:
  -n, --dry-run   Show what would be done without changing anything
  -f, --force     Run on an OS other than Ubuntu ${TARGET_VERSION} (unsupported)
  -u, --update    Fetch the latest release into ${SRC_DIR}, then run it
      --keep      Keep your other extensions and settings (the default)
      --clean     Switch off every other extension and reset its settings (undoable)
      --uninstall Put everything back as it was before the first install
        -y, --yes           don't ask first
        --keep-new-settings only undo Ostrich OS's own settings
        --remove-packages   also remove the packages it added
  -h, --help      Show this help

Log file: ${LOG_FILE}
EOF
}

# Minimal logger until lib/logging.sh is available (the wget | bash case).
early_log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >&2; }

parse_args() {
	while (($# > 0)); do
		case $1 in
		-n | --dry-run) DRY_RUN=1 ;;
		-f | --force) FORCE=1 ;;
		-u | --update) UPDATE=1 ;;
		--keep) INSTALL_MODE=keep ;;
		--clean) INSTALL_MODE=clean ;;
		--uninstall) UNINSTALL=1 ;;
		-y | --yes) YES=1 ;;
		--keep-new-settings) KEEP_NEW_SETTINGS=1 ;;
		--remove-packages) REMOVE_PACKAGES=1 ;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			usage >&2
			early_log ERROR "Unknown option: $1"
			exit 1
			;;
		esac
		shift
	done
}

# Prints the repo directory this script belongs to, or nothing when run from a pipe.
local_repo() {
	local src=${BASH_SOURCE[0]:-}
	[[ -n $src && -f $src ]] || return 0
	local dir
	dir="$(cd "$(dirname "$src")" && pwd)"
	[[ -f $dir/lib/module.sh ]] && printf '%s\n' "$dir"
	return 0
}

# A fresh Ubuntu desktop has neither git (to fetch the repo) nor curl (used by the modules).
ensure_prereqs() {
	local -a missing=()
	local c
	for c in git curl; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
	((${#missing[@]} == 0)) && return 0
	if ((DRY_RUN)); then
		early_log INFO "Dry run: needs ${missing[*]} to fetch the installer. Install them, then run this again: sudo apt-get install ${missing[*]}"
		exit 0
	fi
	early_log INFO "Installing ${missing[*]} first (Ubuntu will ask for your password)"
	if ! { sudo apt-get update -qq && sudo env DEBIAN_FRONTEND=noninteractive \
		apt-get install -y -qq "${missing[@]}" ca-certificates; } </dev/null; then
		early_log ERROR "could not install ${missing[*]}; check the internet connection and try again"
		exit 1
	fi
}

# Fills REPO_REF when it wasn't given: the latest GitHub release for --update, else main.
resolve_ref() {
	[[ -n $REPO_REF ]] && return 0
	if ((UPDATE)); then
		REPO_REF=$(curl -fsSL --proto '=https' "https://api.github.com/repos/$REPO_SLUG/releases/latest" 2>/dev/null |
			sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1) || REPO_REF=""
		[[ -z $REPO_REF ]] || early_log INFO "Latest release: $REPO_REF"
	fi
	[[ -n $REPO_REF ]] || REPO_REF=main
}

fetch_repo() {
	ensure_prereqs
	resolve_ref
	if [[ -d $SRC_DIR/.git ]]; then
		early_log INFO "Updating $SRC_DIR"
		git -C "$SRC_DIR" fetch --quiet --depth 1 origin "$REPO_REF"
		git -C "$SRC_DIR" checkout --quiet --force FETCH_HEAD
	else
		early_log INFO "Fetching $REPO_URL ($REPO_REF) into $SRC_DIR"
		mkdir -p "$(dirname "$SRC_DIR")"
		git clone --quiet --depth 1 --branch "$REPO_REF" "$REPO_URL" "$SRC_DIR"
	fi
}

check_not_root() {
	if ((EUID == 0)); then
		die "Do not run as root. Run as your normal user; you will be asked for sudo when needed."
	fi
}

check_os() {
	local id version
	read -r id version < <(os_id_version)
	if [[ $id == "$TARGET_ID" && $version == "$TARGET_VERSION" ]]; then
		info "OS check passed: Ubuntu $version"
		return 0
	fi
	if ((FORCE)); then
		warn "Unsupported OS ($id $version); continuing because of --force"
		return 0
	fi
	die "This installer supports Ubuntu $TARGET_VERSION only (found $id $version). Use --force to override."
}

# A module counts as implemented once it uses the shared module entry point.
module_implemented() { grep -q '^module_init' "$1"; }

run_modules() {
	local repo=$1 m script
	local -a flags=()
	((DRY_RUN)) && flags+=(--dry-run)
	for m in "${MODULES[@]}"; do
		script="$repo/modules/$m/install.sh"
		if [[ ! -f $script ]] || ! module_implemented "$script"; then
			info "module $m: not implemented yet, skipping"
			continue
		fi
		STATE_DIR="$STATE_DIR" LOG_FILE="$LOG_FILE" DRY_RUN="$DRY_RUN" bash "$script" "${flags[@]}" ||
			die "module $m failed; see $LOG_FILE"
	done
}

main() {
	parse_args "$@"

	local repo
	repo=$(local_repo)
	if [[ -z $repo ]] || ((UPDATE)); then
		if [[ -n $repo && $(realpath "$repo") != $(realpath -m "$SRC_DIR") ]]; then
			early_log INFO "--update: running from a checkout ($repo), not fetching; update it with git"
		else
			fetch_repo
			repo=$SRC_DIR
		fi
		local -a rest=()
		local a
		for a in "${ARGS[@]}"; do [[ $a == -u || $a == --update ]] || rest+=("$a"); done
		# Piped in (wget | bash): the rest of stdin is this script, so read keys from the terminal.
		if [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
			exec bash "$repo/install.sh" "${rest[@]}" </dev/tty
		fi
		exec bash "$repo/install.sh" "${rest[@]}"
	fi

	# shellcheck source=lib/logging.sh
	source "$repo/lib/logging.sh"
	# shellcheck source=lib/detect.sh
	source "$repo/lib/detect.sh"

	# shellcheck source=lib/backup.sh
	source "$repo/lib/backup.sh"
	# shellcheck source=lib/restore.sh
	source "$repo/lib/restore.sh"
	# shellcheck source=lib/tools-build.sh
	source "$repo/lib/tools-build.sh"
	# shellcheck source=lib/migrate.sh
	source "$repo/lib/migrate.sh"
	# shellcheck source=lib/pkg.sh
	source "$repo/lib/pkg.sh"
	# shellcheck source=lib/helper.sh
	source "$repo/lib/helper.sh"

	check_not_root
	# Before the first log line and the restore point: the state directory moves whole.
	((UNINSTALL)) || migrate_state_first
	log_init
	if ((UNINSTALL)); then
		# shellcheck source=lib/pkg.sh
		source "$repo/lib/pkg.sh"
		# shellcheck source=lib/gsettings.sh
		source "$repo/lib/gsettings.sh"
		# shellcheck source=lib/uninstall.sh
		source "$repo/lib/uninstall.sh"
		info "Starting $PROJECT uninstall (dry-run=$DRY_RUN)"
		uninstall_main
		return
	fi
	info "Starting $PROJECT installer (dry-run=$DRY_RUN)"
	# May exec (carrying on from the new source copy); never call it inside $(...), which would
	# capture the whole install.
	relocate_repo "$repo"
	# Tests only: stop here, in the process that will do the install.
	if [[ ${INSTALL_STOP_AFTER:-} == relocate ]]; then
		info "RELOCATE-DONE script=$0 pid=$$ bashpid=$BASHPID"
		return 0
	fi
	check_os
	((DRY_RUN)) && info "Dry run: nothing will be changed"
	choose_mode
	check_tools_build "${BUILD_DIR:-$repo/tools/target/release}" "$repo" # before anything changes
	take_restore_point
	# Moves an install made under an earlier name (lib/migrate.sh), in this shell so STATE_DIR,
	# LOG_FILE, RESTORE_DIR and BACKUP_DIR follow the state directory. Our running apps stop first;
	# app.quit where an app has it, else SIGTERM, never SIGKILL; a data dir whose files are still
	# open (WebKit's processes too) stays where it is.
	migrate_stop_apps
	migrate_run
	remember_source "$repo"
	export INSTALL_MODE
	run_modules "$repo"
	# The new launchers and extensions are in: now the per-site notification settings, then what
	# the old names left behind. Root-owned old files go at the next boot, through a one-shot unit,
	# when no old extension or helper can be loaded.
	migrate_notifications
	migrate_finish
	if [[ -e $STATE_DIR/migrated-from ]] && migrate_root_pending; then
		install_cleanup_unit "$repo" "$STATE_DIR/migrated-from"
	fi
	if ((MIG_DRAWER_SKIPPED)); then
		info "The drawer was running, so its data (your web logins) was not moved yet. Log out and back in, then run \`ostrich update\`."
	fi
	if ((MIG_RELOGIN)); then
		info "Log out and back in to finish: the extensions have new names, which GNOME Shell only finds at login."
	fi
	info "Done"
}

# Running from an earlier name's copy of the source (an update started by an old install): that
# directory is about to be moved, so carry on from the new one (exec), or return if not needed.
relocate_repo() {
	local repo=$1 s data=${XDG_DATA_HOME:-$HOME/.local/share}
	for s in "${MIGRATE_OLD_SLUGS[@]}"; do
		[[ $(realpath "$repo") == "$data/$s/src" ]] || continue
		((DRY_RUN)) && return 0
		info "continuing from $SRC_DIR: the source copy at $repo belongs to an earlier name"
		rm -rf "$SRC_DIR"
		mkdir -p "$(dirname "$SRC_DIR")"
		cp -a "$repo" "$SRC_DIR"
		exec bash "$SRC_DIR/install.sh" "${ARGS[@]}"
	done
	return 0
}

# Where this install came from, so `ostrich update` and `ostrich uninstall` find it when it's a
# checkout rather than the copy the one-line install keeps in $SRC_DIR.
remember_source() {
	((DRY_RUN)) && return 0
	mkdir -p "$STATE_DIR"
	realpath "$1" >"$STATE_DIR/source"
}

# Keep or Clean, asked only when there are other user extensions to decide about.
choose_mode() {
	[[ -n $INSTALL_MODE ]] && return 0
	INSTALL_MODE=keep
	local ext_home="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions" d
	local -a others=()
	for d in "$ext_home"/*/; do
		[[ -d $d && $(basename "$d") != *@ostrich-os ]] && others+=("$(basename "$d")")
	done
	((${#others[@]} > 0)) || return 0
	if ((DRY_RUN)) || [[ ! -t 0 ]]; then
		info "other extensions found (${#others[@]}); keeping them (--clean switches them off)"
		return 0
	fi
	printf '\n  You have %s other GNOME extension(s): %s\n\n' "${#others[@]}" "${others[*]}" >&2
	printf '    1) Keep them (recommended). Ostrich OS switches off only the ones it replaces\n' >&2
	printf '       (dock, tray, blur, tiling, system monitor, workspace bar...) and carries their settings over.\n' >&2
	printf '    2) Clean start. Switch off all of them and reset their settings.\n\n' >&2
	printf '  Either way nothing is deleted, and "ostrich uninstall" puts everything back.\n\n' >&2
	local answer=""
	read -r -p "  Choose 1 or 2 [1]: " answer || true
	[[ $answer == 2 ]] && INSTALL_MODE=clean
	info "mode: $INSTALL_MODE"
}

main "$@"
