#!/usr/bin/env bash
# tests/vm/e2e.sh: run the real installer in the test VM.
#
#   e2e.sh [--pipe] [--from SNAPSHOT] [--mode keep|clean] [--uninstall] [save-as]
#                                         (defaults: from 'stock', the installer's default mode, save as 'post-dev')
#
# Checkout mode (default): copies the committed tree (git archive HEAD) into the VM, plus the tool
# binaries from build-tools.sh (as if built in the checkout), then
#   1. ./install.sh --dry-run    must succeed and change nothing
#   2. ./install.sh              must succeed
#   3. ./install.sh              must succeed with no CHANGE lines (idempotent)
#
# Pipe mode (--pipe) is what a user types: the host stands in for GitHub (git daemon for the repo,
# an HTTP server for install.sh and a release packaged by tools/package.sh, reached from the VM at
# 10.0.2.2), and the VM runs
#   2. wget -qO- http://10.0.2.2:PORT/install.sh | bash      (fetches the repo and the release)
#   3. ostrich update                                        (must change nothing)
#
# Then it checks the result, logs in again, checks every extension is active, and saves the VM.
# --uninstall then runs `ostrich uninstall --yes`, logs in again and checks the machine is back to
# what tests/vm/state.sh recorded before the install (settings, extension lists, files, system files).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VM="$HERE/vm.sh"
PIPE=0
MODE=""
UNINST=0
FROM=stock
SNAP=post-dev
while (($# > 0)); do
	case $1 in
	--pipe) PIPE=1 ;;
	--from) FROM=$2 && shift ;;
	--mode) MODE=$2 && shift ;;
	--uninstall) UNINST=1 ;;
	-*)
		echo "usage: e2e.sh [--pipe] [--from SNAPSHOT] [--mode keep|clean] [--uninstall] [save-as]" >&2
		exit 2
		;;
	*) SNAP=$1 ;;
	esac
	shift
done
HTTP_PORT=18765
GIT_PORT=19418
PROJECT="ubuntu-ostrich"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
TOOLS_BIN="$VM_DIR/tools-bin"
[[ $SNAP =~ ^[A-Za-z0-9._-]+$ && $FROM =~ ^[A-Za-z0-9._-]+$ && $MODE =~ ^(|keep|clean)$ ]] || {
	echo "bad snapshot name" >&2
	exit 1
}

log() { printf '[e2e] %s\n' "$*" >&2; }
fail() {
	log "FAIL: $*"
	exit 1
}

[[ -x $TOOLS_BIN/ostrich-system-helper ]] || fail "no tool binaries in $TOOLS_BIN; run tests/vm/build-tools.sh first"

# Pipe mode: the stand-in for GitHub, serving HEAD of the current branch.
SERVE="$VM_DIR/serve"
SERVER_PIDS=()
cleanup() { ((${#SERVER_PIDS[@]} == 0)) || kill "${SERVER_PIDS[@]}" 2>/dev/null || true; }
trap cleanup EXIT
if ((PIPE)); then
	branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
	rm -rf "$SERVE" && mkdir -p "$SERVE/zips" "$SERVE/release"
	git clone --quiet --bare --branch "$branch" "$ROOT" "$SERVE/ubuntu-ostrich.git"
	git -C "$ROOT" show HEAD:install.sh >"$SERVE/install.sh"
	DIST="$SERVE/zips" "$ROOT/modules/gnome/extensions/build.sh" >/dev/null
	"$ROOT/tools/package.sh" "$TOOLS_BIN" "$SERVE/zips" "$SERVE/release" >&2
	# localhost only; QEMU's user network maps the guest's 10.0.2.2 to the host's 127.0.0.1
	git daemon --reuseaddr --export-all --base-path="$SERVE" --listen=127.0.0.1 --port=$GIT_PORT "$SERVE" &
	SERVER_PIDS+=($!)
	python3 -m http.server --bind 127.0.0.1 --directory "$SERVE" $HTTP_PORT >/dev/null 2>&1 &
	SERVER_PIDS+=($!)
	sleep 1
fi

"$VM" stop
"$VM" snapshot restore "$FROM"
"$VM" start

if ((!PIPE)); then
	tarball=$(mktemp --suffix=.tar)
	git -C "$ROOT" archive --format=tar -o "$tarball" HEAD
	"$VM" copy "$tarball" /tmp/repo.tar
	rm -f "$tarball"
	"$VM" ssh 'rm -rf ~/repo && mkdir ~/repo && tar -C ~/repo -xf /tmp/repo.tar && rm /tmp/repo.tar'
	tar -C "$TOOLS_BIN" -cf - . | "$VM" ssh 'mkdir -p ~/repo/tools/target/release && tar -xf - -C ~/repo/tools/target/release'
fi
# Some networks (e.g. campus proxies) intercept plain-HTTP apt traffic; the archive is GPG-signed
# either way, so fetching it over HTTPS inside the test VM changes nothing but works everywhere.
"$VM" ssh "sudo sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources"

# Give the GNOME session's env to the installer (dconf/gsettings need the session bus).
# Both strings expand inside the VM, not here.
# shellcheck disable=SC2016
{
	session_env='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus'
	state='$HOME/.local/state/ubuntu-ostrich/install.log'
}

mode_flag=${MODE:+--$MODE}
"$VM" ssh "bash -s" <"$HERE/state.sh" >"$VM_DIR/state-before.txt"
if ((PIPE)); then
	src="REPO_URL=git://10.0.2.2:$GIT_PORT/ubuntu-ostrich.git REPO_REF=$branch RELEASE_URL=http://10.0.2.2:$HTTP_PORT/release"
	log "1/3 (no dry run in pipe mode: the dry run needs a checkout)"
	log "2/3 install: wget -qO- .../install.sh | bash (a fresh Ubuntu has no curl or git)"
	"$VM" ssh "$session_env; wget -qO- http://10.0.2.2:$HTTP_PORT/install.sh | $src bash -s -- $mode_flag" >&2 || fail "install failed"
	"$VM" ssh "grep -c '\[CHANGE\]' $state" | sed 's/^/[e2e] changes on first run: /' >&2
	log "3/3 ostrich update (must change nothing)"
	"$VM" ssh "rm -f $state"
	"$VM" ssh "$session_env; $src ~/.local/bin/ostrich update" >&2 || fail "ostrich update failed"
else
	log "1/3 dry run"
	"$VM" ssh "$session_env; cd ~/repo && ./install.sh --dry-run" >&2 || fail "dry run failed"
	"$VM" ssh "! grep -q '\[CHANGE\]\|\[RUN\]' $state" || fail "dry run changed something"
	"$VM" ssh "rm -f $state"

	log "2/3 install"
	"$VM" ssh "$session_env; cd ~/repo && ./install.sh $mode_flag" >&2 || fail "install failed"
	"$VM" ssh "grep -c '\[CHANGE\]' $state" | sed 's/^/[e2e] changes on first run: /' >&2

	log "3/3 re-run (must change nothing)"
	"$VM" ssh "rm -f $state"
	"$VM" ssh "$session_env; cd ~/repo && ./install.sh" >&2 || fail "re-run failed"
fi
if "$VM" ssh "grep '\[CHANGE\]\|\[BACKUP\]' $state"; then
	fail "re-run was not idempotent (lines above)"
fi

log "checks"
EXTS=$(find "$ROOT/modules/gnome/extensions" -mindepth 1 -maxdepth 1 -type d ! -name _lib -printf '%f ' | sort)
"$VM" ssh "EXTS='$EXTS' bash -s" <<'EOF' || fail "post-install checks failed"
set -euo pipefail
check() { if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
check "ghostty installed" 'command -v ghostty >/dev/null'
check "flathub remote" 'flatpak remotes --columns=name | grep -qx flathub'
check "chezmoi pinned" '~/.local/bin/chezmoi --version | grep -q "v2.73.2,"'
check "ghostty config" 'grep -q "^theme = " ~/.config/ghostty/config'
check "default terminal" 'grep -qx com.mitchellh.ghostty.desktop ~/.config/xdg-terminals.list'
check "bashrc sources additions once" '[ "$(grep -c ubuntu-ostrich/bashrc.sh ~/.bashrc)" -eq 1 ]'
check "bashrc still has Ubuntu defaults" 'grep -q "HISTCONTROL" ~/.bashrc'
check "backups taken" 'ls ~/.local/state/ubuntu-ostrich/backups/*/home/*/.bashrc >/dev/null'
check "new shell works" 'bash -ic "type gpu-status >/dev/null 2>&1 || true; echo \$PATH" | grep -q .local/bin'
check "notification banners on" '[ "$(gsettings get org.gnome.desktop.notifications show-banners)" = true ]'
check "extensions installed" 'for u in $EXTS; do [ -f ~/.local/share/gnome-shell/extensions/$u@ubuntu-ostrich/metadata.json ] || exit 1; done'
check "tools installed and runnable" 'export PATH=$HOME/.local/bin:$PATH; ostrich help | grep -q store && ostrich theme list >/dev/null && ostrich speakers list | grep -qx flat'
check "drawer and wizard libraries present" '! ldd ~/.local/libexec/ubuntu-ostrich/ostrich-drawer ~/.local/libexec/ubuntu-ostrich/ostrich-setup | grep -q "not found"'
check "drawer autostarts hidden" 'grep -q -- "--hidden$" ~/.config/autostart/ostrich-drawer.desktop'
check "wizard autostarts and is in the app grid" '[ -f ~/.config/autostart/ostrich-setup.desktop ] && [ -f ~/.local/share/applications/ubuntu-ostrich.setup.desktop ]'
check "Ostrich Store is in the dock, App Center isn't" 'f=$(gsettings get org.gnome.shell favorite-apps); [[ $f == *ubuntu-ostrich.store.desktop* && $f != *snap-store_snap-store.desktop* ]]'
check "Ostrich Store opens Flatpak files and app links" '[ "$(xdg-mime query default application/vnd.flatpak.ref)" = ubuntu-ostrich.store.desktop ] && [ "$(xdg-mime query default x-scheme-handler/appstream)" = ubuntu-ostrich.store.desktop ]'
check "replaced extensions off" 'gsettings get org.gnome.shell disabled-extensions | grep -q tiling-assistant@ubuntu.com'
check "power boot unit enabled (the VM has PCIe ASPM)" 'systemctl is-enabled --quiet ubuntu-ostrich-power.service'
check "helper installed for polkit" '[ -x /usr/libexec/ubuntu-ostrich/system-helper ] && [ -f /usr/share/polkit-1/actions/org.ubuntu-ostrich.system-helper.policy ]'
check "polkit has the helper's four actions" '[ "$(pkaction | grep -c "^org.ubuntu-ostrich.system-helper\.")" = 4 ]'
check "the Store's daily update check is on" 'systemctl --user is-enabled --quiet ostrich-store-updates.timer && systemctl --user is-active --quiet ostrich-store-updates.timer'
check "our app icons are installed and used" 'for n in store settings drawer; do [ -f ~/.local/share/icons/hicolor/scalable/apps/ostrich-$n.svg ] && [ -f ~/.local/share/icons/hicolor/symbolic/apps/ostrich-$n-symbolic.svg ] || exit 1; done; grep -q "^Icon=ostrich-store$" ~/.local/share/applications/ubuntu-ostrich.store.desktop'
EOF

# New extensions load at the next login (Wayland). Let the session finish starting first: powering
# off while a full install is still starting up (within ~10 s of login in this VM) sometimes keeps
# GNOME Shell from exiting; systemd kills it and GNOME switches extensions off. 0 of 10 when
# powered off 30 s after login (docs/DECISIONS.md).
sleep 45
"$VM" stop
"$VM" start
sleep 10
"$VM" ssh "EXTS='$EXTS' bash -s" <<'EOF' || fail "extension checks after re-login failed"
set -euo pipefail
[ "$(gsettings get org.gnome.shell disable-user-extensions)" = false ] || { echo "  FAIL: GNOME disabled user extensions (a shell crash)"; exit 1; }
for u in $EXTS; do
	s=$(gnome-extensions info $u@ubuntu-ostrich | sed -n "s/^ *State: //p")
	[ "$s" = ACTIVE ] && echo "  ok: $u active" || { echo "  FAIL: $u state=$s"; exit 1; }
done
n=$(journalctl --user -b -o cat /usr/bin/gnome-shell | grep -c "JS ERROR.*@ubuntu-ostrich" || true)
[ "$n" = 0 ] && echo "  ok: no JS errors" || { echo "  FAIL: $n JS errors"; exit 1; }
EOF

if ((UNINST)); then
	log "uninstall: ostrich uninstall --yes"
	"$VM" ssh "$session_env; ~/.local/bin/ostrich uninstall --yes" >&2 || fail "uninstall failed"
	# The shell re-enables the original extensions after the settings come back; let it finish
	# before powering off (the same shutdown timing as after the install, above).
	sleep 45
	"$VM" stop
	"$VM" start
	sleep 10
	"$VM" ssh "bash -s" <"$HERE/state.sh" >"$VM_DIR/state-after.txt"
	if diff -u "$VM_DIR/state-before.txt" "$VM_DIR/state-after.txt" >"$VM_DIR/state.diff"; then
		log "uninstall: settings, extensions and files are exactly as before"
	else
		cat "$VM_DIR/state.diff" >&2
		# GNOME switches extensions off when systemd had to kill the shell at shutdown: show that.
		"$VM" ssh 'journalctl -b -1 -o short | grep -iE "gnome-shell.*(kill|timed out|timeout)|disable-extensions|Stopped.*gnome-shell" | tail -6' >&2 || true
		fail "uninstall left differences (above; also $VM_DIR/state.diff)"
	fi
fi

"$VM" stop
"$VM" snapshot save "$SNAP"
log "PASS; saved snapshot $SNAP"
