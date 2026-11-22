#!/usr/bin/env bash
# lib/helper.sh: install the privileged system helper and its polkit policy (shared by the
# hardware modules, each of which calls it only when its hardware is present). Source after pkg.sh.

HELPER_SRC="${HELPER_SRC:-$LIB_DIR/../dist/ostrich-system-helper}"
HELPER_DEST="${HELPER_DEST:-/usr/libexec/ostrich-os/system-helper}"
POLICY_SRC="$LIB_DIR/../modules/hardware/org.ostrich-os.system-helper.policy"
POLICY_DEST="${POLICY_DEST:-/usr/share/polkit-1/actions/org.ostrich-os.system-helper.policy}"

# sudo_install <src> <dest> <mode>: root-owned file; compared first, the old one kept beside it.
sudo_install() {
	local src=$1 dest=$2 mode=$3
	if [[ -f $dest ]] && cmp -s "$src" "$dest"; then
		return 0
	fi
	if [[ ! -e $dest ]]; then
		record_line created-root.txt "$dest"
	elif [[ ! -e $dest.before-ostrich-os ]] && ! grep -qxF -- "$dest" "$RESTORE_DIR/created-root.txt" 2>/dev/null; then
		# The machine's own file, kept once: later runs replace only our version.
		run_cmd "$SUDO" cp -a "$dest" "$dest.before-ostrich-os"
		record_line originals-root.txt "$dest	$dest.before-ostrich-os"
	fi
	changed "install $dest"
	run_cmd "$SUDO" install -D -m "$mode" "$src" "$dest"
}

# have_helper_build: 0 if the helper binary is staged (the tools module puts it in dist/).
have_helper_build() { [[ -x $HELPER_SRC ]]; }

install_system_helper() {
	sudo_install "$HELPER_SRC" "$HELPER_DEST" 0755
	sudo_install "$POLICY_SRC" "$POLICY_DEST" 0644
}

# install_cleanup_unit <repo> <marker>: the one-shot boot unit that removes the root-owned files an
# earlier name left (lib/migrate.sh migrate_root), at the next boot before anyone can log in, when
# no old extension or helper can be loaded. Everything it runs is root-owned: a copy of
# lib/migrate.sh and lib/logging.sh, not the user's checkout. Needs the migration marker to run.
CLEANUP_DIR="${CLEANUP_DIR:-/usr/libexec/ostrich-os/cleanup-old}"
CLEANUP_UNIT="${CLEANUP_UNIT:-/etc/systemd/system/ostrich-os-cleanup-old.service}"
install_cleanup_unit() {
	local repo=$1 marker=$2 tmp
	sudo_install "$repo/modules/core/ostrich-os-cleanup-old" "$CLEANUP_DIR/run" 0755
	sudo_install "$repo/lib/logging.sh" "$CLEANUP_DIR/logging.sh" 0644
	sudo_install "$repo/lib/migrate.sh" "$CLEANUP_DIR/migrate.sh" 0644
	tmp=$(mktemp)
	sed "s|@MARKER@|$marker|g" "$repo/modules/core/ostrich-os-cleanup-old.service" >"$tmp"
	sudo_install "$tmp" "$CLEANUP_UNIT" 0644
	rm -f "$tmp"
	run_cmd "$SUDO" systemctl daemon-reload
	run_cmd "$SUDO" systemctl enable ostrich-os-cleanup-old.service
}
