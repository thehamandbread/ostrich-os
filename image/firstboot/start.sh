#!/usr/bin/env bash
# /opt/ostrich-os/firstboot/start.sh: at login, open a terminal that finishes Ostrich OS's
# setup, once per user (installed by the Ostrich OS image; see image/build-iso.sh).
set -euo pipefail
done_file="${XDG_STATE_HOME:-$HOME/.local/state}/ostrich-os/firstboot-done"
[[ -e $done_file ]] && exit 0
finish=/opt/ostrich-os/firstboot/finish.sh
for term in "ptyxis --new-window --" "gnome-terminal --" "x-terminal-emulator -e"; do
	read -r -a cmd <<<"$term"
	if command -v "${cmd[0]}" >/dev/null 2>&1; then
		exec "${cmd[@]}" bash "$finish"
	fi
done
echo "ostrich: no terminal found; run $finish in one" >&2
exit 1
