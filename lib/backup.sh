#!/usr/bin/env bash
# lib/backup.sh: back up before overwriting, and idempotent file installs. Source after logging.sh.
#
# Backups go to $BACKUP_DIR (one timestamped directory per installer run), mirroring the original path.

RESTORE_DIR="${RESTORE_DIR:-${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ostrich-os}/restore/original}"
BACKUP_DIR="${BACKUP_DIR:-${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ostrich-os}/backups/$(date '+%Y%m%dT%H%M%S')}"

# Restore-point bookkeeping (lib/restore.sh): only once a restore point exists, never in a dry run.
# record_line <list> <line>: append unless already listed.
record_line() {
	((DRY_RUN)) && return 0
	[[ -f $RESTORE_DIR/dconf.ini ]] || return 0
	grep -qxF -- "$2" "$RESTORE_DIR/$1" 2>/dev/null || printf '%s\n' "$2" >>"$RESTORE_DIR/$1"
}
# record_created <path>: a file we're about to create (it doesn't exist yet).
# Both record the path as given (symlinks not resolved), so the two lists always match.
record_created() { record_line created.txt "$(realpath -ms "$1")"; }
# record_original <path> <copy>: the first copy of a file we replace is the original.
record_original() {
	((DRY_RUN)) && return 0
	[[ -f $RESTORE_DIR/dconf.ini ]] || return 0
	local path
	path=$(realpath -ms "$1")
	grep -q -- "^$path	" "$RESTORE_DIR/originals.txt" 2>/dev/null && return 0
	grep -qxF -- "$path" "$RESTORE_DIR/created.txt" 2>/dev/null && return 0 # ours to begin with
	printf '%s\t%s\n' "$path" "$2" >>"$RESTORE_DIR/originals.txt"
}

# backup_file <path>: copy an existing file or directory into BACKUP_DIR. No-op if it doesn't exist.
backup_file() {
	local path=$1 dest
	[[ -e $path || -L $path ]] || return 0
	dest="$BACKUP_DIR$(realpath -s "$path")"
	if ((DRY_RUN)); then
		log WOULD "back up $path -> $dest"
		return 0
	fi
	mkdir -p "$(dirname "$dest")"
	cp -a "$path" "$dest"
	record_original "$path" "$dest"
	log BACKUP "$path -> $dest"
}

# install_file <src> <dest> [mode]: install src at dest unless identical; back up what it replaces.
install_file() {
	local src=$1 dest=$2 mode=${3:-0644}
	[[ -f $src ]] || die "install_file: source missing: $src"
	if [[ -f $dest ]] && cmp -s "$src" "$dest"; then
		return 0
	fi
	if [[ -e $dest ]]; then
		backup_file "$dest"
	else
		record_created "$dest"
	fi
	changed "install $dest"
	((DRY_RUN)) && return 0
	mkdir -p "$(dirname "$dest")"
	install -m "$mode" "$src" "$dest"
}
