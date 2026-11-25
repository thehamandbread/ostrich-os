#!/usr/bin/env bash
# lib/pkg.sh: idempotent package helpers (apt, flatpak). Source after logging.sh.
#
# Privileged commands go through $SUDO (default: sudo), so the user is prompted by sudo itself.

SUDO="${SUDO:-sudo}"
# apt-get waits up to 5 minutes for the package lock: on a fresh system Ubuntu's automatic updates
# often hold it for a while after the first login.
APT_GET=(apt-get -o DPkg::Lock::Timeout=300)

apt_installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == "install ok installed" ]]; }

# apt_install <pkg>...: install only the packages that are missing.
apt_install() {
	local -a missing=()
	local p
	for p in "$@"; do
		apt_installed "$p" || missing+=("$p")
	done
	((${#missing[@]} > 0)) || return 0
	changed "apt install ${missing[*]}"
	local install=("$SUDO" env DEBIAN_FRONTEND=noninteractive "${APT_GET[@]}" install -y --no-install-recommends "${missing[@]}")
	# A stale package list asks for a version the mirror has replaced (404): refresh it once, retry.
	run_cmd "${install[@]}" && return 0
	warn "apt install failed; refreshing the package lists and trying again"
	run_cmd "$SUDO" "${APT_GET[@]}" update -qq
	run_cmd "${install[@]}"
}

flatpak_remote_present() { flatpak remotes --columns=name 2>/dev/null | grep -qx "$1"; }

# flatpak_add_remote <name> <url>: system-wide remote, added once.
flatpak_add_remote() {
	local name=$1 url=$2
	flatpak_remote_present "$name" && return 0
	changed "flatpak remote-add $name"
	run_cmd "$SUDO" flatpak remote-add --if-not-exists "$name" "$url"
}

# flatpak_fetch_catalogue <name>: download a remote's app list (AppStream) if it isn't on disk yet.
# flatpak only fetches it on the first install or update, and Ostrich Store searches it from disk.
flatpak_fetch_catalogue() {
	local name=$1 arch
	arch=$(uname -m)
	[[ -e ${FLATPAK_SYSTEM_DIR:-/var/lib/flatpak}/appstream/$name/$arch/active ]] && return 0
	changed "flatpak update --appstream $name"
	run_cmd "$SUDO" flatpak update --appstream --noninteractive "$name" || warn "couldn't fetch the $name app list; Ostrich Store can fetch it later"
}
