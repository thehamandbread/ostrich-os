#!/usr/bin/env bash
# /opt/ubuntu-ostrich/firstboot/finish.sh: the first-login finish for the Ubuntu Ostrich image.
# Runs the same installer as the one-line command, using the copy and the release on the image,
# so only Ubuntu packages come from the internet. Asks for your password once (sudo).
set -uo pipefail
src_image=/opt/ubuntu-ostrich/src
src="${XDG_DATA_HOME:-$HOME/.local/share}/ubuntu-ostrich/src"
state="${XDG_STATE_HOME:-$HOME/.local/state}/ubuntu-ostrich"

printf '\n  Finishing Ubuntu Ostrich setup\n  ------------------------------\n'
printf '  This takes a few minutes and needs the internet for Ubuntu packages.\n'
printf '  You will be asked for your password once.\n\n'

if [[ ! -d $src/.git ]]; then
	mkdir -p "$(dirname "$src")"
	cp -a "$src_image" "$src"
fi
if RELEASE_URL=file:///opt/ubuntu-ostrich/release bash "$src/install.sh"; then
	mkdir -p "$state" && touch "$state/firstboot-done"
	printf '\n  All done. Log out and back in to switch everything on.\n'
	read -r -p '  Press Enter to log out now (or close this window to log out later). ' _
	gnome-session-quit --logout --no-prompt
else
	printf '\n  Something went wrong; nothing is lost. Details: %s/install.log\n' "$state"
	printf '  It tries again at your next login, or run: ostrich update\n'
	read -r -p '  Press Enter to close. ' _
fi
