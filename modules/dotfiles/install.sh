#!/usr/bin/env bash
# modules/dotfiles/install.sh: install chezmoi (pinned, checksum-verified) and apply home/.
set -euo pipefail
# shellcheck source=lib/module.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/module.sh"
module_init "$@"

CHEZMOI_VERSION="2.73.2"
CHEZMOI_SHA256="6f5eb3ab10b0805ddfec5ddd3e9d575720b17bf065a581cff501170d3770479f" # gitleaks:allow (release checksum)
CHEZMOI_URL="https://github.com/twpayne/chezmoi/releases/download/v${CHEZMOI_VERSION}/chezmoi-linux-amd64"
BIN_DIR="$HOME/.local/bin"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

chezmoi_ok() {
	local bin=$1
	[[ -x $bin ]] && [[ $("$bin" --version 2>/dev/null) == "chezmoi version v${CHEZMOI_VERSION},"* ]]
}

install_chezmoi() {
	chezmoi_ok "$BIN_DIR/chezmoi" && return 0
	changed "install chezmoi $CHEZMOI_VERSION to $BIN_DIR"
	((DRY_RUN)) && return 0
	local tmp
	tmp=$(mktemp -d)
	curl -fsSL -o "$tmp/chezmoi" "$CHEZMOI_URL"
	echo "$CHEZMOI_SHA256  $tmp/chezmoi" | sha256sum -c --quiet - || die "chezmoi checksum mismatch"
	if [[ -e $BIN_DIR/chezmoi ]]; then backup_file "$BIN_DIR/chezmoi"; else record_created "$BIN_DIR/chezmoi"; fi
	install -D -m 0755 "$tmp/chezmoi" "$BIN_DIR/chezmoi"
	rm -rf "$tmp"
}

install_chezmoi
CHEZMOI="$BIN_DIR/chezmoi"
if ((DRY_RUN)) && ! chezmoi_ok "$CHEZMOI"; then
	info "dry run: chezmoi not installed yet, skipping the dotfiles diff"
	module_done
	exit 0
fi

# Identity comes from existing git config; empty values make the template skip [user].
name=$(git config --global user.name 2>/dev/null || true)
email=$(git config --global user.email 2>/dev/null || true)
chez=("$CHEZMOI" --source "$REPO" --no-tty)
# --promptString keys are the prompt texts in home/.chezmoi.toml.tmpl.
init_args=(init --promptString "git name=$name" --promptString "git email=$email")

if ((DRY_RUN)); then
	tmpcfg=$(mktemp -d)
	"${chez[@]}" --config "$tmpcfg/chezmoi.toml" --persistent-state "$tmpcfg/state.boltdb" "${init_args[@]}" >/dev/null
	"${chez[@]}" --config "$tmpcfg/chezmoi.toml" --persistent-state "$tmpcfg/state.boltdb" apply --dry-run --verbose --no-pager 2>&1 | sed 's/^/[dotfiles] /' >&2 || true
	rm -rf "$tmpcfg"
	module_done
	exit 0
fi

chez_config="${XDG_CONFIG_HOME:-$HOME/.config}/chezmoi"
# chezmoi init rewrites its config: someone's own setup is kept, so uninstall puts it back.
if [[ -e $chez_config/chezmoi.toml ]] && ! grep -qF "$REPO" "$chez_config/chezmoi.toml"; then
	warn "your chezmoi config is saved; Ubuntu Ostrich's dotfiles take over chezmoi until uninstall"
fi
# Once it's ours (a later run or update), there's nothing of theirs left to save.
if ! grep -qsF "$REPO" "$chez_config/chezmoi.toml"; then
	for f in "$chez_config/chezmoi.toml" "$chez_config/chezmoistate.boltdb"; do
		if [[ -e $f ]]; then backup_file "$f"; else record_created "$f"; fi
	done
fi
"${chez[@]}" "${init_args[@]}"

pending=$("${chez[@]}" status --include=files,symlinks)
if [[ -z $pending ]]; then
	info "dotfiles already up to date"
else
	# Back up every existing file chezmoi would change (not directories), note the new ones, apply.
	while IFS= read -r rel; do
		[[ -n $rel && ! -d $HOME/$rel ]] || continue
		if [[ -e $HOME/$rel ]]; then backup_file "$HOME/$rel"; else record_created "$HOME/$rel"; fi
	done < <(awk '{ print $2 }' <<<"$pending")
	"${chez[@]}" apply
	changed "applied dotfiles: $(awk '{ print $2 }' <<<"$pending" | paste -sd' ')"
fi
module_done
