#!/usr/bin/env bash
# /opt/ubuntu-ostrich/firstboot/start.sh: at login, open a terminal that finishes Ubuntu Ostrich's
# setup, once per user (installed by the Ubuntu Ostrich image; see image/build-iso.sh).
set -euo pipefail
done_file="${XDG_STATE_HOME:-$HOME/.local/state}/ubuntu-ostrich/firstboot-done"
[[ -e $done_file ]] && exit 0
finish=/opt/ubuntu-ostrich/firstboot/finish.sh
for term in "ptyxis --new-window --" "gnome-terminal --" "x-terminal-emulator -e"; do
	read -r -a cmd <<<"$term"
	if command -v "${cmd[0]}" >/dev/null 2>&1; then
		exec "${cmd[@]}" bash "$finish"
	fi
done
echo "ostrich: no terminal found; run $finish in one" >&2
exit 1
