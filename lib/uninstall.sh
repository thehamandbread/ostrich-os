#!/usr/bin/env bash
# lib/uninstall.sh: `ostrich uninstall` (install.sh --uninstall). Puts the machine back the way the
# restore point (lib/restore.sh) recorded it. Source after logging.sh, backup.sh, pkg.sh, gsettings.sh.
#
# Options (set by install.sh): YES=1 skips the question; KEEP_NEW_SETTINGS=1 restores only the
# settings Ostrich OS changed instead of all of them; REMOVE_PACKAGES=1 also removes the apt
# packages it added. DRY_RUN=1 only lists what would happen.
#
# Kept on purpose: apps you installed with `ostrich store` (Flatpaks, and GitHub apps in
# ~/.local/share/ostrich-os/github with their launchers), colour schemes you made
# (~/.config/ostrich-os/schemes) and the restore point itself
# (renamed to restore/used-<date>, so a later install takes a fresh one).

OUR_SUFFIX=@ostrich-os
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"

# Removes our marked block from a file the theme tool edits (it keeps everything else).
strip_theme_block() {
	local f=$1
	[[ -f $f ]] && grep -q 'ostrich-os theme: begin' "$f" || return 0
	changed "remove the Ostrich OS block from $f"
	((DRY_RUN)) && return 0
	sed -i '/ostrich-os theme: begin/,/ostrich-os theme: end/d' "$f"
	[[ -s $f ]] || rm -f "$f"
}

# Root only removes or puts back files the installer writes: the lists it reads are the user's.
ours_root() {
	case $1 in
	/usr/libexec/ostrich-os/* | /usr/share/polkit-1/actions/org.ostrich-os.* | \
		/etc/modprobe.d/ostrich-os-* | /etc/systemd/system/ostrich-os-* | \
		/etc/udev/rules.d/90-ostrich-os* | \
		/usr/libexec/ubuntu-ostrich/* | /usr/share/polkit-1/actions/org.ubuntu-ostrich.* | \
		/etc/modprobe.d/ubuntu-ostrich-* | /etc/systemd/system/ubuntu-ostrich-* | \
		/etc/udev/rules.d/90-ubuntu-ostrich*) [[ $1 != *..* ]] && return 0 ;; # the older names: restore points made before 0.6.0
	esac
	warn "not ours, left alone: $1"
	return 1
}

# keep_current <path>: a copy of a file in your home as it is now, in the kept restore point's
# yours/files (the same tree), before uninstall replaces or removes it. Only regular text-sized files
# outside our own folders: the programs and extensions we installed are ours to remove.
keep_current() {
	local path=$1
	[[ -f $path && ! -L $path && $path == "$HOME"/* ]] || return 0
	case $path in
	"$HOME"/.local/bin/* | "$HOME"/.local/libexec/* | "$HOME"/.local/share/gnome-shell/extensions/*) return 0 ;;
	esac
	(($(stat -c %s "$path") <= 1048576)) || return 0
	changed "keep your current $path in $KEPT/yours/files"
	((DRY_RUN)) || { mkdir -p "$RESTORE_DIR/yours/files$(dirname "$path")" && cp -a "$path" "$RESTORE_DIR/yours/files$path"; }
}

remove_path() {
	[[ -e $1 || -L $1 ]] || return 0
	changed "remove $1"
	run_cmd rm -rf -- "$1"
}

# The dock without the Store, the rest as the user has it now: App Center goes back in the Store's
# place if it was in the dock before (Ubuntu's default dock has it, so no saved list counts as yes).
unpin_store() {
	local store=ostrich_os.store.desktop center=snap-store_snap-store.desktop f new="" back=1
	local -a favs
	mapfile -t favs < <(gs_list org.gnome.shell favorite-apps)
	printf '%s\n' "${favs[@]}" | grep -qxF "$store" || return 0
	grep -q '^favorite-apps=' "$RESTORE_DIR/dconf.ini" && ! grep -q "^favorite-apps=.*'$center'" "$RESTORE_DIR/dconf.ini" && back=0
	printf '%s\n' "${favs[@]}" | grep -qxF "$center" && back=0
	for f in "${favs[@]}"; do
		if [[ $f == "$store" ]]; then
			((back)) || continue
			f=$center
		fi
		new+="${new:+, }'$f'"
	done
	gs_set org.gnome.shell favorite-apps "[$new]"
}

uninstall_main() {
	[[ -f $RESTORE_DIR/dconf.ini ]] ||
		die "no restore point in $RESTORE_DIR, so there's nothing to put back. (Installs from before restore points existed can't be undone automatically.)"
	# The restore point is kept under this name afterwards (a later install takes a fresh one).
	KEPT="$(dirname "$RESTORE_DIR")/used-$(date '+%Y%m%dT%H%M%S')"
	# Without dconf at install time there's no snapshot to reset to: only our own settings go back.
	[[ -e $RESTORE_DIR/no-dconf ]] && KEEP_NEW_SETTINGS=1

	cat >&2 <<EOF

  Uninstall Ostrich OS
  ------------------------
  This puts back what you had before $(cat "$RESTORE_DIR/date" 2>/dev/null):
    - your extensions and their settings, and GNOME's settings$( ((KEEP_NEW_SETTINGS)) && printf ' (only the ones Ostrich OS changed)')
    - the files it replaced, and removes the ones it added
    - its system files (needs your password), and the graphics mode you had
  Kept: apps you installed with \`ostrich store\`.$( ((KEEP_NEW_SETTINGS)) || printf '\n  Note: settings you changed after installing go back too (use --keep-new-settings to keep them).')

EOF
	if ((!YES && !DRY_RUN)); then
		local answer=""
		read -r -p "  Continue? [y/N] " answer </dev/tty || true
		[[ $answer == [yY]* ]] || die "nothing changed"
	fi

	# 0. Our running apps (the drawer and its web pages, Ostrich Setup, the store): stopped now,
	# rather than left running until logout with their files gone.
	local apps="$HOME/.local/libexec/ostrich-os/"
	if pgrep -u "$(id -u)" -f -- "$apps" >/dev/null 2>&1; then
		changed "stop the running Ostrich OS apps"
		((DRY_RUN)) || pkill -u "$(id -u)" -f -- "$apps" || true
	fi

	# 1. Our extensions: off, and gone. 2. The extensions as they were (missing ones only).
	local e
	while IFS= read -r e; do
		[[ $e == *"$OUR_SUFFIX" ]] && gs_list_remove org.gnome.shell enabled-extensions "$e"
	done < <(gs_list org.gnome.shell enabled-extensions)
	for e in "$EXT_HOME"/*"$OUR_SUFFIX"; do
		[[ -e $e ]] && remove_path "$e"
	done
	if [[ -f $RESTORE_DIR/extensions.tar.gz ]]; then
		changed "put back extensions that were removed"
		((DRY_RUN)) || { mkdir -p "$EXT_HOME" && tar -C "$EXT_HOME" -xzf "$RESTORE_DIR/extensions.tar.gz" --skip-old-files; }
	fi

	# The Store's daily update check: off before its unit files go.
	if systemctl --user is-enabled --quiet ostrich-store-updates.timer 2>/dev/null; then
		run_cmd systemctl --user disable --now ostrich-store-updates.timer
	fi

	# 3. Files: ours removed, originals put back. Each one's current version is kept first: you or
	# your tools may have changed it since (lines in .bashrc, a git name in .gitconfig).
	local path copy
	while IFS= read -r path; do
		[[ -n $path ]] || continue
		keep_current "$path"
		remove_path "$path"
	done <"$RESTORE_DIR/created.txt"
	while IFS=$'\t' read -r path copy; do
		[[ -n $path && -e $copy ]] || continue
		[[ $path == *"$OUR_SUFFIX" ]] && continue # our own extension, saved by an earlier update
		keep_current "$path"
		changed "put back $path"
		((DRY_RUN)) || { mkdir -p "$(dirname "$path")" && rm -rf -- "$path" && cp -a "$copy" "$path"; }
	done <"$RESTORE_DIR/originals.txt"

	# 4. System files (sudo), the power unit, the graphics mode.
	if [[ -s $RESTORE_DIR/created-root.txt || -s $RESTORE_DIR/originals-root.txt || -e /etc/udev/rules.d/90-ostrich-os-touchscreen.rules ]] ||
		compgen -G '/etc/apparmor.d/ostrich-os-github-*' >/dev/null; then
		# A touchscreen switched off by the helper comes back on before the helper goes.
		[[ -x /usr/libexec/ostrich-os/system-helper ]] &&
			run_cmd "$SUDO" /usr/libexec/ostrich-os/system-helper touchscreen on >/dev/null 2>&1 || true
		# Power saver's knobs (boost, power limits, PCIe/USB power saving) back to the machine's own
		# before the helper goes; they'd otherwise stay until a reboot.
		[[ -x /usr/libexec/ostrich-os/system-helper ]] &&
			run_cmd "$SUDO" /usr/libexec/ostrich-os/system-helper power apply balanced >/dev/null 2>&1 || true
		if systemctl is-enabled --quiet ostrich-os-power.service 2>/dev/null; then
			run_cmd "$SUDO" systemctl disable ostrich-os-power.service
		fi
		# The boot-time cleanup of an earlier name's files, if it has not run yet (it removes itself).
		if systemctl is-enabled --quiet ostrich-os-cleanup-old.service 2>/dev/null; then
			run_cmd "$SUDO" systemctl disable ostrich-os-cleanup-old.service
		fi
		run_cmd "$SUDO" rm -rf /usr/libexec/ostrich-os/cleanup-old /etc/systemd/system/ostrich-os-cleanup-old.service
		while IFS= read -r path; do
			[[ -n $path ]] && ours_root "$path" && run_cmd "$SUDO" rm -f -- "$path"
		done <"$RESTORE_DIR/created-root.txt"
		while IFS=$'\t' read -r path copy; do
			[[ -n $path && -e $copy && ($copy == "$path.before-ostrich-os" || $copy == "$path.before-ubuntu-ostrich") ]] && ours_root "$path" &&
				run_cmd "$SUDO" mv -f -- "$copy" "$path"
		done <"$RESTORE_DIR/originals-root.txt"
		run_cmd "$SUDO" rm -f /etc/udev/rules.d/90-ostrich-os-touchscreen.rules
		# The Store's sandbox profiles for apps from GitHub (system-helper apparmor allow).
		local profile
		for profile in /etc/apparmor.d/ostrich-os-github-*; do
			[[ -f $profile ]] || continue
			run_cmd "$SUDO" apparmor_parser -R "$profile" >/dev/null 2>&1 || true
			run_cmd "$SUDO" rm -f -- "$profile"
		done
		run_cmd "$SUDO" rmdir --ignore-fail-on-non-empty /usr/libexec/ostrich-os
		run_cmd "$SUDO" systemctl daemon-reload
	fi
	if [[ -s $RESTORE_DIR/prime-mode ]] && command -v prime-select >/dev/null 2>&1; then
		local was now
		was=$(cat "$RESTORE_DIR/prime-mode")
		now=$(prime-select query 2>/dev/null || true)
		if [[ -n $was && $was != "$now" ]]; then
			changed "graphics mode $now -> $was (takes effect after you log out)"
			run_cmd "$SUDO" prime-select "$was"
		fi
	fi

	# 5. What the tools changed while you used them.
	strip_theme_block "$CFG/gtk-4.0/gtk.css"
	strip_theme_block "$CFG/gtk-3.0/gtk.css"
	remove_path "$CFG/ghostty/themes/ostrich-os"
	if [[ -e $CFG/pipewire/pipewire.conf.d/90-ostrich-os-speakers.conf ]]; then
		remove_path "$CFG/pipewire/pipewire.conf.d/90-ostrich-os-speakers.conf"
		run_cmd systemctl --user try-restart pipewire pipewire-pulse wireplumber
	fi
	local f
	for f in "$DATA"/applications/ostrich_os.drawer*.desktop "$CFG"/autostart/ostrich-*.desktop; do
		[[ -e $f ]] && remove_path "$f"
	done
	# A colour scheme still on: what it changed outside our files goes back to how it was before the
	# first one (the default path does this anyway with every other setting).
	local before="$CFG/ostrich-os/scheme/before/settings" schema key value
	if ((KEEP_NEW_SETTINGS)) && [[ -f $before ]]; then
		while IFS=$'\t' read -r schema key value; do
			# A wallpaper the user picked since stays; only ours (deleted below) goes back.
			[[ $key == picture-uri* && $(gsettings get "$schema" "$key" 2>/dev/null) != *"/backgrounds/ostrich-os/"* ]] && continue
			changed "$key back to $value"
			run_cmd gsettings set "$schema" "$key" "$value"
		done <"$before"
	fi
	# What you made with Ostrich (drawer sites, saved desktops, settings export) is copied into the
	# kept restore point before it goes.
	for f in drawer.toml environments settings.dconf; do
		[[ -e $CFG/ostrich-os/$f ]] || continue
		changed "keep a copy of $f in $KEPT/yours"
		((DRY_RUN)) || { mkdir -p "$RESTORE_DIR/yours" && rm -rf "$RESTORE_DIR/yours/$f" && cp -a "$CFG/ostrich-os/$f" "$RESTORE_DIR/yours/$f"; }
	done
	# Our config, except the colour schemes you made (they're yours, like Store apps).
	for f in "$CFG"/ostrich-os/* "$CFG"/ostrich-os/.[!.]*; do
		[[ -e $f && $f != "$CFG/ostrich-os/schemes" ]] && remove_path "$f"
	done
	rmdir --ignore-fail-on-non-empty "$CFG/ostrich-os" 2>/dev/null || true
	remove_path "$DATA/backgrounds/ostrich-os" # wallpapers drawn by `ostrich theme scheme`
	# One-time markers, so a later install starts fresh (pins the Store, sets the graphics default).
	for f in store-pinned graphics-default-set; do
		remove_path "$(dirname "$(dirname "$RESTORE_DIR")")/$f"
	done
	remove_path "$HOME/.local/libexec/ostrich-os"
	# Only what we put there: other things share this folder (tests/vm keeps its VMs in vm/). Store
	# apps (github/) stay; src (running this) goes last.
	for f in audio drawer; do
		[[ -e $DATA/ostrich-os/$f ]] && remove_path "$DATA/ostrich-os/$f"
	done

	# 6. Settings.
	if command -v dconf >/dev/null 2>&1; then
		if ((KEEP_NEW_SETTINGS)); then
			changed "reset Ostrich OS's own settings and the extension lists"
			run_cmd dconf reset -f /org/gnome/shell/extensions/ostrich-os/
			[[ -s $RESTORE_DIR/enabled.txt ]] && run_cmd gsettings set org.gnome.shell enabled-extensions "$(cat "$RESTORE_DIR/enabled.txt")"
			[[ -s $RESTORE_DIR/disabled.txt ]] && run_cmd gsettings set org.gnome.shell disabled-extensions "$(cat "$RESTORE_DIR/disabled.txt")"
			unpin_store
		else
			changed "put back every setting from $(cat "$RESTORE_DIR/date" 2>/dev/null)"
			if ((!DRY_RUN)); then
				dconf reset -f /
				dconf load / <"$RESTORE_DIR/dconf.ini"
			fi
		fi
	fi

	# 7. Packages it added (only when asked).
	if [[ -s $RESTORE_DIR/packages.txt ]] && command -v apt-mark >/dev/null 2>&1; then
		local -a added=()
		mapfile -t added < <(LC_ALL=C comm -13 <(LC_ALL=C sort "$RESTORE_DIR/packages.txt") <(apt-mark showmanual 2>/dev/null | LC_ALL=C sort))
		if ((${#added[@]} > 0)); then
			# Always asked, --yes or not: the list holds packages you installed yourself too.
			local answer="" go=$((REMOVE_PACKAGES && DRY_RUN))
			if ((REMOVE_PACKAGES && !go)); then
				# The list is everything installed since, yours too: say so and ask once more.
				printf '\n  These apt packages were installed since Ostrich OS, by it or by you:\n    %s\n' "${added[*]}" >&2
				read -r -p "  Type remove to remove them all: " answer </dev/tty || true
				[[ $answer == remove ]] && go=1
			fi
			if ((go)); then
				changed "remove packages added since the install: ${added[*]}"
				run_cmd "$SUDO" env DEBIAN_FRONTEND=noninteractive "${APT_GET[@]}" remove -y "${added[@]}"
			else
				info "packages added since the install (kept; run with --remove-packages to remove): ${added[*]}"
			fi
		fi
	fi

	if ((!DRY_RUN)); then
		mv "$RESTORE_DIR" "$KEPT"
		[[ -d $DATA/ostrich-os/src ]] && rm -rf -- "$DATA/ostrich-os/src"
		rm -f -- "$(dirname "$(dirname "$RESTORE_DIR")")/source"
		rmdir --ignore-fail-on-non-empty "$DATA/ostrich-os" 2>/dev/null || true
	fi
	info "Ostrich OS is uninstalled. Log out and back in to finish."
	[[ -d $KEPT/yours ]] && info "your drawer sites, saved desktops, settings export and files as they were: $KEPT/yours"
	return 0
}
