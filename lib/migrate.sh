#!/usr/bin/env bash
# lib/migrate.sh: move an install made under an earlier project name to Ostrich OS (plan 01).
# Source it (install.sh does) or run it: lib/migrate.sh [--dry-run] [--verbose] [--root]
#
# Data-driven: the old slugs and the root-file tables below are the whole mapping.
#   ostrich-os  new slug: paths, extension UUIDs, schema ids, dconf paths, unit and polkit names
#   ostrich_os  new app id: GApplication, .desktop and D-Bus ids (no dash before the last part)
#
# migrate_run   user-owned items; needs no sudo. Safe to run any number of times.
# migrate_root  root-owned items, through $SUDO (the installer's own); the caller decides when,
#               and it removes an old file only once the new one is in place (two-phase).
#
# Nothing here installs anything new: new extension zips, desktop files, the helper and its policy
# come from the installer. NOT migrated here (the installer regenerates them): .desktop launchers
# in ~/.local/share/applications, autostart files, chezmoi, the Ghostty theme name.

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=lib/logging.sh
declare -F info >/dev/null || source "$LIB_DIR/logging.sh"

MIGRATE_NEW_SLUG=ostrich-os
MIGRATE_NEW_APP=ostrich_os
# Oldest first. Each also exists with underscores as an app id (ubuntu_ostrich.drawer).
MIGRATE_OLD_SLUGS=(cleanest-ubuntu-setup ostrich-ubuntu ubuntu-ostrich)

# Root items; @S@ is an old slug, @N@ the new one. REPLACED: the installer puts the new file in
# place, we remove the old once it is there. MOVED: data, moved as is. DIRS: removed if empty.
MIGRATE_ROOT_REPLACED=(
	'/usr/libexec/@S@/system-helper|/usr/libexec/@N@/system-helper'
	'/usr/share/polkit-1/actions/org.@S@.system-helper.policy|/usr/share/polkit-1/actions/org.@N@.system-helper.policy'
	'/etc/systemd/system/@S@-power.service|/etc/systemd/system/@N@-power.service'
	'/etc/udev/rules.d/90-@S@-touchscreen.rules|/etc/udev/rules.d/90-@N@-touchscreen.rules'
)
MIGRATE_ROOT_MOVED=('/var/lib/@S@|/var/lib/@N@')
MIGRATE_ROOT_DIRS=('/usr/libexec/@S@')
MIGRATE_ROOT="${MIGRATE_ROOT:-}" # a prefix for the root paths (tests)

MIG_CHANGES=0
MIG_RELOGIN=0
MIG_VERBOSE="${MIG_VERBOSE:-0}"

mig_note() {
	changed "migrate: $*"
	MIG_CHANGES=$((MIG_CHANGES + 1))
}
mig_v() { ((MIG_VERBOSE)) && info "migrate: $*" || true; }

# --- the id and uuid tables ---------------------------------------------------------------

# migrate_map_id <id[.desktop]>: the new id on stdout; status 1 when it is not an old id.
# Also maps prefixes (ubuntu_ostrich.drawer), which the dock's hidden-app-prefixes holds.
migrate_map_id() {
	local id=$1 suffix="" s u
	if [[ $id == *.desktop ]]; then
		suffix=.desktop
		id=${id%.desktop}
	fi
	for s in "${MIGRATE_OLD_SLUGS[@]}"; do
		for u in "$s" "${s//-/_}"; do
			if [[ $id == "$u".* ]]; then
				printf '%s.%s%s\n' "$MIGRATE_NEW_APP" "${id#"$u".}" "$suffix"
				return 0
			fi
		done
	done
	return 1
}

# migrate_map_uuid <name@slug>: the new uuid; status 1 when not ours.
migrate_map_uuid() {
	local s
	for s in "${MIGRATE_OLD_SLUGS[@]}"; do
		if [[ $1 == *@"$s" ]]; then
			printf '%s@%s\n' "${1%@"$s"}" "$MIGRATE_NEW_SLUG"
			return 0
		fi
	done
	return 1
}

# migrate_child_name <app id>: GNOME's notification child for it (verified, plan 01): drop
# ".desktop", lower-case, "." and "_" become "-".
migrate_child_name() {
	local n=${1%.desktop}
	n=${n,,}
	printf '%s\n' "${n//[._]/-}"
}

# --- dconf string lists -------------------------------------------------------------------

mig_list_items() { # <key>: one item per line
	local v
	v=$(dconf read "$1" 2>/dev/null) || return 0
	v=${v#@as }
	v=${v#\[}
	v=${v%\]}
	[[ -n $v ]] || return 0
	v=${v//\', \'/$'\n'}
	v=${v#\'}
	v=${v%\'}
	printf '%s\n' "$v"
}

mig_list_format() { # items as arguments
	local out="" i
	for i; do out+="'$i', "; done
	((${#out})) || {
		printf '@as []'
		return
	}
	printf '[%s]' "${out%, }"
}

# mig_rewrite_list <key> <mapper> [excluded...]: map every item, drop duplicates (first wins, so
# the order stays), drop mapped items that are in excluded. Sets MIG_LIST_CHANGED=1 if it wrote.
mig_rewrite_list() {
	local key=$1 mapper=$2 item new x skip
	shift 2
	local -a before=() out=()
	MIG_LIST_CHANGED=0
	mapfile -t before < <(mig_list_items "$key")
	((${#before[@]})) || return 0
	for item in "${before[@]}"; do
		new=$("$mapper" "$item") || new=$item
		skip=0
		for x in "${out[@]}"; do [[ $x == "$new" ]] && skip=1; done
		if [[ $new != "$item" ]]; then
			for x in "$@"; do [[ $x == "$new" ]] && skip=1; done
		fi
		((skip)) || out+=("$new")
	done
	[[ ${before[*]} == "${out[*]}" ]] && return 0
	mig_note "$key: $(mig_list_format "${before[@]}") -> $(mig_list_format "${out[@]}")"
	run_cmd dconf write "$key" "$(mig_list_format "${out[@]}")"
	MIG_LIST_CHANGED=1
}

# mig_dconf_copy <old path/> <new path/>: copy, then reset the old only after a good load.
mig_dconf_copy() {
	local dump
	dump=$(dconf dump "$1" 2>/dev/null) || return 0
	[[ -n $dump ]] || return 0
	if [[ -n $(dconf list "$2" 2>/dev/null) ]]; then
		warn "migrate: $2 already has settings, keeping them and leaving $1"
		return 0
	fi
	mig_note "dconf $1 -> $2"
	((DRY_RUN)) && return 0
	if printf '%s\n' "$dump" | dconf load "$2"; then
		dconf reset -f "$1"
	else
		warn "migrate: dconf load $2 failed, $1 left as it was"
	fi
}

# --- user directories ---------------------------------------------------------------------

mig_drawer_running() { pgrep -x ostrich-drawer >/dev/null 2>&1; }

# mig_merge <old> <new>: new exists. Move what new lacks, drop identical copies, never overwrite.
# A drawer/<site> directory is one unit (cookies.sqlite with its -wal/-shm). Status 1: conflicts,
# old kept (with only the conflicting parts left in it).
mig_merge() {
	local old=$1 new=$2 e name rc=0
	shopt -s dotglob nullglob
	for e in "$old"/*; do
		name=${e##*/}
		if [[ ! -e $new/$name && ! -L $new/$name ]]; then
			mig_note "move $e -> $new/$name"
			run_cmd mv "$e" "$new/$name"
		elif [[ -d $e && ! -L $e && -d $new/$name && ${old##*/} != drawer ]]; then
			mig_merge "$e" "$new/$name" || rc=1
		elif [[ -f $e && -f $new/$name ]] && cmp -s "$e" "$new/$name"; then
			run_cmd rm -f "$e"
		else
			warn "migrate: conflict, $e and $new/$name differ; keeping $e"
			rc=1
		fi
	done
	shopt -u dotglob nullglob
	((rc == 0)) && { run_cmd rmdir "$old" || rc=1; }
	return $rc
}

# mig_move_dir <old> <new>
mig_move_dir() {
	[[ -d $1 ]] || return 0
	if [[ ! -e $2 ]]; then
		mig_note "move $1 -> $2"
		run_cmd mkdir -p "$(dirname "$2")"
		run_cmd mv "$1" "$2"
	else
		mig_merge "$1" "$2" || warn "migrate: $1 kept (see conflicts above)"
	fi
}

# After the state dir moved, files that still name it (the log, restore points) follow.
mig_repoint() { # <old state dir> <new state dir>
	local v
	for v in LOG_FILE STATE_DIR RESTORE_DIR BACKUP_DIR; do
		[[ ${!v:-} == "$1"* ]] && printf -v "$v" '%s' "$2${!v#"$1"}"
	done
	[[ -z ${LOG_FILE:-} ]] || mkdir -p "$(dirname "$LOG_FILE")"
}

# --- the run ------------------------------------------------------------------------------

# Newest slug first, so when two old installs left a child for the same site the newer one wins.
mig_notifications() {
	local base=/org/gnome/desktop/notifications/application kids_key=/org/gnome/desktop/notifications/application-children
	local kid id new newkid dump changed=0 i s
	local -a cur=()
	mapfile -t cur < <(mig_list_items "$kids_key")
	((${#cur[@]})) || return 0
	for ((s = ${#MIGRATE_OLD_SLUGS[@]} - 1; s >= 0; s--)); do
		for i in "${!cur[@]}"; do
			kid=${cur[i]}
			id=$(dconf read "$base/$kid/application-id" 2>/dev/null)
			id=${id#\'}
			id=${id%\'}
			[[ $id == "${MIGRATE_OLD_SLUGS[s]}".* || $id == "${MIGRATE_OLD_SLUGS[s]//-/_}".* ]] || continue
			new=$(migrate_map_id "$id") || continue
			newkid=$(migrate_child_name "$new")
			if [[ " ${cur[*]} " == *" $newkid "* || -n $(dconf list "$base/$newkid/" 2>/dev/null) ]]; then
				mig_v "notifications: $newkid exists, keeping it (and $kid)"
				continue
			fi
			mig_note "notification settings $kid -> $newkid"
			cur[i]=$newkid
			changed=1
			((DRY_RUN)) && continue
			dump=$(dconf dump "$base/$kid/")
			if printf '%s\n' "$dump" | sed "s|^application-id=.*|application-id='$new'|" | dconf load "$base/$newkid/"; then
				dconf reset -f "$base/$kid/"
			else
				warn "migrate: could not copy notification settings $kid -> $newkid"
				cur[i]=$kid
			fi
		done
	done
	((changed)) && run_cmd dconf write "$kids_key" "$(mig_list_format "${cur[@]}")"
	return 0
}

mig_extension_dirs() {
	local d name new
	shopt -s nullglob
	for d in "$1"/*; do
		name=${d##*/}
		new=$(migrate_map_uuid "$name") || continue
		if [[ -d $1/$new ]]; then
			mig_note "remove old extension $name (installed as $new)"
			run_cmd rm -rf "$d"
		else
			mig_v "extension $name stays until $new is installed"
		fi
	done
	shopt -u nullglob
}

# migrate_run: honours DRY_RUN and MIG_VERBOSE.
migrate_run() {
	local cfg=${XDG_CONFIG_HOME:-$HOME/.config} data=${XDG_DATA_HOME:-$HOME/.local/share}
	local state=${XDG_STATE_HOME:-$HOME/.local/state} libexec=$HOME/.local/libexec
	local n=$MIGRATE_NEW_SLUG i s from_version=unknown found=() v
	local -a disabled=()
	MIG_CHANGES=0
	MIG_RELOGIN=0
	info "migrate: start (dry-run=$DRY_RUN)"

	# Newest slug first: it wins the move, older ones only add what is missing.
	for ((i = ${#MIGRATE_OLD_SLUGS[@]} - 1; i >= 0; i--)); do
		s=${MIGRATE_OLD_SLUGS[i]}
		if [[ -d $cfg/$s || -d $data/$s || -d $state/$s || -d $libexec/$s ]]; then
			found+=("$s")
			if [[ $from_version == unknown && -r $data/$s/src/VERSION ]]; then
				from_version=$(<"$data/$s/src/VERSION")
			fi
		fi
		mig_move_dir "$cfg/$s" "$cfg/$n"
		if [[ -d $data/$s/drawer ]] && mig_drawer_running; then
			warn "migrate: the drawer is running; quit it and run again to move $data/$s (config and settings moved)"
		else
			mig_move_dir "$data/$s" "$data/$n"
		fi
		if [[ -d $state/$s ]]; then
			mig_move_dir "$state/$s" "$state/$n"
			if ((!DRY_RUN)) && [[ ! -d $state/$s ]]; then mig_repoint "$state/$s" "$state/$n"; fi
		fi
		mig_move_dir "$libexec/$s" "$libexec/$n"
		mig_dconf_copy "/org/gnome/shell/extensions/$s/" "/org/gnome/shell/extensions/$n/"
	done

	# Extensions: disabled stays disabled (each list is mapped on its own); the new uuid never
	# goes into enabled-extensions when it is in disabled-extensions.
	mig_rewrite_list /org/gnome/shell/disabled-extensions migrate_map_uuid
	mapfile -t disabled < <(mig_list_items /org/gnome/shell/disabled-extensions)
	for i in "${!disabled[@]}"; do disabled[i]=$(migrate_map_uuid "${disabled[i]}" || echo "${disabled[i]}"); done
	mig_rewrite_list /org/gnome/shell/enabled-extensions migrate_map_uuid "${disabled[@]}"
	((MIG_LIST_CHANGED)) && MIG_RELOGIN=1
	mig_extension_dirs "$data/gnome-shell/extensions"

	mig_rewrite_list /org/gnome/shell/favorite-apps migrate_map_id
	mig_rewrite_list "/org/gnome/shell/extensions/$n/dock/hidden-app-prefixes" migrate_map_id
	mig_notifications

	if ((MIG_CHANGES > 0 && !DRY_RUN)) && [[ ! -e $state/$n/migrated-from ]]; then
		mkdir -p "$state/$n"
		printf 'from_slugs=%s\nfrom_version=%s\nto_version=%s\ndate=%s\n' \
			"${found[*]}" "$from_version" "$(cat "$LIB_DIR/../VERSION" 2>/dev/null || echo unknown)" \
			"$(date '+%Y-%m-%dT%H:%M:%S%z')" >"$state/$n/migrated-from"
	fi
	if ((MIG_RELOGIN)); then
		info "migrate: log out and back in to finish: the extensions now have new names, and GNOME Shell only finds new extension folders at the start of a session."
	fi
	for v in "${found[@]}"; do mig_v "found an install under $v"; done
	info "migrate: done, $MIG_CHANGES change(s) (dry-run=$DRY_RUN)"
}

# --- root items ---------------------------------------------------------------------------

mig_root() { # run through the installer's $SUDO (empty in tests)
	if [[ -n ${SUDO-sudo} ]]; then run_cmd "${SUDO-sudo}" "$@"; else run_cmd "$@"; fi
}

mig_sub() { # <template> <slug>
	local t=${1//@S@/$2}
	printf '%s\n' "${t//@N@/$MIGRATE_NEW_SLUG}"
}

# migrate_root: for the installer, after the new helper, policy and units are installed.
migrate_root() {
	local s pair old new units=0 udev=0 d
	for s in "${MIGRATE_OLD_SLUGS[@]}"; do
		for pair in "${MIGRATE_ROOT_REPLACED[@]}"; do
			old=$MIGRATE_ROOT$(mig_sub "${pair%%|*}" "$s")
			new=$MIGRATE_ROOT$(mig_sub "${pair##*|}" "$s")
			[[ -e $old ]] || continue
			if [[ ! -e $new ]]; then
				info "migrate: keeping $old until $new is installed"
				continue
			fi
			mig_note "remove $old (replaced by $new)"
			if [[ $old == *.service ]]; then
				mig_root systemctl disable "${old##*/}" || true
				units=1
			fi
			[[ $old == */udev/* ]] && udev=1
			mig_root rm -f "$old"
		done
		for pair in "${MIGRATE_ROOT_MOVED[@]}"; do
			old=$MIGRATE_ROOT$(mig_sub "${pair%%|*}" "$s")
			new=$MIGRATE_ROOT$(mig_sub "${pair##*|}" "$s")
			[[ -d $old ]] || continue
			if [[ -e $new ]]; then
				warn "migrate: $new exists, keeping $old"
			else
				mig_note "move $old -> $new"
				mig_root mv "$old" "$new"
			fi
		done
		for pair in "${MIGRATE_ROOT_DIRS[@]}"; do
			d=$MIGRATE_ROOT$(mig_sub "$pair" "$s")
			[[ -d $d ]] && mig_root rmdir --ignore-fail-on-non-empty "$d"
		done
	done
	((units)) && mig_root systemctl daemon-reload
	((udev)) && mig_root udevadm control --reload
	return 0
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	set -uo pipefail
	root=0
	for a in "$@"; do
		case $a in
		-n | --dry-run) DRY_RUN=1 ;;
		-v | --verbose) MIG_VERBOSE=1 ;;
		--root) root=1 ;;
		*) die "migrate: unknown option: $a" ;;
		esac
	done
	((EUID != 0)) || die "migrate: run as your normal user, not root"
	LOG_FILE="${LOG_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/$MIGRATE_NEW_SLUG/install.log}"
	((DRY_RUN)) || log_init
	migrate_run
	if ((root)); then migrate_root; fi
fi
