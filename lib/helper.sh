#!/usr/bin/env bash
# lib/helper.sh: install the privileged system helper and its polkit policy (shared by the
# hardware modules, each of which calls it only when its hardware is present). Source after pkg.sh.

HELPER_SRC="${HELPER_SRC:-$LIB_DIR/../dist/ostrich-system-helper}"
HELPER_DEST="${HELPER_DEST:-/usr/libexec/ubuntu-ostrich/system-helper}"
POLICY_SRC="$LIB_DIR/../modules/hardware/org.ubuntu-ostrich.system-helper.policy"
POLICY_DEST="${POLICY_DEST:-/usr/share/polkit-1/actions/org.ubuntu-ostrich.system-helper.policy}"

# sudo_install <src> <dest> <mode>: root-owned file; compared first, the old one kept beside it.
sudo_install() {
	local src=$1 dest=$2 mode=$3
	if [[ -f $dest ]] && cmp -s "$src" "$dest"; then
		return 0
	fi
	if [[ ! -e $dest ]]; then
		record_line created-root.txt "$dest"
	elif [[ ! -e $dest.before-ubuntu-ostrich ]] && ! grep -qxF -- "$dest" "$RESTORE_DIR/created-root.txt" 2>/dev/null; then
		# The machine's own file, kept once: later runs replace only our version.
		run_cmd "$SUDO" cp -a "$dest" "$dest.before-ubuntu-ostrich"
		record_line originals-root.txt "$dest	$dest.before-ubuntu-ostrich"
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
