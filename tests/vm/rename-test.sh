#!/usr/bin/env bash
# tests/vm/rename-test.sh: the 0.5.0 -> 0.6.0 upgrade (Ubuntu Ostrich -> Ostrich OS) in a lab VM on
# the stock base, the way a user lives through it. Never the main VM: it uses lab slots only.
#
#   rename-test.sh [--from STEP] [--break-cookies] [--out DIR] [--release]
#
# Stages, each ending in a snapshot of the lab slot (rt-STEP), so --from STEP re-runs one stage
# (and the ones after it) from the previous stage's snapshot instead of from a fresh install:
#   install   v0.5.0 from the real GitHub release (old repo URL), as `wget -qO- .../install.sh | bash`;
#             its SHA256SUMS check is logged. Boot once so the extensions load.
#   state     what a user builds up: a localhost stand-in site (cookie, signed in, its notifications
#             off), the drawer pinned in the dock, one extension disabled, a custom site list, and a
#             Store GitHub app under its AppArmor profile.
#   upgrade   boot (0.5.0's drawer autostarts), open the site so WebKit holds the data, then run
#             this branch's installer (BUILD_DIR: the 0.6.0 release doesn't exist yet) without
#             stopping anything by hand. The data must have moved in that same run. Then log out/in.
#   verify    reboot (the boot-time cleanup unit runs), then every assertion.
#
# --break-cookies is the negative control: it deletes the drawer's cookies just before the
# signed-in check, which must then FAIL (exit 1). Exit 2 means the check cannot see lost cookies.
#
# Needs: a lab base made from the stock snapshot (LAB_DIR=$VM_DIR/lab-stock lab.sh base stock) and
# the 0.6.0 tools (tests/vm/build-tools-docker.sh, into $VM_DIR/tools-bin-docker).
# Environment: VM_DIR (the dev VM folder, for keys and firmware), LAB_DIR, TOOLS_BIN.
# shellcheck disable=SC2015 # "check && ok || bad": ok only prints, so it never runs the bad branch by mistake
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ostrich-os/vm}"
LAB_DIR="${LAB_DIR:-$VM_DIR/lab-stock}"
export VM_DIR LAB_DIR
TOOLS_BIN="${TOOLS_BIN:-$VM_DIR/tools-bin-docker}"
OUT="$VM_DIR/rename-test"
STAGES=(install state upgrade verify)
FROM=install
BREAK=0
RELEASE=0
OLD_REPO=thehamandbread/ubuntu-ostrich # the old repo URL: before the GitHub rename
OLD_TAG=v0.5.0
PORT=8099
while (($# > 0)); do
	case $1 in
	--from) FROM=$2 && shift ;;
	--break-cookies) BREAK=1 ;;
	--out) OUT=$2 && shift ;;
	--release) RELEASE=1 ;;
	*)
		sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
		exit 2
		;;
	esac
	shift
done
[[ " ${STAGES[*]} " == *" $FROM "* ]] || {
	echo "rename-test: --from takes one of: ${STAGES[*]}" >&2
	exit 2
}
mkdir -p "$OUT"

log() { printf '[rename-test] %s\n' "$*" >&2; }
failures=0
ok() { printf '  ok: %s\n' "$*"; }
bad() {
	printf '  FAIL: %s\n' "$*"
	failures=$((failures + 1))
}
step() { printf '== %s\n' "$*"; }
die() {
	log "$*"
	exit 1
}

# --- the lab slot ---------------------------------------------------------------------------
SLOTFILE="$LAB_DIR/rename-test.slot"
if [[ $FROM == install ]]; then
	[[ -d $LAB_DIR ]] || die "no lab at $LAB_DIR; make it: LAB_DIR=$LAB_DIR tests/vm/lab.sh base stock"
	[[ $(cat "$LAB_DIR/snapshot" 2>/dev/null) == stock ]] || die "the lab at $LAB_DIR isn't made from the stock snapshot"
	[[ -f $SLOTFILE ]] && "$HERE/lab.sh" "$(cat "$SLOTFILE")" release >/dev/null 2>&1 || true
	SLOT=$("$HERE/lab.sh" book rename-test | tail -1)
	echo "$SLOT" >"$SLOTFILE"
else
	[[ -f $SLOTFILE ]] || die "no slot yet; run the install stage first"
	SLOT=$(cat "$SLOTFILE")
	touch "$LAB_DIR/slot$SLOT.busy" # still in use
fi
vmx() { VM_DIR="$LAB_DIR/slot$SLOT" VM_SSH_PORT=$((2230 + SLOT)) VM_MEM=5G VM_AUDIO=0 "$HERE/vm.sh" "$@"; }
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0;'
run() { vmx ssh "$SESSION $*"; }
# shellcheck disable=SC2016 # expands in the VM
OLD_HOST='$HOME/.local/libexec/ubuntu-ostrich/ostrich-drawer'
# shellcheck disable=SC2016 # expands in the VM
NEW_HOST='$HOME/.local/libexec/ostrich-os/ostrich-drawer'
OLD_ACT="--dest ubuntu_ostrich.drawer --object-path /ubuntu_ostrich/drawer --method org.gtk.Actions.Activate"

# boot_session: start the slot and wait until the GNOME session answers and has settled.
boot_session() {
	vmx start >/dev/null
	local i
	for ((i = 0; i < 60; i++)); do
		run "gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.freedesktop.DBus.Peer.Ping" >/dev/null 2>&1 && break
		sleep 3
	done
	((i < 60)) || die "no GNOME session after boot"
	sleep 20 # extensions load and autostart apps start
	run "pkill -x ostrich-setup; gsettings set org.gnome.desktop.session idle-delay 0; gsettings set org.gnome.desktop.screensaver lock-enabled false" >/dev/null 2>&1 || true
}
# restore SNAPSHOT: power off if the slot is on (a re-run), then go back to the stage's snapshot.
restore() {
	vmx stop >/dev/null
	vmx snapshot restore "$1" >/dev/null
}
# Power off with the session settled, then save the stage's snapshot (the same shutdown timing as
# e2e.sh: powering off right after login can make GNOME switch extensions off).
end_stage() {
	sleep 30
	vmx stop >/dev/null
	vmx snapshot save "rt-$1" >/dev/null
	log "stage $1 done; snapshot rt-$1"
}
# relogin: log out and in again (GDM's autologin starts a fresh session) and wait for it.
relogin() {
	vmx ssh "sudo systemctl restart gdm" >/dev/null 2>&1 || true
	sleep 15
	local i
	for ((i = 0; i < 60; i++)); do
		run "gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.freedesktop.DBus.Peer.Ping" >/dev/null 2>&1 && break
		sleep 3
	done
	((i < 60)) || die "no GNOME session after logging out and in"
	sleep 20
	run "pkill -x ostrich-setup" >/dev/null 2>&1 || true
}

# The localhost stand-in for a site: gives a new visitor a persistent cookie (that is "signing in"),
# recognises it later and logs each load. Its token is fixed, so the cookie stays good when the server is restarted after a reboot.
start_site() {
	vmx ssh "mkdir -p ~/standin && cat >~/standin/server.py" <<'PY'
import http.server, os, time
TOKEN = "standin-token-0001"
LOG = os.path.expanduser("~/standin/log")
PAGE = """<!doctype html><title>Stand-in: %s</title><h1>%s</h1>"""
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/favicon.ico":
            self.send_response(404); self.end_headers(); return
        signed = ("sid=" + TOKEN) in self.headers.get("Cookie", "")
        with open(LOG, "a") as f:
            f.write("%d %s %s\n" % (time.time(), "SIGNED-IN" if signed else "NEW-SESSION", self.path))
        body = (PAGE % (("signed in",) * 2 if signed else ("signed out",) * 2)).encode()
        self.send_response(200)
        if not signed:
            self.send_header("Set-Cookie", "sid=%s; Max-Age=31536000; Path=/" % TOKEN)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", 8099), H).serve_forever()
PY
	vmx ssh "kill \$(cat ~/standin/pid 2>/dev/null) 2>/dev/null; setsid nohup python3 ~/standin/server.py >/dev/null 2>&1 </dev/null & echo \$! >~/standin/pid; sleep 1; wget -qO- http://localhost:$PORT/ >/dev/null && echo up" | grep -q up || die "the stand-in site didn't start"
}
# wait_log PATTERN: wait for a new line of the stand-in's log (after the lines already there).
loglines() { vmx ssh "wc -l <~/standin/log 2>/dev/null || echo 0"; }
last_visit() { vmx ssh "tail -1 ~/standin/log | cut -d' ' -f2"; }
open_site() { # open_site HOSTPATH: show the drawer's site and wait for the stand-in to be asked
	local before i
	before=$(loglines)
	run "$1 --show localhost >/dev/null 2>&1 &"
	for ((i = 0; i < 30; i++)); do
		(($(loglines) > before)) && return 0
		sleep 2
	done
	return 1
}

# --- stage 1: the real v0.5.0 ----------------------------------------------------------------
stage_install() {
	step "install: $OLD_TAG from github.com/$OLD_REPO, as a user would"
	vmx start >/dev/null 2>&1 || true # lab.sh book left the fresh slot running
	vmx ssh "sudo sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources"
	run "wget -qO- https://raw.githubusercontent.com/$OLD_REPO/$OLD_TAG/install.sh | REPO_REF=$OLD_TAG bash -s" >"$OUT/install-0.5.0.log" 2>&1 || {
		tail -20 "$OUT/install-0.5.0.log" >&2
		die "the 0.5.0 install failed (log: $OUT/install-0.5.0.log)"
	}
	[[ $(vmx ssh "cat ~/.local/share/ubuntu-ostrich/src/VERSION") == 0.5.0 ]] && ok "installed version is 0.5.0" || bad "not version 0.5.0"
	# The installer verifies the release against its SHA256SUMS and stops on a mismatch; repeat the
	# check on what it downloaded, and keep the output in the log.
	{
		echo "release: https://github.com/$OLD_REPO/releases/download/$OLD_TAG/SHA256SUMS"
		vmx ssh "cd ~/.local/share/ubuntu-ostrich/src/dist/release/$OLD_TAG && sha256sum -c SHA256SUMS"
	} | tee "$OUT/sha256-0.5.0.txt"
	[[ ${PIPESTATUS[0]} -eq 0 ]] && ok "0.5.0 release files match SHA256SUMS" || bad "0.5.0 SHA256SUMS check failed"
	vmx ssh '[ -x /usr/libexec/ubuntu-ostrich/system-helper ]' && ok "0.5.0's root helper is installed" || bad "no 0.5.0 root helper"
	end_stage install
}

# --- stage 2: what a user has built up -------------------------------------------------------
stage_state() {
	step "state: a site, its cookie and notification setting, the dock, an extension, a Store app"
	restore rt-install
	boot_session
	start_site
	run "pgrep -x ostrich-drawer >/dev/null" && ok "0.5.0's drawer is running (autostart at login)" || bad "0.5.0's drawer isn't running"
	# a custom site list: the stand-in added, one recommended site removed
	run "$OLD_HOST --add http://localhost:$PORT/ && $OLD_HOST --remove youtube" >/dev/null 2>&1 || true
	run "$OLD_HOST --list" | sort >"$OUT/sites-before.txt"
	grep -q '^localhost' "$OUT/sites-before.txt" && ! grep -q '^youtube' "$OUT/sites-before.txt" &&
		ok "site list is customised ($(wc -l <"$OUT/sites-before.txt") sites)" || bad "couldn't customise the site list"
	# sign in (the stand-in's cookie is set on the first visit), then load again signed in
	open_site "$OLD_HOST" || bad "the drawer didn't load the stand-in site"
	run "gdbus call --session $OLD_ACT reload \"[<'localhost'>]\" '{}'" >/dev/null 2>&1 || true
	sleep 6
	[[ $(last_visit) == SIGNED-IN ]] && ok "the site is signed in (its cookie is kept)" || bad "the site isn't signed in before the upgrade"
	# the site notifies (as notify-send does for an app with a .desktop file, the way plan 01 verified):
	# GNOME makes its notification entry; then the user turns the site's notifications off
	local i child=ubuntu-ostrich-drawer-localhost
	for ((i = 0; i < 15; i++)); do
		run "notify-send -h string:desktop-entry:ubuntu_ostrich.drawer.localhost Stand-in hello" # until the Shell knows the launcher
		sleep 2
		run "dconf read /org/gnome/desktop/notifications/application/$child/application-id" | grep -q localhost && break
	done
	run "dconf read /org/gnome/desktop/notifications/application/$child/application-id" | grep -q "ubuntu_ostrich.drawer.localhost.desktop" && ok "GNOME made the site's notification entry ($child)" || bad "no notification entry for the site"
	run "gsettings set org.gnome.desktop.notifications.application:/org/gnome/desktop/notifications/application/$child/ enable false"
	run "gsettings get org.gnome.desktop.notifications.application:/org/gnome/desktop/notifications/application/$child/ enable" | grep -qx false && ok "the site's notifications are off" || bad "couldn't switch the site's notifications off"
	# the drawer pinned in the dock
	# shellcheck disable=SC2016 # expands in the VM
	run 'f=$(gsettings get org.gnome.shell favorite-apps); [[ $f == *ubuntu_ostrich.drawer.desktop* ]] || gsettings set org.gnome.shell favorite-apps "$(echo "$f" | sed "s/]$/, '"'"'ubuntu_ostrich.drawer.desktop'"'"']/")"'
	run "gsettings get org.gnome.shell favorite-apps" | grep -q ubuntu_ostrich.drawer.desktop && ok "the drawer is pinned in the dock" || bad "the drawer isn't pinned"
	# one extension disabled by the user
	run "gnome-extensions disable monitor@ubuntu-ostrich"
	run "gsettings get org.gnome.shell disabled-extensions" | grep -q monitor@ubuntu-ostrich && ok "monitor@ubuntu-ostrich is disabled" || bad "couldn't disable an extension"
	# a Store GitHub app: laid out as the Store does (its manifest, launcher and AppArmor profile through
	# the helper's own action). The program is a copy of unshare: it needs a user namespace, which Ubuntu
	# only allows under the profile, so launching it proves the profile applies.
	vmx ssh 'bash -s' <<'EOF'
set -e
app=$HOME/.local/share/ubuntu-ostrich/github/stand_in-app
mkdir -p "$app/app" ~/.local/share/applications
cp /usr/bin/unshare "$app/app/AppRun"
printf '[Desktop Entry]\nType=Application\nName=Stand-in app\nComment=Installed from github.com/stand/in-app (v1)\nExec="%s/app/AppRun" -U -r true\nIcon=application-x-executable\nCategories=Utility;\nTerminal=false\n' "$app" >~/.local/share/applications/ost-github-stand_in-app.desktop
printf '{"stand/in-app": {"tag": "v1", "kind": "AppImage", "asset": "x.AppImage", "files": ["%s/app/AppRun"], "package": null}}\n' "$app" >~/.local/share/ubuntu-ostrich/github-apps.json
EOF
	if vmx ssh "\"\$HOME/.local/share/ubuntu-ostrich/github/stand_in-app/app/AppRun\" -U -r true" >/dev/null 2>&1; then
		bad "the Store app starts without its profile (the control is void)"
	else
		ok "without the profile the Store app can't make its user namespace (control)"
	fi
	vmx ssh "sudo /usr/libexec/ubuntu-ostrich/system-helper apparmor allow stand_in-app" >/dev/null &&
		vmx ssh "\"\$HOME/.local/share/ubuntu-ostrich/github/stand_in-app/app/AppRun\" -U -r true" >/dev/null 2>&1 &&
		ok "with its 0.5.0 profile the Store app runs" || bad "the Store app doesn't run under its 0.5.0 profile"
	# what the old name left as root-owned files, to be gone after the upgrade and reboot
	vmx ssh "sudo find / -xdev \\( -path /proc -o -path /home -o -path /var/cache -o -path /var/log -o -path /tmp -o -path /var/tmp \\) -prune -o \\( -name '*ubuntu-ostrich*' -o -name '*ubuntu_ostrich*' \\) -print 2>/dev/null | sort" >"$OUT/root-old-before.txt"
	[[ -s $OUT/root-old-before.txt ]] && ok "old root-owned files exist ($(wc -l <"$OUT/root-old-before.txt"))" || bad "found no old root-owned files"
	run "$OLD_HOST --list >/dev/null"
	vmx ssh "gsettings get org.gnome.shell enabled-extensions; ls ~/.local/share/gnome-shell/extensions" >"$OUT/extensions-before.txt"
	((failures == 0)) || die "stage state failed"
	end_stage state
}

# --- stage 3: the upgrade, in the session ----------------------------------------------------
stage_upgrade() {
	step "upgrade: this branch's installer over 0.5.0, with the old drawer running"
	[[ -x $TOOLS_BIN/ostrich-system-helper ]] || die "no 0.6.0 tools in $TOOLS_BIN; run tests/vm/build-tools-docker.sh"
	restore rt-state
	boot_session
	start_site
	run "pgrep -x ostrich-drawer >/dev/null" && ok "0.5.0's drawer is running before the upgrade" || bad "0.5.0's drawer isn't running"
	# the user has the drawer open on the site, so WebKit's processes hold its data
	open_site "$OLD_HOST" || bad "the drawer didn't load the site"
	sleep 3
	run "fuser \$HOME/.local/share/ubuntu-ostrich/drawer/localhost/data/cookies.sqlite >/dev/null 2>&1" &&
		ok "the cookie file is held open by the running 0.5.0 drawer" || bad "nothing holds the cookie file (the held-data case isn't tested)"
	# this branch's tree and binaries, as e2e.sh's checkout mode does
	local tarball
	tarball=$(mktemp --suffix=.tar)
	git -C "$ROOT" archive --format=tar -o "$tarball" HEAD
	vmx copy "$tarball" /tmp/repo.tar
	rm -f "$tarball"
	vmx ssh 'rm -rf ~/repo && mkdir ~/repo && tar -C ~/repo -xf /tmp/repo.tar && rm /tmp/repo.tar'
	tar -C "$TOOLS_BIN" -cf - . | vmx ssh 'mkdir -p ~/repo/tools/target/release && tar -xf - -C ~/repo/tools/target/release'
	vmx ssh "sudo sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources"
	log "running ./install.sh (the 0.5.0 drawer is still running; nothing is stopped by hand)"
	run "cd ~/repo && ./install.sh" >"$OUT/upgrade-0.6.0.log" 2>&1 || {
		tail -25 "$OUT/upgrade-0.6.0.log" >&2
		die "the upgrade failed (log: $OUT/upgrade-0.6.0.log)"
	}
	ok "the installer finished"
	# the data moved in that same run
	run '[ -f ~/.local/share/ostrich-os/drawer/localhost/data/cookies.sqlite ] && [ ! -e ~/.local/share/ubuntu-ostrich/drawer ]' &&
		ok "the drawer's data moved in the same run" || bad "the drawer's data did not move in the upgrade run"
	grep -q "was not moved yet" "$OUT/upgrade-0.6.0.log" && bad "the installer says the drawer's data was left (it was running)" || ok "the installer did not defer the drawer's data"
	run "pgrep -f [l]ibexec/ubuntu-ostrich >/dev/null" && bad "an old process is still running" || ok "no process of the old install is left"
	# old root-owned files wait for the boot-time cleanup unit
	vmx ssh 'systemctl is-enabled ostrich-os-cleanup-old.service' >/dev/null 2>&1 && ok "the boot-time cleanup unit is enabled" || bad "no cleanup unit"
	vmx ssh 'test -e /usr/libexec/ubuntu-ostrich' && ok "old root files are still there until the reboot (the unit's job)" || ok "old root files already gone (nothing for the unit)"
	# a second run changes nothing
	vmx ssh 'rm -f ~/.local/state/ostrich-os/install.log'
	run "cd ~/repo && ./install.sh" >"$OUT/upgrade-rerun.log" 2>&1 || bad "the re-run failed"
	vmx ssh "grep '\[CHANGE\]\|\[BACKUP\]' ~/.local/state/ostrich-os/install.log" >"$OUT/rerun-changes.txt" || true
	[[ ! -s $OUT/rerun-changes.txt ]] && ok "re-running the installer changes nothing" || {
		bad "the re-run changed something (see $OUT/rerun-changes.txt)"
		cat "$OUT/rerun-changes.txt"
	}
	log "log out and in"
	relogin
	((failures == 0)) || die "stage upgrade failed"
	end_stage upgrade
}

# --- stage 4: after the reboot ---------------------------------------------------------------
stage_verify() {
	step "verify: after logging out and in, and a reboot"
	restore rt-upgrade
	boot_session # this boot runs the cleanup unit
	start_site
	local i child=ostrich-os-drawer-localhost

	step "the new install"
	run "pgrep -x ostrich-drawer >/dev/null" && ok "the new drawer is running" || bad "the drawer isn't running"
	run "pgrep -f [l]ibexec/ubuntu-ostrich >/dev/null" && bad "an old process is running" || ok "no process of the old install"
	[[ $(vmx ssh "cat ~/.local/share/ostrich-os/src/VERSION 2>/dev/null || cat ~/repo/VERSION") == 0.6.0 ]] && ok "version 0.6.0" || bad "not version 0.6.0"

	step "the signed-in site and its notification setting"
	if ((BREAK)); then
		log "negative control: deleting the drawer's cookies before the check"
		run "pkill -x ostrich-drawer; sleep 3; rm -f ~/.local/share/ostrich-os/drawer/localhost/data/cookies.sqlite*; $NEW_HOST --hidden >/dev/null 2>&1 &"
		sleep 5
	fi
	open_site "$NEW_HOST" || bad "the drawer didn't load the site"
	sleep 3
	signed_in=1
	[[ $(last_visit) == SIGNED-IN ]] && ok "the site is still signed in" || {
		bad "the site is signed out (the stand-in saw no cookie)"
		signed_in=0
	}
	run "dconf list /org/gnome/desktop/notifications/application/" | grep -qx "$child/" && ok "the site's notification entry is $child" || bad "no entry $child"
	run "dconf list /org/gnome/desktop/notifications/application/" | grep -q "^ubuntu-ostrich" && bad "an old notification entry is left" || ok "no old notification entry"
	run "gsettings get org.gnome.desktop.notifications.application:/org/gnome/desktop/notifications/application/$child/ enable" | grep -qx false && ok "the site's notifications are still off" || bad "the site's notifications are not off"
	run "gsettings get org.gnome.desktop.notifications.application:/org/gnome/desktop/notifications/application/$child/ application-id" | grep -q "ostrich_os.drawer.localhost.desktop" && ok "its application-id is the new one" || bad "wrong application-id"
	run "dconf read /org/gnome/desktop/notifications/application-children" | grep -q "$child" && ok "it is listed in application-children" || bad "not in application-children"

	step "dock, extensions, site list"
	run "gsettings get org.gnome.shell favorite-apps" | grep -q "ostrich_os.drawer.desktop" && ! run "gsettings get org.gnome.shell favorite-apps" | grep -q ubuntu_ostrich &&
		ok "the dock pins ostrich_os.drawer.desktop, no old id" || bad "the dock's pinned apps are wrong"
	vmx screenshot "$OUT/dock.png" >/dev/null 2>&1 || true
	run "gsettings get org.gnome.shell enabled-extensions; gsettings get org.gnome.shell disabled-extensions" | grep -q '@ubuntu-ostrich' && bad "an extension list still names @ubuntu-ostrich" || ok "no extension list names @ubuntu-ostrich"
	[[ $(run "gsettings get org.gnome.shell disable-user-extensions") == false ]] && ok "GNOME did not switch user extensions off" || bad "user extensions are switched off"
	while read -r old <&3; do # fd 3: ssh inside the loop would eat stdin
		[[ $old == *@ubuntu-ostrich ]] || continue
		new=${old%@ubuntu-ostrich}@ostrich-os
		state=$(run "gnome-extensions info $new | sed -n 's/^ *State: //p'")
		if [[ $old == monitor@ubuntu-ostrich ]]; then
			run "gsettings get org.gnome.shell disabled-extensions" | grep -q "$new" && [[ $state != ACTIVE && $state != ERROR ]] &&
				ok "$new stays disabled ($state)" || bad "$new should still be disabled (state $state)"
		else
			[[ $state == ACTIVE ]] && ok "$new is ACTIVE" || bad "$new is $state"
		fi
	done 3< <(grep -o '[a-z-]*@ubuntu-ostrich' "$OUT/extensions-before.txt" | sort -u)
	[[ $(grep -o '[a-z-]*@ubuntu-ostrich' "$OUT/extensions-before.txt" | sort -u | wc -l) -ge 10 ]] || bad "the 0.5.0 install had fewer than 10 extensions"
	n=$(run "journalctl --user -b -o cat /usr/bin/gnome-shell | grep -c 'JS ERROR.*@ostrich-os' || true")
	[[ $n == 0 ]] && ok "no JS errors from our extensions" || bad "$n JS errors"
	run "$NEW_HOST --list" | sort >"$OUT/sites-after.txt"
	diff -q "$OUT/sites-before.txt" "$OUT/sites-after.txt" >/dev/null && ok "the custom site list is unchanged" || {
		bad "the site list changed"
		diff "$OUT/sites-before.txt" "$OUT/sites-after.txt" || true
	}

	step "the Store app under its AppArmor profile"
	vmx ssh 'sudo grep -q "^ostrich-os-github-stand_in-app " /sys/kernel/security/apparmor/profiles' && ok "profile ostrich-os-github-stand_in-app is loaded" || bad "the new profile isn't loaded"
	vmx ssh 'sudo grep -q "^ubuntu-ostrich-github" /sys/kernel/security/apparmor/profiles' && bad "an old profile is still loaded" || ok "no old profile is loaded"
	vmx ssh 'ls /etc/apparmor.d | grep ubuntu-ostrich' >/dev/null 2>&1 && bad "an old profile file is left" || ok "no old profile file"
	vmx ssh 'bash -s' <<'EOF' && ok "the Store app's launcher points at the new folder and the app runs under the profile" || bad "the Store app does not run from its launcher"
set -e
f=$HOME/.local/share/applications/ost-github-stand_in-app.desktop
grep -q "/share/ostrich-os/github/stand_in-app/app/AppRun" "$f"
! grep -q ubuntu-ostrich "$f"
exe=$(sed -n 's/^Exec="\([^"]*\)".*/\1/p' "$f")
"$exe" -U -r true
grep -q ostrich-os ~/.local/share/ostrich-os/github-apps.json
EOF

	step "old files, the cleanup unit, the portal's dash rule"
	vmx ssh "sudo find / -xdev \\( -path /proc -o -path /home -o -path /var/cache -o -path /var/log -o -path /tmp -o -path /var/tmp \\) -prune -o \\( -name '*ubuntu-ostrich*' -o -name '*ubuntu_ostrich*' -o -name '*cleanest-ubuntu-setup*' \\) -print 2>/dev/null | sort" >"$OUT/root-old-after.txt"
	[[ ! -s $OUT/root-old-after.txt ]] && ok "no old root-owned file is left" || {
		bad "old root-owned files are left:"
		cat "$OUT/root-old-after.txt"
	}
	vmx ssh 'systemctl cat ostrich-os-cleanup-old.service >/dev/null 2>&1' && bad "the cleanup unit is still installed" || ok "the cleanup unit removed itself"
	vmx ssh 'test -e /usr/libexec/ostrich-os/cleanup-old' && bad "the unit's files are left" || ok "the unit's files are gone"
	vmx ssh 'journalctl -b -u ostrich-os-cleanup-old.service --no-pager 2>/dev/null | grep -q .' && ok "the unit ran at this boot (journal)" || bad "no journal entry for the unit at this boot"
	vmx ssh 'ls -d ~/.config/ubuntu-ostrich ~/.local/share/ubuntu-ostrich ~/.local/state/ubuntu-ostrich ~/.local/libexec/ubuntu-ostrich ~/.config/cleanest-ubuntu-setup 2>/dev/null' | grep -q . && bad "an old per-user folder is left" || ok "no old per-user folder"
	vmx ssh 'grep -rlE "ubuntu[-_]ostrich" ~/.local/share/applications ~/.config/autostart 2>/dev/null; ls ~/.local/share/applications ~/.config/autostart 2>/dev/null | grep -E "ubuntu[-_]ostrich"' | grep -q . &&
		bad "old-slug names or contents in applications/ or autostart/" || ok "nothing of the old slug in ~/.local/share/applications or ~/.config/autostart"
	vmx ssh 'bash -s' <<'EOF' && ok "tests/appid-lint.sh passes on the generated .desktop files (applications, autostart)" || bad "appid-lint failed on the generated .desktop files"
set -e
mkdir -p /tmp/lint && rm -rf /tmp/lint/* && cp ~/.local/share/applications/*.desktop ~/.config/autostart/*.desktop /tmp/lint/
ls /tmp/lint | grep -q .
bash ~/repo/tests/appid-lint.sh /tmp/lint
EOF

	if ((BREAK)); then
		if ((signed_in)); then
			log "CONTROL FAILED: the signed-in check passed with the cookies deleted"
			exit 2
		fi
		log "control ok: the signed-in check failed with the cookies deleted ($failures check(s) failed, as expected for the signed-in ones)"
		exit 1
	fi
}

# --- run ---------------------------------------------------------------------------------------
started=0
for s in "${STAGES[@]}"; do
	[[ $s == "$FROM" ]] && started=1
	((started)) || continue
	"stage_$s"
done
if ((RELEASE)); then "$HERE/lab.sh" "$SLOT" release; fi
if ((failures > 0)); then
	log "FAIL: $failures check(s) failed"
	exit 1
fi
log "PASS"
