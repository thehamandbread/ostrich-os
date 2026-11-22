#!/usr/bin/env bash
# Headless screenshot of a real Ostrich GTK app in an ubuntu:26.04 container (no GPU, no compositor).
# Run from the repo root (the tools are built binaries, not built here):
#   docker run --rm -v "$BIN:/ostrich-setup:ro" -v "$PWD/modules/gnome/extensions:/ext:ro" \
#     -v "$PWD/docs/plans/evidence/headless-shot.sh:/shot.sh:ro" -v "$OUT:/out" ubuntu:26.04 bash /shot.sh dock
# Works: light theme, 100 % text. Does NOT work here: dark, 200 % text (see 02-tour-and-settings.md).
set -eu
page=${1:-dock}
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq libgtk-4-1 libadwaita-1-0 xvfb imagemagick x11-utils adwaita-icon-theme \
	fonts-ubuntu libglib2.0-bin libglib2.0-dev-bin gsettings-desktop-schemas dconf-gsettings-backend \
	librsvg2-common gstreamer1.0-plugins-base libasound2t64 >/dev/null
# The settings pages bind to each extension's GSettings schema, so install the schemas like the installer does.
for e in /ext/*/; do
	n=$(basename "$e")
	d="$HOME/.local/share/gnome-shell/extensions/$n@ubuntu-ostrich"
	mkdir -p "$d"
	if [ -d "$e/schemas" ]; then cp -r "$e/schemas" "$d/" && glib-compile-schemas "$d/schemas"; fi
done
export GDK_BACKEND=x11 GSK_RENDERER=cairo LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1 GTK_A11Y=none DISPLAY=:99
Xvfb :99 -screen 0 1280x900x24 >/dev/null 2>&1 &
sleep 2
/ostrich-setup --step "$page" >/tmp/app.log 2>&1 &
sleep 5
import -window root "/out/ostrich-setup-$page.png"
