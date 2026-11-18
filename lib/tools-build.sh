#!/usr/bin/env bash
# lib/tools-build.sh: is a checkout's own tools build (tools/target/release) safe to install?
# build-tools.sh writes .tools-stamp (a hash of the sources it built) next to the binaries; the
# installer checks it before changing anything, so a stale or half build never gets installed.

TOOLS_BINS=(ostrich ostrich-drawer ostrich-setup ostrich-store ostrich-store-gtk ostrich-theme ostrich-speakers ostrich-system-helper)

# tools_stamp REPO: one hash of every file the tools are built from (the same set build-tools.sh sends).
tools_stamp() {
	(cd "$1" && find tools -path tools/target -prune -o -type f -print &&
		find modules/gnome/extensions -name stylesheet.css.in) |
		LC_ALL=C sort | (cd "$1" && xargs -d '\n' sha256sum) | sha256sum | cut -d' ' -f1
}

# tools_build_state BUILD_DIR REPO: prints none (no build: use the release), ok, unknown (no stamp),
# partial or stale.
tools_build_state() {
	local dir=$1 repo=$2 b have=0 missing=0
	for b in "${TOOLS_BINS[@]}"; do
		if [[ -x $dir/$b ]]; then have=1; else missing=1; fi
	done
	if ((!have)); then
		echo none
	elif ((missing)); then
		echo partial
	elif [[ ! -f $dir/.tools-stamp ]]; then
		echo unknown
	elif [[ $(cat "$dir/.tools-stamp") == "$(tools_stamp "$repo")" ]]; then
		echo ok
	else
		echo stale
	fi
}

# check_tools_build BUILD_DIR REPO: stops the install early on a partial or stale build.
check_tools_build() {
	case $(tools_build_state "$1" "$2") in
	partial) die "the tools build in $1 is incomplete. Run tests/vm/build-tools.sh (or cargo build --release in tools/) first; nothing was changed." ;;
	stale) die "the tools build in $1 is older than tools/. Rebuild it (tests/vm/build-tools.sh) first; nothing was changed." ;;
	unknown) warn "can't tell what the tools in $1 were built from (no .tools-stamp); using them" ;;
	esac
	return 0
}
