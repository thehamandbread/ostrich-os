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
	'/etc/modprobe.d/@S@-nvidia-pm.conf|/etc/modprobe.d/@N@-nvidia-pm.conf'
)
# Files in the home that carry the slug in their name (base: config or data). Moved like the
# directories: never over an existing file.
MIGRATE_USER_FILES=(
	'config|ghostty/themes/@S@|ghostty/themes/@N@'
	'config|pipewire/pipewire.conf.d/90-@S@-speakers.conf|pipewire/pipewire.conf.d/90-@N@-speakers.conf'
	'data|backgrounds/@S@|backgrounds/@N@'
)
MIGRATE_ROOT_MOVED=('/var/lib/@S@|/var/lib/@N@')
MIGRATE_ROOT_DIRS=('/usr/libexec/@S@')
MIGRATE_ROOT="${MIGRATE_ROOT:-}" # a prefix for the root paths (tests)

MIG_CHANGES=0
MIG_RELOGIN=0
export MIG_DRAWER_SKIPPED=0 # 1: the data dir stayed because the drawer runs (install.sh says so)
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

# mig_data_held <dir>: status 0 if any process has a file open under dir. WebKit's network process
# holds cookies.sqlite, not only ostrich-drawer, so the drawer's own pid proves nothing. Without
# fuser (psmisc, in Ubuntu's desktop seed) a running ostrich-drawer counts as holding it.
mig_data_held() {
	[[ -d $1 ]] || return 1
	if ! command -v fuser >/dev/null 2>&1; then
		pgrep -x ostrich-drawer >/dev/null 2>&1
		return
	fi
	local rc=0
	# 255 stops xargs at the first chunk fuser reports a holder for (xargs then exits 124).
	find "$1" -type f -print0 |
		xargs -0 -r -n 400 sh -c 'fuser -s "$@" 2>/dev/null && exit 255; exit 0' _ >/dev/null 2>&1 || rc=$?
	((rc != 0))
}

# mig_copy is a function so a test can break it.
mig_copy() { cp -a -- "$1" "$2"; }

mig_sums() { # <file or dir>: sha256 of every regular file, by relative path
	if [[ -d $1 ]]; then (cd "$1" && find . -type f -exec sha256sum {} + | sort -k2); else sha256sum <"$1"; fi
}

# mig_sidecars <dir>: the -wal/-shm files under it, relative, one per line.
mig_sidecars() { (cd "$1" && find . -type f \( -name '*-wal' -o -name '*-shm' \) | sort); }

# mig_check_sidecars <new dir> <list from mig_sidecars>: every one must have moved with its
# database. Status 1 and a warning when one is missing.
mig_check_sidecars() {
	local f rc=0
	while IFS= read -r f; do
		[[ -z $f || -e $1/$f ]] || {
			warn "migrate: $f did not move with its database"
			rc=1
		}
	done <<<"$2"
	return $rc
}

# mig_mv <old> <new>: a rename on one filesystem. Across filesystems (or with MIG_FORCE_COPY=1):
# copy, compare sha256 of every file (cookies.sqlite-wal and -shm included), delete the old copy
# only if all match; otherwise keep both and say so (status 1).
mig_mv() {
	local old=$1 new=$2 sidecars=""
	if ((DRY_RUN)); then
		run_cmd mv "$old" "$new"
		return 0
	fi
	[[ -d $old ]] && sidecars=$(mig_sidecars "$old")
	if [[ -z ${MIG_FORCE_COPY:-} && $(stat -c %d "$old") == "$(stat -c %d "$(dirname "$new")")" ]]; then
		mv -- "$old" "$new" || return
		mig_check_sidecars "$new" "$sidecars"
		return
	fi
	info "migrate: $old is on another filesystem: copying, then comparing checksums"
	if ! mig_copy "$old" "$new"; then
		warn "migrate: copying $old failed; keeping it (a partial copy may be at $new)"
		return 1
	fi
	if [[ $(mig_sums "$old") == "$(mig_sums "$new")" ]] && mig_check_sidecars "$new" "$sidecars"; then
		rm -rf -- "$old"
	else
		warn "migrate: checksums of $old and $new differ; keeping both"
		return 1
	fi
}

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
			mig_mv "$e" "$new/$name" || rc=1
		elif [[ -d $e && ! -L $e && -d $new/$name && ${old##*/} != drawer ]]; then
			mig_merge "$e" "$new/$name" || rc=1
		elif [[ -f $e && -f $new/$name ]] && cmp -s "$e" "$new/$name"; then
			run_cmd rm -f "$e"
		elif [[ $name == install.log && -f $e && -f $new/$name ]]; then
			# A log: the old lines go in front of the new ones, nothing is lost.
			mig_note "append $e to $new/$name"
			if ((!DRY_RUN)); then
				cat "$e" "$new/$name" >"$new/$name.tmp" && mv "$new/$name.tmp" "$new/$name" && rm -f "$e"
			fi
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
		mig_mv "$1" "$2" || warn "migrate: $1 kept (see above)"
	else
		mig_merge "$1" "$2" || warn "migrate: $1 kept (see conflicts above)"
	fi
}

# migrate_state_first: called by install.sh before it logs or takes a restore point. The state
# dir (restore points, backups, install.log) moves whole to the new name when the new one does
# not exist yet, so the log and the restore point continue the old tree instead of starting a
# second one beside it (which would make uninstall restore the wrong "original").
export MIG_STATE_EARLY=""
migrate_state_first() {
	local state=${XDG_STATE_HOME:-$HOME/.local/state} i s
	MIG_STATE_EARLY=""
	((DRY_RUN)) && return 0
	for ((i = ${#MIGRATE_OLD_SLUGS[@]} - 1; i >= 0; i--)); do
		s=${MIGRATE_OLD_SLUGS[i]}
		[[ -d $state/$s && ! -e $state/$MIGRATE_NEW_SLUG ]] || continue
		mv -- "$state/$s" "$state/$MIGRATE_NEW_SLUG" || return 0
		MIG_STATE_EARLY=$s
		mig_repoint "$state/$s" "$state/$MIGRATE_NEW_SLUG"
		return 0
	done
}

# After the state dir moved, files that still name it (the log, restore points) follow.
mig_repoint() { # <old state dir> <new state dir>
	local v
	for v in LOG_FILE STATE_DIR RESTORE_DIR BACKUP_DIR; do
		[[ ${!v:-} == "$1"* ]] && printf -v "$v" '%s' "$2${!v#"$1"}"
	done
	[[ -z ${LOG_FILE:-} ]] || mkdir -p "$(dirname "$LOG_FILE")"
}

# mig_sed_file <file> <old> <new> <what>: replace text in a file, only if it has it.
mig_sed_file() {
	[[ -f $1 ]] && grep -qF -- "$2" "$1" || return 0
	mig_note "$4: $1"
	run_cmd sed -i "s|$(printf '%s' "$2" | sed 's/[][\\.*^$|]/\\&/g')|$3|g" "$1"
}

# mig_refs <old slug> <cfg> <data>: places that name the old slug inside files and settings that
# stay where they are: the theme block markers in the user's gtk.css, `theme =` in Ghostty's
# config, the wallpaper paths GNOME holds, and the launchers and list of apps the Store installed
# from GitHub (their paths point into the data dir).
mig_refs() {
	local s=$1 cfg=$2 data=$3 n=$MIGRATE_NEW_SLUG f key v
	for f in "$cfg/gtk-4.0/gtk.css" "$cfg/gtk-3.0/gtk.css"; do
		mig_sed_file "$f" "$s theme: " "$n theme: " "theme block marker"
	done
	for f in "$cfg/ghostty/config" "$cfg/ghostty/config.ghostty"; do
		[[ -f $f ]] || continue
		grep -qE "^theme *= *$s\$" "$f" || continue
		mig_note "ghostty theme name: $f"
		run_cmd sed -i -E "s|^theme *= *$s\$|theme = $n|" "$f"
	done
	for key in /org/gnome/desktop/background/picture-uri /org/gnome/desktop/background/picture-uri-dark /org/gnome/desktop/screensaver/picture-uri; do
		v=$(dconf read "$key" 2>/dev/null)
		[[ $v == *"/backgrounds/$s/"* ]] || continue
		mig_note "$key"
		run_cmd dconf write "$key" "${v//\/backgrounds\/$s\//\/backgrounds\/$n\/}"
	done
	for f in "$data"/applications/ost-github-*.desktop "$data/$n/github-apps.json"; do
		mig_sed_file "$f" "/share/$s/" "/share/$n/" "path into the data dir"
	done
}

# mig_move_path <old> <new>: a directory as above; a file only if new lacks it.
mig_move_path() {
	if [[ -d $1 ]]; then
		mig_move_dir "$1" "$2"
	elif [[ -f $1 ]]; then
		if [[ ! -e $2 ]]; then
			mig_note "move $1 -> $2"
			run_cmd mkdir -p "$(dirname "$2")"
			mig_mv "$1" "$2" || true
		elif cmp -s "$1" "$2"; then
			run_cmd rm -f "$1"
		else
			warn "migrate: conflict, $1 and $2 differ; keeping $1"
		fi
	fi
}

# --- the run ------------------------------------------------------------------------------

# mig_child_default <child path>: nothing set but application-id (GNOME made it, nobody changed it).
mig_child_default() {
	local k
	k=$(dconf list "$1/" 2>/dev/null)
	[[ -z $k || $k == application-id ]]
}

# migrate_notifications: per-app notification settings follow the app id (plan 01, verified rule).
# Run after the new .desktop files are installed. Matches on the application-id key, newest slug
# first (so when two old installs left a child for one site the newer wins). A new child that
# GNOME already made with defaults gets the old keys written over it; one the user has changed
# is kept. Migrated old children leave application-children.
migrate_notifications() {
	local base=/org/gnome/desktop/notifications/application kids_key=/org/gnome/desktop/notifications/application-children
	local kid id new newkid changed=0 i s exists
	local -a cur=() out=()
	mapfile -t cur < <(mig_list_items "$kids_key")
	((${#cur[@]})) || return 0
	for ((s = ${#MIGRATE_OLD_SLUGS[@]} - 1; s >= 0; s--)); do
		for i in "${!cur[@]}"; do
			kid=${cur[i]}
			[[ -n $kid ]] || continue
			id=$(dconf read "$base/$kid/application-id" 2>/dev/null)
			id=${id#\'}
			id=${id%\'}
			[[ $id == "${MIGRATE_OLD_SLUGS[s]}".* || $id == "${MIGRATE_OLD_SLUGS[s]//-/_}".* ]] || continue
			new=$(migrate_map_id "$id") || continue
			newkid=$(migrate_child_name "$new")
			exists=0
			[[ " ${cur[*]} " == *" $newkid "* || -n $(dconf list "$base/$newkid/" 2>/dev/null) ]] && exists=1
			if ((exists)) && ! mig_child_default "$base/$newkid"; then
				mig_v "notifications: $newkid has your settings, keeping them (and $kid)"
				continue
			fi
			mig_note "notification settings $kid -> $newkid"
			changed=1
			if ((!DRY_RUN)); then
				if dconf dump "$base/$kid/" | sed "s|^application-id=.*|application-id='$new'|" | dconf load "$base/$newkid/"; then
					dconf reset -f "$base/$kid/"
				else
					warn "migrate: could not copy notification settings $kid -> $newkid"
					continue
				fi
			fi
			if [[ " ${cur[*]} " == *" $newkid "* ]]; then cur[i]=""; else cur[i]=$newkid; fi
		done
	done
	((changed)) || return 0
	for kid in "${cur[@]}"; do [[ -n $kid ]] && out+=("$kid"); done
	run_cmd dconf write "$kids_key" "$(mig_list_format "${out[@]}")"
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
	local n=$MIGRATE_NEW_SLUG i s from_version=unknown found=() v f base from to
	local -a disabled=()
	MIG_CHANGES=0
	MIG_RELOGIN=0
	MIG_DRAWER_SKIPPED=0
	info "migrate: start (dry-run=$DRY_RUN)"
	if [[ -n $MIG_STATE_EARLY ]]; then
		found+=("$MIG_STATE_EARLY")
		mig_note "the state directory moved first: $MIG_STATE_EARLY -> $n"
	fi

	# Newest slug first: it wins the move, older ones only add what is missing.
	for ((i = ${#MIGRATE_OLD_SLUGS[@]} - 1; i >= 0; i--)); do
		s=${MIGRATE_OLD_SLUGS[i]}
		if [[ -d $cfg/$s || -d $data/$s || -d $state/$s || -d $libexec/$s ]]; then
			[[ " ${found[*]} " == *" $s "* ]] || found+=("$s")
			if [[ $from_version == unknown && -r $data/$s/src/VERSION ]]; then
				from_version=$(<"$data/$s/src/VERSION")
			fi
		fi
		mig_move_dir "$cfg/$s" "$cfg/$n"
		if mig_data_held "$data/$s"; then
			MIG_DRAWER_SKIPPED=1
			warn "migrate: files under $data/$s are still open (the drawer or its web processes); its data stays until they close: log out, then run \`ostrich update\` again (everything else moved)"
		elif [[ $LIB_DIR/ == "$data/$s/src/"* ]]; then
			warn "migrate: this installer runs from $data/$s/src; $data/$s stays until it is run from elsewhere"
		else
			# The old copy of the installer's source is only a cache: a fresh one is fetched.
			if [[ -d $data/$s/src ]]; then
				mig_note "drop the old source copy $data/$s/src"
				run_cmd rm -rf "$data/$s/src"
			fi
			mig_move_dir "$data/$s" "$data/$n"
		fi
		for f in "${MIGRATE_USER_FILES[@]}"; do
			IFS='|' read -r base from to <<<"$f"
			[[ $base == config ]] && base=$cfg || base=$data
			mig_move_path "$base/$(mig_sub "$from" "$s")" "$base/$(mig_sub "$to" "$s")"
		done
		if [[ -d $state/$s ]]; then
			mig_move_dir "$state/$s" "$state/$n"
			if ((!DRY_RUN)) && [[ ! -d $state/$s ]]; then mig_repoint "$state/$s" "$state/$n"; fi
		fi
		mig_move_dir "$libexec/$s" "$libexec/$n"
		mig_dconf_copy "/org/gnome/shell/extensions/$s/" "/org/gnome/shell/extensions/$n/"
	done

	for s in "${found[@]}"; do mig_refs "$s" "$cfg" "$data"; done

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

# mig_old_install_present: something from an earlier name is still in the home.
mig_old_install_present() {
	local cfg=${XDG_CONFIG_HOME:-$HOME/.config} data=${XDG_DATA_HOME:-$HOME/.local/share}
	local state=${XDG_STATE_HOME:-$HOME/.local/state} s
	for s in "${MIGRATE_OLD_SLUGS[@]}"; do
		[[ -d $cfg/$s || -d $data/$s || -d $state/$s || -d $HOME/.local/libexec/$s ]] && return 0
	done
	return 1
}

# migrate_stop_apps: before anything moves, and only when an earlier install is there. For each of
# our apps (under any old or the new libexec dir): app.quit over D-Bus if the app exports it, else
# SIGTERM. Then it waits up to MIG_STOP_WAIT seconds (15) until no process has a file open under
# an old data dir: that covers WebKit's own processes, which outlive the drawer a moment. It
# never sends SIGKILL. A 0.5.0 drawer has no app.quit and gets SIGTERM; SQLite with its -wal and
# -shm moved together is consistent after a terminated process. Files still held after the wait:
# migrate_run leaves that data dir where it is and install.sh says to log out and run again.
migrate_stop_apps() {
	local libexec=$HOME/.local/libexec data=${XDG_DATA_HOME:-$HOME/.local/share}
	local uid=${UID:-$(id -u)} s u kind name path pid cmd held acts
	local -A quit_ok=()
	mig_old_install_present || return 0
	if ((DRY_RUN)); then
		info "migrate: would stop our running apps (app.quit where exported, else SIGTERM) and wait for their files to close"
		return 0
	fi
	for s in "${MIGRATE_OLD_SLUGS[@]}" "$MIGRATE_NEW_SLUG"; do
		for u in "$s" "${s//-/_}"; do
			[[ $s == "$MIGRATE_NEW_SLUG" ]] && u=$MIGRATE_NEW_APP
			for kind in drawer store setup; do
				name=$u.$kind
				path=/${name//./\/}
				path=${path//-/_}
				acts=$(gdbus call --session --dest "$name" --object-path "$path" --method org.gtk.Actions.List 2>/dev/null) || continue
				[[ $acts == *"'quit'"* ]] || continue
				if gdbus call --session --dest "$name" --object-path "$path" --method org.gtk.Actions.Activate quit '[]' '{}' >/dev/null 2>&1; then
					info "migrate: asked $name to quit"
					quit_ok[$kind]=1
				fi
			done
		done
		for pid in $(pgrep -u "$uid" -f -- "$libexec/$s/" 2>/dev/null); do
			cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || continue
			kind=other
			case $cmd in
			*ostrich-drawer*) kind=drawer ;;
			*ostrich-store*) kind=store ;;
			*ostrich-setup*) kind=setup ;;
			esac
			[[ -n ${quit_ok[$kind]:-} ]] && continue
			info "migrate: pid $pid ($kind) has no app.quit: asking it to stop (SIGTERM)"
			kill -TERM "$pid" 2>/dev/null || true
		done
	done
	# A deadline, not a count: each check scans every file under the dir.
	local end=$((SECONDS + ${MIG_STOP_WAIT:-15}))
	while ((SECONDS < end)); do
		held=0
		for s in "${MIGRATE_OLD_SLUGS[@]}"; do
			mig_data_held "$data/$s" && held=1
		done
		((held)) || return 0
		sleep 0.5
	done
	warn "migrate: files under an old data dir are still open after ${MIG_STOP_WAIT:-15} s; that data stays where it is until they close (log out, then run \`ostrich update\` again)"
	return 0
}

# migrate_root_pending: an old root-owned item is still there (the boot-time cleanup has work).
migrate_root_pending() {
	local s pair f
	shopt -s nullglob
	for s in "${MIGRATE_OLD_SLUGS[@]}"; do
		for pair in "${MIGRATE_ROOT_REPLACED[@]}" "${MIGRATE_ROOT_MOVED[@]}"; do
			[[ -e $MIGRATE_ROOT$(mig_sub "${pair%%|*}" "$s") ]] && {
				shopt -u nullglob
				return 0
			}
		done
		for f in "$MIGRATE_ROOT/etc/apparmor.d/$s"-github-*; do
			shopt -u nullglob
			return 0
		done
	done
	shopt -u nullglob
	return 1
}

# migrate_finish: after the modules installed the new extensions, launchers and apps. Removes what
# the old names left behind: old extension folders (once the new one is installed), old launchers
# and autostart entries, then refreshes the desktop database. Also swaps the Store's AppArmor
# profiles (root, through $SUDO) because their paths follow the data dir.
migrate_finish() {
	local data=${XDG_DATA_HOME:-$HOME/.local/share} cfg=${XDG_CONFIG_HOME:-$HOME/.config}
	local s u f removed=0
	mig_extension_dirs "$data/gnome-shell/extensions"
	shopt -s nullglob
	for s in "${MIGRATE_OLD_SLUGS[@]}"; do
		for u in "$s" "${s//-/_}"; do
			for f in "$data/applications/$u".*.desktop "$cfg/autostart/$u".*.desktop; do
				mig_note "remove old launcher $f"
				run_cmd rm -f -- "$f"
				removed=1
			done
		done
		# Autostart entries the tools module rewrites for the new paths; one it didn't is stale.
		for f in "$cfg"/autostart/*.desktop; do
			grep -q "libexec/$s/" "$f" || continue
			mig_note "remove stale autostart entry $f"
			run_cmd rm -f -- "$f"
			removed=1
		done
		for f in "$cfg/$s" "$data/$s" "${XDG_STATE_HOME:-$HOME/.local/state}/$s" "$HOME/.local/libexec/$s"; do
			[[ -d $f ]] && rmdir "$f" 2>/dev/null && mig_v "removed the empty $f"
		done
		for f in "$data"/icons/hicolor/*/apps/"$s"-*; do
			mig_note "remove old icon $f"
			run_cmd rm -f -- "$f"
		done
	done
	shopt -u nullglob
	if ((removed && !DRY_RUN)) && command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database "$data/applications" || true
	fi
	mig_apparmor
}

mig_apparmor() {
	local s old new tmp
	shopt -s nullglob
	for s in "${MIGRATE_OLD_SLUGS[@]}"; do
		for old in "$MIGRATE_ROOT/etc/apparmor.d/$s"-github-*; do
			new=${old/"/$s-github-"/"/$MIGRATE_NEW_SLUG-github-"}
			mig_note "AppArmor profile $old -> $new"
			if [[ ! -e $new ]]; then
				tmp=$(mktemp)
				sed "s|profile $s-github-|profile $MIGRATE_NEW_SLUG-github-|; s|/share/$s/|/share/$MIGRATE_NEW_SLUG/|" "$old" >"$tmp"
				mig_root install -m 644 "$tmp" "$new"
				mig_root apparmor_parser -r "$new" || warn "migrate: could not load $new"
				rm -f "$tmp"
			fi
			mig_root apparmor_parser -R "$old" >/dev/null 2>&1 || true
			mig_root rm -f "$old"
		done
	done
	shopt -u nullglob
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
	shopt -s nullglob
	for s in "${MIGRATE_OLD_SLUGS[@]}"; do
		for pair in "${MIGRATE_ROOT_REPLACED[@]}"; do
			old=$MIGRATE_ROOT$(mig_sub "${pair%%|*}" "$s")
			new=$MIGRATE_ROOT$(mig_sub "${pair##*|}" "$s")
			[[ -e $old && $old != "$new" ]] || continue
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
		# Store sandbox profiles: an old one goes only when its new twin is in place.
		for old in "$MIGRATE_ROOT/etc/apparmor.d/$s"-github-*; do
			new=${old/"/$s-github-"/"/$MIGRATE_NEW_SLUG-github-"}
			[[ -e $new ]] || continue
			mig_note "remove superseded AppArmor profile $old"
			mig_root apparmor_parser -R "$old" >/dev/null 2>&1 || true
			mig_root rm -f "$old"
		done
	done
	shopt -u nullglob
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
