#!/usr/bin/env bash
# modules/tools/install.sh: the `ostrich` command and the tools behind it (store, theme, speakers,
# drawer, setup), the system helper and, for release installs, the prebuilt extension zips.
#
# From a checkout with a build in tools/target/release, those binaries are used. Otherwise the
# release for VERSION is downloaded and checked against its SHA256SUMS. `ostrich` goes to
# ~/.local/bin and the tools it runs to ~/.local/libexec/ubuntu-ostrich. The system helper is staged
# in dist/ and installed as root here: the Store needs it on every machine (sandbox profiles for apps
# from GitHub); the hardware modules reinstall it only if it changed. The drawer starts hidden at login, so messaging services
# can notify. The wizard is in the app grid and opens at the next login until it's finished.
set -euo pipefail
# shellcheck source=lib/module.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/module.sh"
# shellcheck source=lib/gsettings.sh
source "$LIB_DIR/gsettings.sh"
module_init "$@"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST="${DIST:-$REPO/dist}"
VERSION="$(cat "$REPO/VERSION")"
RELEASE_URL="${RELEASE_URL:-https://github.com/thehamandbread/ubuntu-ostrich/releases/download/v$VERSION}"
BUILD_DIR="${BUILD_DIR:-$REPO/tools/target/release}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LIBEXEC_DIR="${LIBEXEC_DIR:-$HOME/.local/libexec/ubuntu-ostrich}"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
LIBEXEC_TOOLS=(ostrich-drawer ostrich-setup ostrich-store ostrich-store-gtk ostrich-theme ostrich-speakers)
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
STORE_ID=ubuntu-ostrich.store.desktop
WELCOME_DONE="${XDG_CONFIG_HOME:-$HOME/.config}/ubuntu-ostrich/welcome-done"
HELPER=ostrich-system-helper
TARBALL="ubuntu-ostrich-tools-v$VERSION-amd64.tar.gz"

# shellcheck source=lib/tools-build.sh
source "$LIB_DIR/tools-build.sh"

# The checkout's own build when there is one (a partial or stale one stops here, as in install.sh).
have_build() {
	check_tools_build "$BUILD_DIR" "$REPO"
	[[ $(tools_build_state "$BUILD_DIR" "$REPO") != none ]]
}

# Downloads and verifies the release into $DIST/release; prints the directory with bin/.
fetch_release() {
	local dir="$DIST/release/v$VERSION"
	if [[ -x $dir/${TARBALL%.tar.gz}/bin/$HELPER ]]; then
		echo "$dir/${TARBALL%.tar.gz}"
		return 0
	fi
	command -v curl >/dev/null 2>&1 || die "curl is needed to download the tools"
	mkdir -p "$dir"
	info "downloading tools v$VERSION from $RELEASE_URL"
	curl -fsSL -o "$dir/SHA256SUMS" "$RELEASE_URL/SHA256SUMS" || die "could not download $RELEASE_URL/SHA256SUMS"
	curl -fsSL -o "$dir/$TARBALL" "$RELEASE_URL/$TARBALL" || die "could not download $RELEASE_URL/$TARBALL"
	local f
	while read -r _ f; do
		[[ $f == *.shell-extension.zip ]] || continue
		curl -fsSL -o "$dir/$f" "$RELEASE_URL/$f" || die "could not download $f"
	done <"$dir/SHA256SUMS"
	(cd "$dir" && sha256sum --quiet -c SHA256SUMS) || die "checksum mismatch in the v$VERSION release; nothing installed"
	tar -xzf "$dir/$TARBALL" -C "$dir"
	# The gnome module installs prebuilt zips from $DIST when they're there.
	cp "$dir"/*.shell-extension.zip "$DIST"/ 2>/dev/null || true
	echo "$dir/${TARBALL%.tar.gz}"
}

if have_build; then
	SRC="$BUILD_DIR"
	info "using the tools built in $BUILD_DIR"
elif ((DRY_RUN)); then
	info "dry run: tools v$VERSION would be downloaded from $RELEASE_URL and verified"
	module_done
	exit 0
else
	SRC="$(fetch_release)/bin"
fi

install_file "$SRC/ostrich" "$BIN_DIR/ostrich" 0755
for b in "${LIBEXEC_TOOLS[@]}"; do
	install_file "$SRC/$b" "$LIBEXEC_DIR/$b" 0755
done
mkdir -p "$DIST"
if ! cmp -s "$SRC/$HELPER" "$DIST/$HELPER" 2>/dev/null; then
	((DRY_RUN)) || install -m 0755 "$SRC/$HELPER" "$DIST/$HELPER"
fi
HELPER_SRC="$DIST/$HELPER"
have_helper_build && install_system_helper

# Our app icons (made by tools/icons/export.sh): two sets, icons/ for the dark style and icons-light/
# for the light one. Both go to $SETS_DIR; the one for the current style goes into the icon theme as
# ostrich-NAME in scalable/apps, and ostrich-icon-style swaps them when the style changes. The 16 px
# ostrich-NAME-symbolic (the same in both sets) go to symbolic/apps.
SETS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ubuntu-ostrich/icons"
case $(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || true) in
*prefer-dark*) STYLE_DIR="$REPO/modules/tools/icons" ;;
*) STYLE_DIR="$REPO/modules/tools/icons-light" ;;
esac
for icon in "$REPO"/modules/tools/icons/*.svg; do
	name=$(basename "$icon")
	case $name in
	*-symbolic.svg) install_file "$icon" "$ICONS_DIR/symbolic/apps/$name" ;;
	*)
		install_file "$icon" "$SETS_DIR/dark/$name"
		install_file "$REPO/modules/tools/icons-light/$name" "$SETS_DIR/light/$name"
		install_file "$STYLE_DIR/$name" "$ICONS_DIR/scalable/apps/$name"
		;;
	esac
done
install_file "$REPO/modules/tools/ostrich-icon-style" "$LIBEXEC_DIR/ostrich-icon-style" 0755

autostart=$(mktemp)
trap 'rm -f "$autostart"' EXIT
cat >"$autostart" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Drawer
Comment=Ubuntu Ostrich web-app drawer (starts hidden; Super+Alt+D shows it)
Exec=$LIBEXEC_DIR/ostrich-drawer --hidden
Icon=ostrich-drawer
NoDisplay=true
X-GNOME-Autostart-enabled=true
DESKTOP
install_file "$autostart" "$AUTOSTART_DIR/ostrich-drawer.desktop"
cat >"$autostart" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Ostrich icon style
Comment=Swaps our app icons when the light or dark style changes
Exec=$LIBEXEC_DIR/ostrich-icon-style watch
NoDisplay=true
X-GNOME-Autostart-enabled=true
DESKTOP
install_file "$autostart" "$AUTOSTART_DIR/ostrich-icon-style.desktop"
# The drawer's own app entry, hidden from the app grid: GNOME ties the drawer's window to it (our
# icon, its notifications) instead of a placeholder app with a gear icon.
cat >"$autostart" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Ostrich Drawer
Comment=Your web apps in the top bar
Exec=$LIBEXEC_DIR/ostrich-drawer
Icon=ostrich-drawer
NoDisplay=true
X-GNOME-UsesNotifications=true
DESKTOP
install_file "$autostart" "$APPS_DIR/ubuntu_ostrich.drawer.desktop"
# Up to 0.1.4 the drawer was ubuntu-ostrich.drawer (an id the desktop portal crashes on): its
# launcher and per-site entries go.
for f in "$APPS_DIR"/ubuntu-ostrich.drawer*.desktop; do
	[[ -e $f ]] || continue
	changed "remove the old drawer entry $f"
	run_cmd rm -f -- "$f"
done

cat >"$autostart" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Ostrich Settings
Comment=Every Ubuntu Ostrich setting: theme, dock, drawer, blur, workspaces, power, speakers and more
Exec=$LIBEXEC_DIR/ostrich-setup
Icon=ostrich-settings
Categories=Settings;
DESKTOP
# Named after the app id, so GNOME ties the window (and its notices) to this entry.
install_file "$autostart" "$APPS_DIR/ubuntu-ostrich.setup.desktop"
# Opens at the next login until it's finished (it removes this entry itself).
if [[ ! -e $WELCOME_DONE ]]; then
	install_file "$autostart" "$AUTOSTART_DIR/ostrich-setup.desktop"
fi

cat >"$autostart" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Ostrich Store
Comment=Find and install apps from Flathub, or from a GitHub link
Exec=$LIBEXEC_DIR/ostrich-store-gtk %U
Icon=ostrich-store
Categories=System;PackageManager;
Keywords=apps;install;flatpak;flathub;github;
MimeType=application/vnd.flatpak.ref;application/vnd.flatpak.repo;x-scheme-handler/appstream;
DESKTOP
install_file "$autostart" "$APPS_DIR/$STORE_ID"

# A daily look for updates (Flatpak and apps from GitHub): a notification when there are some, whose
# button opens the Store's Updates tab (owner, 2026-11-18). Persistent: a day missed while the
# laptop was off is caught up at the next login.
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
cat >"$autostart" <<UNIT
[Unit]
Description=Ostrich Store: look for app updates

[Service]
Type=simple
ExecStart=$LIBEXEC_DIR/ostrich-store-gtk --check-updates
# The Store window the notification opens outlives this check (else it closes when the check ends).
KillMode=process
UNIT
install_file "$autostart" "$UNIT_DIR/ostrich-store-updates.service"
cat >"$autostart" <<UNIT
[Unit]
Description=Ostrich Store: look for app updates daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
UNIT
install_file "$autostart" "$UNIT_DIR/ostrich-store-updates.timer"
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
	run_cmd systemctl --user daemon-reload
	systemctl --user is-enabled --quiet ostrich-store-updates.timer 2>/dev/null ||
		run_cmd systemctl --user enable --now ostrich-store-updates.timer
fi

# Ostrich Store is the store: in the dock, in App Center's place (App Center stays in the app grid:
# it's Ubuntu's store for snaps and Ubuntu packages, and snaps update through it), and the app that
# opens Flatpak files and app links. The restore point puts the dock back; mimeapps.list is backed up.
# Pinned once: a Store the user took out of the dock stays out after an update.
PIN_MARK="$STATE_DIR/store-pinned"
if [[ ! -e $PIN_MARK ]] && command -v gsettings >/dev/null 2>&1 && gsettings list-schemas 2>/dev/null | grep -qx org.gnome.shell; then
	mapfile -t favs < <(gs_list org.gnome.shell favorite-apps)
	if ! printf '%s\n' "${favs[@]}" | grep -qxF "$STORE_ID"; then
		new="" placed=0
		for f in "${favs[@]}"; do
			if [[ $f == snap-store_snap-store.desktop ]]; then
				f=$STORE_ID placed=1
			fi
			new+="${new:+, }'$f'"
		done
		((placed)) || new+="${new:+, }'$STORE_ID'"
		gs_set org.gnome.shell favorite-apps "[$new]"
	fi
	((DRY_RUN)) || { mkdir -p "$STATE_DIR" && touch "$PIN_MARK"; }
fi
MIMEAPPS="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
STORE_TYPES=(application/vnd.flatpak.ref application/vnd.flatpak.repo x-scheme-handler/appstream)
missing_types=()
command -v xdg-mime >/dev/null 2>&1 || STORE_TYPES=()
for t in "${STORE_TYPES[@]}"; do
	[[ $(xdg-mime query default "$t" 2>/dev/null) == "$STORE_ID" ]] || missing_types+=("$t")
done
if ((${#missing_types[@]} > 0)); then
	if [[ -e $MIMEAPPS ]]; then backup_file "$MIMEAPPS"; else record_created "$MIMEAPPS"; fi
	for t in "${missing_types[@]}"; do
		changed "default app for $t: Ostrich Store"
		run_cmd xdg-mime default "$STORE_ID" "$t"
	done
fi

# Everyday files open in something on a fresh install (council test T14 found no default for video,
# music, web pages or Word files). Each kind gets the first app on its list that is installed, and
# only when nothing opens it yet: a choice already made, by the user or the system, is left alone.
APP_DIRS="${APP_DIRS:-${XDG_DATA_HOME:-$HOME/.local/share}:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:/var/lib/snapd/desktop:/var/lib/flatpak/exports/share:$HOME/.local/share/flatpak/exports/share}"
desktop_installed() { # desktop-file id
	local d
	local IFS=:
	for d in $APP_DIRS; do
		[[ -f $d/applications/$1 ]] && return 0
	done
	return 1
}
# The app set for a type: xdg-mime's answer, or else the user's own mimeapps.list (xdg-mime can't
# see an app it can't find on the data path, e.g. a snap's when /var/lib/snapd/desktop isn't on it).
mime_default() { # type
	local d
	d=$(xdg-mime query default "$1" 2>/dev/null)
	[[ -z $d && -f $MIMEAPPS ]] && d=$(awk -F= -v t="$1" '/^\[/ { s = ($0 == "[Default Applications]") } s && $1 == t { print $2 }' "$MIMEAPPS")
	printf '%s' "$d"
}
EVERYDAY=(
	"video/mp4 video/webm video/x-matroska video/quicktime|org.gnome.Showtime.desktop org.gnome.Totem.desktop vlc.desktop"
	"audio/mpeg audio/flac audio/ogg audio/x-wav audio/mp4|org.gnome.Decibels.desktop org.gnome.Rhythmbox3.desktop vlc.desktop"
	"text/html x-scheme-handler/http x-scheme-handler/https|firefox_firefox.desktop firefox.desktop"
	"application/vnd.openxmlformats-officedocument.wordprocessingml.document application/msword application/vnd.oasis.opendocument.text|libreoffice-writer.desktop libreoffice_writer.desktop"
)
command -v xdg-mime >/dev/null 2>&1 || EVERYDAY=()
backed_up=$((${#missing_types[@]} > 0))
for entry in "${EVERYDAY[@]}"; do
	app=""
	for candidate in ${entry#*|}; do
		if desktop_installed "$candidate"; then
			app=$candidate
			break
		fi
	done
	[[ -n $app ]] || continue
	for t in ${entry%%|*}; do
		[[ -z $(mime_default "$t") ]] || continue
		if ((!backed_up)); then
			if [[ -e $MIMEAPPS ]]; then backup_file "$MIMEAPPS"; else record_created "$MIMEAPPS"; fi
			backed_up=1
		fi
		changed "default app for $t: $app"
		run_cmd xdg-mime default "$app" "$t"
	done
done

# Video and audio decoders for Ostrich Drawer (WebKitGTK plays media through GStreamer; YouTube
# needs VP9, AV1 and H.264) and for decoding the speaker-tuning clips below. Ubuntu's own packages.
MEDIA_PACKAGES=(gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav)
apt_install "${MEDIA_PACKAGES[@]}"

# Music and speech for tuning the speakers by ear (public domain, from Wikimedia Commons; the list,
# with each file's SHA-256, is tools/audio-tune/data/clips.tsv). Each is downloaded, checked,
# decoded with GStreamer (Ubuntu's own) and cut to a 20-second excerpt. Without one (offline, a
# checksum mismatch) the tuner uses pink noise instead. Nothing is downloaded twice.
CLIPS_TSV="${CLIPS_TSV:-$REPO/tools/audio-tune/data/clips.tsv}"
CLIP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ubuntu-ostrich/audio"
install_clips() {
	local id name _kind url sha _start _secs licence credit tmp
	if ! command -v gst-launch-1.0 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
		warn "GStreamer or curl is missing: the speaker tuner will use pink noise"
		return 0
	fi
	while IFS=$'\t' read -r id name _kind url sha _start _secs licence credit; do
		[[ -z $id || $id == \#* ]] && continue
		[[ -f $CLIP_DIR/$id.wav ]] && continue
		if ((DRY_RUN)); then
			info "dry run: would download the speaker-tuning clip $name ($licence)"
			continue
		fi
		tmp=$(mktemp -d)
		if curl -fsSL --max-time 180 -o "$tmp/source" "$url" &&
			echo "$sha  $tmp/source" | sha256sum --quiet -c - 2>/dev/null &&
			gst-launch-1.0 -q filesrc location="$tmp/source" ! decodebin ! audioconvert ! audioresample \
				! "audio/x-raw,rate=48000,channels=2,format=S16LE" ! wavenc ! filesink location="$tmp/full.wav" >/dev/null 2>&1 &&
			"$LIBEXEC_DIR/ostrich-speakers" clip-cut "$id" "$tmp/full.wav" >/dev/null; then
			changed "speaker-tuning clip: $name ($licence, $credit)"
		else
			warn "couldn't get the speaker-tuning clip $name; the tuner uses pink noise for it"
		fi
		rm -rf "$tmp"
	done <"$CLIPS_TSV"
}
install_clips

module_done
