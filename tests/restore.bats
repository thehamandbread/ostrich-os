#!/usr/bin/env bats
# tests/restore.bats: the restore point, the bookkeeping of what the installer changes, and
# `ostrich uninstall` putting it back. Throwaway HOME; dconf, gsettings, sudo and systemctl stubbed.

setup() {
	export HOME="$BATS_TEST_TMPDIR/home" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
	export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
	mkdir -p "$HOME" "$XDG_CONFIG_HOME"
	ROOT="$BATS_TEST_DIRNAME/.."
	STUBS="$BATS_TEST_TMPDIR/bin" CALLS="$BATS_TEST_TMPDIR/calls"
	export CALLS DCONF="$BATS_TEST_TMPDIR/dconf.db"
	mkdir -p "$STUBS"
	: >"$CALLS"
	printf '[org/gnome/desktop/interface]\ncolor-scheme=%s\n' "'prefer-dark'" >"$DCONF"
	stub dconf 'case $1 in
dump) cat "$DCONF" ;;
load) echo "dconf load" >>"$CALLS"; cat >"$DCONF" ;;
reset) echo "dconf reset $*" >>"$CALLS"; [[ $2 == -f && $3 == / ]] && : >"$DCONF"; true ;;
*) echo "dconf $*" >>"$CALLS" ;;
esac'
	stub gsettings 'case $1 in
list-schemas) echo org.gnome.shell ;;
get) echo "['"'"'mine@someone'"'"']" ;;
*) echo "gsettings $*" >>"$CALLS" ;;
esac'
	stub sudo 'echo "sudo $*" >>"$CALLS"'
	stub systemctl 'echo "systemctl $*" >>"$CALLS"; false'
	stub apt-mark 'printf "git\nvim\n"'
	export PATH="$STUBS:$PATH"
	export DRY_RUN=0 STATE_DIR="$XDG_STATE_HOME/ostrich-os"
	export LOG_FILE="$BATS_TEST_TMPDIR/install.log" RESTORE_DIR="$STATE_DIR/restore/original"
	export EXT_HOME="$XDG_DATA_HOME/gnome-shell/extensions"
}

stub() {
	printf '#!/usr/bin/env bash\n%s\n' "$2" >"$STUBS/$1"
	chmod +x "$STUBS/$1"
}

# Runs bash with the installer's libraries loaded, then the given commands.
with_libs() {
	bash -c "set -euo pipefail; LIB_DIR='$ROOT/lib'; source '$ROOT/lib/logging.sh'; source '$ROOT/lib/backup.sh'; source '$ROOT/lib/restore.sh'; source '$ROOT/lib/pkg.sh'; source '$ROOT/lib/gsettings.sh'; source '$ROOT/lib/helper.sh'; source '$ROOT/lib/uninstall.sh'; $1"
}

@test "restore point: settings, extensions and packages, taken only once" {
	mkdir -p "$EXT_HOME/mine@someone" && echo x >"$EXT_HOME/mine@someone/extension.js"
	run with_libs take_restore_point
	[ "$status" -eq 0 ]
	grep -q "prefer-dark" "$RESTORE_DIR/dconf.ini"
	tar -tzf "$RESTORE_DIR/extensions.tar.gz" | grep -q 'mine@someone/extension.js'
	grep -qx vim "$RESTORE_DIR/packages.txt"
	printf '[x]\ny=1\n' >"$DCONF"
	run with_libs take_restore_point
	grep -q "prefer-dark" "$RESTORE_DIR/dconf.ini" # the first one stays
}

@test "bookkeeping: new files are 'created', replaced files keep their first original" {
	with_libs take_restore_point
	echo theirs >"$HOME/.bashrc"
	echo ours1 >"$BATS_TEST_TMPDIR/src1"
	echo ours2 >"$BATS_TEST_TMPDIR/src2"
	with_libs "install_file '$BATS_TEST_TMPDIR/src1' '$HOME/.local/bin/ostrich'; install_file '$BATS_TEST_TMPDIR/src1' '$HOME/.bashrc'"
	BACKUP_DIR="$BATS_TEST_TMPDIR/b2" with_libs "install_file '$BATS_TEST_TMPDIR/src2' '$HOME/.bashrc'; install_file '$BATS_TEST_TMPDIR/src2' '$HOME/.local/bin/ostrich'"
	grep -qx "$HOME/.local/bin/ostrich" "$RESTORE_DIR/created.txt"
	[ "$(grep -c "^$HOME/.bashrc	" "$RESTORE_DIR/originals.txt")" -eq 1 ]
	[ "$(cat "$(grep "^$HOME/.bashrc	" "$RESTORE_DIR/originals.txt" | cut -f2)")" = theirs ]
	! grep -q "ostrich	" "$RESTORE_DIR/originals.txt" # our own file is never an "original"
}

@test "bookkeeping: a symlinked folder doesn't make our own file an original" {
	with_libs take_restore_point
	mkdir -p "$HOME/real-bin" "$HOME/.local"
	ln -s "$HOME/real-bin" "$HOME/.local/bin"
	echo ours1 >"$BATS_TEST_TMPDIR/src1"
	echo ours2 >"$BATS_TEST_TMPDIR/src2"
	with_libs "install_file '$BATS_TEST_TMPDIR/src1' '$HOME/.local/bin/ostrich'"
	BACKUP_DIR="$BATS_TEST_TMPDIR/b2" with_libs "install_file '$BATS_TEST_TMPDIR/src2' '$HOME/.local/bin/ostrich'"
	! grep -q "ostrich	" "$RESTORE_DIR/originals.txt"
}

@test "uninstall: puts files, extensions and settings back, removes ours" {
	mkdir -p "$EXT_HOME/mine@someone" && echo x >"$EXT_HOME/mine@someone/extension.js"
	echo theirs >"$HOME/.bashrc"
	with_libs take_restore_point
	echo ours >"$BATS_TEST_TMPDIR/src"
	with_libs "install_file '$BATS_TEST_TMPDIR/src' '$HOME/.bashrc'; install_file '$BATS_TEST_TMPDIR/src' '$HOME/.local/bin/ostrich'"
	rm -rf "$EXT_HOME/mine@someone" # as if it had been removed
	mkdir -p "$EXT_HOME/dock@ostrich-os"
	# An update before this fix saved our own v1 extension as an "original": it must not come back.
	mkdir -p "$BATS_TEST_TMPDIR/old/dock@ostrich-os"
	printf '%s\t%s\n' "$EXT_HOME/dock@ostrich-os" "$BATS_TEST_TMPDIR/old/dock@ostrich-os" >>"$RESTORE_DIR/originals.txt"
	mkdir -p "$XDG_CONFIG_HOME/gtk-4.0"
	printf 'mine { }\n/* ostrich-os theme: begin (managed) */\n@define-color x red;\n/* ostrich-os theme: end */\n' >"$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
	printf '[x]\ny=1\n' >"$DCONF"
	mkdir -p "$XDG_DATA_HOME/ostrich-os/drawer" "$XDG_DATA_HOME/ostrich-os/vm"
	touch "$STATE_DIR/store-pinned"
	mkdir -p "$XDG_CONFIG_HOME/ostrich-os/schemes" "$XDG_CONFIG_HOME/ostrich-os/scheme" "$XDG_DATA_HOME/backgrounds/ostrich-os"
	touch "$XDG_CONFIG_HOME/ostrich-os/schemes/mine.toml" "$XDG_CONFIG_HOME/ostrich-os/scheme/blur.css" "$XDG_DATA_HOME/backgrounds/ostrich-os/forest.svg"
	mkdir -p "$XDG_CONFIG_HOME/ostrich-os/environments"
	echo '[[service]]' >"$XDG_CONFIG_HOME/ostrich-os/drawer.toml"
	echo '{}' >"$XDG_CONFIG_HOME/ostrich-os/environments/work.json"
	run with_libs "YES=1 KEEP_NEW_SETTINGS=0 REMOVE_PACKAGES=0 uninstall_main"
	[ "$status" -eq 0 ]
	# What the user made is copied, not lost, and the last line says where.
	[ -f "$STATE_DIR"/restore/used-*/yours/drawer.toml ] && [ -f "$STATE_DIR"/restore/used-*/yours/environments/work.json ]
	[[ ${lines[-1]} == *"/yours"* ]]
	[ ! -e "$XDG_DATA_HOME/ostrich-os/drawer" ]
	[ -f "$XDG_CONFIG_HOME/ostrich-os/schemes/mine.toml" ] # schemes you made stay
	[ ! -e "$XDG_CONFIG_HOME/ostrich-os/scheme" ] && [ ! -e "$XDG_DATA_HOME/backgrounds/ostrich-os" ]
	[ -d "$XDG_DATA_HOME/ostrich-os/vm" ] # not ours: the test VMs live there
	[ "$(cat "$HOME/.bashrc")" = theirs ]
	[ ! -e "$HOME/.local/bin/ostrich" ]
	[ ! -e "$EXT_HOME/dock@ostrich-os" ]
	[ -f "$EXT_HOME/mine@someone/extension.js" ]
	grep -q prefer-dark "$DCONF"
	[ "$(cat "$XDG_CONFIG_HOME/gtk-4.0/gtk.css")" = "mine { }" ]
	ls "$STATE_DIR"/restore/used-* >/dev/null # a later install takes a fresh restore point
	[ ! -e "$STATE_DIR/store-pinned" ]        # and pins the Store again
}

@test "uninstall: your later edits to files it puts back or removes are kept" {
	echo theirs >"$HOME/.bashrc"
	with_libs take_restore_point
	echo ours >"$BATS_TEST_TMPDIR/src"
	with_libs "install_file '$BATS_TEST_TMPDIR/src' '$HOME/.bashrc'; install_file '$BATS_TEST_TMPDIR/src' '$HOME/.gitconfig'; install_file '$BATS_TEST_TMPDIR/src' '$HOME/.local/bin/ostrich'"
	echo 'export NVM_DIR=~/.nvm' >>"$HOME/.bashrc"      # a tool added a line since
	printf '[user]\n\tname = Me\n' >>"$HOME/.gitconfig" # git config --global since
	run with_libs "YES=1 KEEP_NEW_SETTINGS=0 REMOVE_PACKAGES=0 uninstall_main"
	[ "$status" -eq 0 ]
	[ "$(cat "$HOME/.bashrc")" = theirs ] # put back
	[ ! -e "$HOME/.gitconfig" ]           # it created it: removed
	kept=$(echo "$STATE_DIR"/restore/used-*/yours/files)
	grep -q NVM_DIR "$kept$HOME/.bashrc"
	grep -q 'name = Me' "$kept$HOME/.gitconfig"
	[ ! -e "$kept$HOME/.local/bin/ostrich" ] # our own program isn't "yours"
}

@test "uninstall --dry-run changes nothing" {
	echo theirs >"$HOME/.bashrc"
	with_libs take_restore_point
	echo ours >"$BATS_TEST_TMPDIR/src"
	with_libs "install_file '$BATS_TEST_TMPDIR/src' '$HOME/.bashrc'"
	run with_libs "DRY_RUN=1 YES=1 KEEP_NEW_SETTINGS=0 REMOVE_PACKAGES=0 uninstall_main"
	[ "$status" -eq 0 ]
	[ "$(cat "$HOME/.bashrc")" = ours ]
	[ -f "$RESTORE_DIR/dconf.ini" ]
	! grep -q 'dconf load' "$CALLS"
}

@test "uninstall without a restore point refuses" {
	run with_libs "YES=1 KEEP_NEW_SETTINGS=0 REMOVE_PACKAGES=0 uninstall_main"
	[ "$status" -ne 0 ]
	[[ $output == *"no restore point"* ]]
}

@test "uninstall --keep-new-settings puts App Center back in the Store's place" {
	with_libs take_restore_point
	echo "['firefox_firefox.desktop', 'ostrich_os.store.desktop', 'mine.desktop']" >"$BATS_TEST_TMPDIR/favs"
	stub gsettings 'f="$BATS_TEST_TMPDIR/favs"; case $1 in list-schemas) echo org.gnome.shell ;;
get) if [[ $3 == favorite-apps ]]; then cat "$f"; else echo "@as []"; fi ;;
set) if [[ $3 == favorite-apps ]]; then echo "$4" >"$f"; fi ;; esac'
	run with_libs "YES=1 KEEP_NEW_SETTINGS=1 REMOVE_PACKAGES=0 uninstall_main"
	[ "$status" -eq 0 ]
	[ "$(cat "$BATS_TEST_TMPDIR/favs")" = "['firefox_firefox.desktop', 'snap-store_snap-store.desktop', 'mine.desktop']" ]
}

@test "uninstall: root removes only our own system files, whatever the lists say" {
	with_libs take_restore_point
	printf '%s\n' /usr/libexec/ostrich-os/system-helper /tmp/ostrich-canary /etc/systemd/system/ostrich-os-../../passwd >"$RESTORE_DIR/created-root.txt"
	printf '%s\t%s\n' /etc/passwd /tmp/evil >"$RESTORE_DIR/originals-root.txt"
	touch /tmp/evil
	run with_libs "SUDO=sudo YES=1 KEEP_NEW_SETTINGS=0 REMOVE_PACKAGES=0 uninstall_main"
	[ "$status" -eq 0 ]
	grep -q 'sudo rm -f -- /usr/libexec/ostrich-os/system-helper' "$CALLS"
	! grep -q 'canary\|passwd' "$CALLS"
	rm -f /tmp/evil
}

@test "uninstall --keep-new-settings undoes a colour scheme that is still on" {
	with_libs take_restore_point
	mkdir -p "$XDG_CONFIG_HOME/ostrich-os/scheme/before"
	printf 'org.gnome.desktop.background\tpicture-uri\tfile:///usr/share/a.png\norg.gnome.desktop.interface\taccent-color\tteal\n' >"$XDG_CONFIG_HOME/ostrich-os/scheme/before/settings"
	stub gsettings 'case $1 in list-schemas) echo org.gnome.shell ;;
get) [[ $3 == picture-uri ]] && echo "'"'"'file:///home/u/.local/share/backgrounds/ostrich-os/forest.svg'"'"'" || echo "@as []" ;;
*) echo "gsettings $*" >>"$CALLS" ;; esac'
	run with_libs "YES=1 KEEP_NEW_SETTINGS=1 REMOVE_PACKAGES=0 uninstall_main"
	[ "$status" -eq 0 ]
	grep -q 'gsettings set org.gnome.desktop.background picture-uri file:///usr/share/a.png' "$CALLS"
	grep -q 'gsettings set org.gnome.desktop.interface accent-color teal' "$CALLS"
}

@test "no dconf at install: uninstall resets only our own settings" {
	with_libs take_restore_point
	: >"$RESTORE_DIR/dconf.ini" && touch "$RESTORE_DIR/no-dconf" # as if dconf had been missing
	run with_libs "YES=1 KEEP_NEW_SETTINGS=0 REMOVE_PACKAGES=0 uninstall_main"
	[ "$status" -eq 0 ]
	! grep -q 'reset -f /$' "$CALLS"
	grep -q 'reset -f /org/gnome/shell/extensions/ostrich-os/' "$CALLS"
}

@test "restore point: a failed settings dump stops the install" {
	stub dconf 'exit 1'
	run with_libs take_restore_point
	[ "$status" -ne 0 ]
	[ ! -e "$RESTORE_DIR/dconf.ini" ]
}
