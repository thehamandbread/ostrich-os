#!/usr/bin/env bash
# lib/restore.sh: the restore point taken before the first install, so `ostrich uninstall` can put
# the machine back exactly as it was. Source after logging.sh and backup.sh.
#
# $RESTORE_DIR (written once; later runs never overwrite it):
#   dconf.ini            every user setting (`dconf dump /`)
#   extensions.tar.gz    ~/.local/share/gnome-shell/extensions as it was
#   enabled.txt / disabled.txt   GNOME's extension lists
#   packages.txt         `apt-mark showmanual`
#   flatpak-remotes.txt, prime-mode, version, date
# and, filled in as the modules run (lib/backup.sh, lib/helper.sh):
#   created.txt          files we created (didn't exist before)
#   originals.txt        "<path>\t<copy of the original>" for files we replaced
#   created-root.txt / originals-root.txt   the same for system files (sudo)

RESTORE_DIR="${RESTORE_DIR:-${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ubuntu-ostrich}/restore/original}"
EXT_HOME="${EXT_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions}"

# take_restore_point: only on the first install (or the first after an uninstall).
take_restore_point() {
	if [[ -f $RESTORE_DIR/dconf.ini ]]; then
		info "restore point: $RESTORE_DIR (taken $(cat "$RESTORE_DIR/date" 2>/dev/null))"
		return 0
	fi
	if ((DRY_RUN)); then
		log WOULD "take a restore point in $RESTORE_DIR (settings, extensions, packages)"
		return 0
	fi
	mkdir -p "$RESTORE_DIR"
	chmod 700 "$RESTORE_DIR"
	if command -v dconf >/dev/null 2>&1; then
		# An empty file must mean "no settings yet", never "the dump failed": uninstall resets to it.
		dconf dump / >"$RESTORE_DIR/dconf.ini" || {
			rm -f "$RESTORE_DIR/dconf.ini"
			die "couldn't save your settings (dconf dump failed); nothing changed"
		}
	else
		: >"$RESTORE_DIR/dconf.ini"
		touch "$RESTORE_DIR/no-dconf" # uninstall then resets only our own settings
	fi
	if command -v gsettings >/dev/null 2>&1 && gsettings list-schemas 2>/dev/null | grep -qx org.gnome.shell; then
		gsettings get org.gnome.shell enabled-extensions >"$RESTORE_DIR/enabled.txt"
		gsettings get org.gnome.shell disabled-extensions >"$RESTORE_DIR/disabled.txt"
	fi
	if [[ -d $EXT_HOME ]]; then
		tar -C "$EXT_HOME" -czf "$RESTORE_DIR/extensions.tar.gz" .
	fi
	command -v apt-mark >/dev/null 2>&1 && apt-mark showmanual 2>/dev/null | LC_ALL=C sort >"$RESTORE_DIR/packages.txt"
	command -v flatpak >/dev/null 2>&1 && flatpak remotes --columns=name 2>/dev/null >"$RESTORE_DIR/flatpak-remotes.txt"
	command -v prime-select >/dev/null 2>&1 && prime-select query 2>/dev/null >"$RESTORE_DIR/prime-mode"
	: >"$RESTORE_DIR/created.txt"
	: >"$RESTORE_DIR/originals.txt"
	: >"$RESTORE_DIR/created-root.txt"
	: >"$RESTORE_DIR/originals-root.txt"
	cat "$(dirname "${BASH_SOURCE[0]}")/../VERSION" >"$RESTORE_DIR/version" 2>/dev/null || true
	date '+%Y-%m-%d %H:%M' >"$RESTORE_DIR/date"
	changed "took a restore point: $RESTORE_DIR (ostrich uninstall puts everything back)"
}
