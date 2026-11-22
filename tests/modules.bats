#!/usr/bin/env bats
# tests/modules.bats: module behaviour with stubbed system commands (nothing real is installed).

setup() {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	ROOT="$BATS_TEST_DIRNAME/.."
	export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
	STUBS="$BATS_TEST_TMPDIR/bin"
	CALLS="$BATS_TEST_TMPDIR/calls"
	export CALLS
	mkdir -p "$STUBS"
	: >"$CALLS"
	# Installed packages and remotes are listed in these files.
	export INSTALLED="$BATS_TEST_TMPDIR/installed" REMOTES="$BATS_TEST_TMPDIR/remotes"
	: >"$INSTALLED"
	: >"$REMOTES"
	# Flatpak's system folder: no Flathub app list in it unless a test puts one there.
	export FLATPAK_SYSTEM_DIR="$BATS_TEST_TMPDIR/flatpak"
	stub dpkg-query 'pkg=${@: -1}; grep -qx "$pkg" "$INSTALLED" && printf "install ok installed"; true'
	stub flatpak 'if [[ $1 == remotes ]]; then cat "$REMOTES"; else echo "flatpak $*" >>"$CALLS"; fi'
	stub sudo 'echo "sudo $*" >>"$CALLS"'
	export PATH="$STUBS:$PATH"
	# Nothing reaches the real desktop session: gsettings, dconf, xdg-mime and systemctl --user act on it, not
	# through $HOME (a test once changed the developer's own dock). Tests that need them stub them.
	local c
	for c in gsettings dconf xdg-mime systemctl; do
		stub "$c" "echo \"$c \$*\" >>\"\$BATS_TEST_TMPDIR/session-calls\""
	done
	# No speaker-tuning clips unless a test asks for them (nothing real is downloaded).
	export CLIPS_TSV="$BATS_TEST_TMPDIR/no-clips.tsv"
	: >"$CLIPS_TSV"
}

stub() {
	printf '#!/usr/bin/env bash\n%s\n' "$2" >"$STUBS/$1"
	chmod +x "$STUBS/$1"
}

@test "core: installs only missing packages and adds flathub" {
	printf 'curl\ngit\n' >"$INSTALLED"
	run "$ROOT/modules/core/install.sh"
	[ "$status" -eq 0 ]
	grep -q 'DPkg::Lock::Timeout=300 install -y --no-install-recommends ca-certificates jq unzip flatpak$' "$CALLS"
	grep -q 'sudo flatpak remote-add --if-not-exists flathub' "$CALLS"
	grep -q 'sudo flatpak update --appstream --noninteractive flathub' "$CALLS"
}

@test "core: second run with everything present changes nothing" {
	printf 'curl\nca-certificates\ngit\njq\nunzip\nflatpak\n' >"$INSTALLED"
	echo flathub >"$REMOTES"
	mkdir -p "$FLATPAK_SYSTEM_DIR/appstream/flathub/$(uname -m)/active"
	run "$ROOT/modules/core/install.sh"
	[ "$status" -eq 0 ]
	[ ! -s "$CALLS" ]
	! grep -q '\[CHANGE\]' "$XDG_STATE_HOME/ostrich-os/install.log"
}

@test "core: dry-run calls nothing privileged" {
	run "$ROOT/modules/core/install.sh" --dry-run
	[ "$status" -eq 0 ]
	[ ! -s "$CALLS" ]
	[[ $output == *"[WOULD] apt install"* ]]
}

@test "core: rejects unknown options" {
	run "$ROOT/modules/core/install.sh" --bogus
	[ "$status" -eq 1 ]
}

@test "terminal: installs ghostty once" {
	run "$ROOT/modules/terminal/install.sh"
	[ "$status" -eq 0 ]
	grep -q 'DPkg::Lock::Timeout=300 install -y --no-install-recommends ghostty$' "$CALLS"
	: >"$CALLS"
	echo ghostty >"$INSTALLED"
	run "$ROOT/modules/terminal/install.sh"
	[ ! -s "$CALLS" ]
}

# ---- gnome module (stubbed gsettings / gnome-extensions; zips built from the repo) ----

gnome_setup() {
	export GS="$BATS_TEST_TMPDIR/gsettings.db"
	printf '%s\n' "org.gnome.shell enabled-extensions @as []" "org.gnome.shell disabled-extensions @as []" "org.gnome.shell disable-user-extensions false" "org.gnome.shell start-in-overview false" \
		"org.gnome.desktop.notifications show-banners false" >"$GS"
	# get/set against a flat "schema key value" file
	stub gsettings 'case $1 in
list-schemas) echo org.gnome.shell ;;
get) grep -m1 "^$2 $3 " "$GS" | cut -d" " -f3- ;;
set) echo "gsettings set $2 $3 $4" >>"$CALLS"; grep -v "^$2 $3 " "$GS" >"$GS.n"; echo "$2 $3 $4" >>"$GS.n"; mv "$GS.n" "$GS" ;;
esac'
	# dconf goes through the real session's settings service, so it must never run unstubbed here.
	export DCONF="$BATS_TEST_TMPDIR/dconf.db"
	: >"$DCONF"
	stub dconf 'case $1 in
read) grep -m1 "^$2 " "$DCONF" | cut -d" " -f2- ;;
write) echo "dconf write $2 $3" >>"$CALLS"; grep -v "^$2 " "$DCONF" >"$DCONF.n"; echo "$2 $3" >>"$DCONF.n"; mv "$DCONF.n" "$DCONF" ;;
reset) echo "dconf reset $2 $3" >>"$CALLS" ;;
dump) grep "^$2" "$DCONF" || true ;;
esac'
	# the user's systemd manager is the real one too: record, never run
	stub systemctl 'echo "systemctl $*" >>"$CALLS"'
	export EXT_HOME="$HOME/.local/share/gnome-shell/extensions"
	# "install" unpacks the zip where GNOME would
	stub gnome-extensions 'if [[ $1 == install ]]; then echo "gnome-extensions $*" >>"$CALLS"; z=${@: -1}; u=$(basename "$z" .shell-extension.zip); rm -rf "$EXT_HOME/$u"; mkdir -p "$EXT_HOME/$u"; unzip -q "$z" -d "$EXT_HOME/$u"; if [[ -d $EXT_HOME/$u/schemas ]]; then : >"$EXT_HOME/$u/schemas/gschemas.compiled"; fi; else exec /usr/bin/gnome-extensions "$@"; fi'
	export DIST="$BATS_TEST_TMPDIR/dist"
}

@test "gnome: installs and enables extensions, turns banners on" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	[ "$(grep -c 'gnome-extensions install' "$CALLS")" -eq 11 ]
	grep -q "enabled-extensions \['monitor@ostrich-os', 'dock@ostrich-os', 'workspaces@ostrich-os', 'tweaks@ostrich-os', 'tray@ostrich-os', 'focus@ostrich-os', 'blur@ostrich-os', 'drawer@ostrich-os', 'tiling@ostrich-os', 'holder-monitor@ostrich-os', 'search-new-window@ostrich-os'\]" "$GS"
	grep -q "disabled-extensions \['ubuntu-dock@ubuntu.com', 'ubuntu-appindicators@ubuntu.com', 'space-bar@luchrioh', 'Vitals@CoreCoding.com', 'just-perfection-desktop@just-perfection', 'blur-my-shell@aunetx', 'tiling-assistant@ubuntu.com'\]" "$GS"
	grep -q 'show-banners true' "$GS"
}

@test "gnome: second run changes nothing" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	"$ROOT/modules/gnome/install.sh"
	: >"$CALLS"
	run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	[ ! -s "$CALLS" ]
}

@test "gnome: keeps other enabled extensions and backs up a changed install" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	sed -i "s|enabled-extensions @as \[\]|enabled-extensions ['ubuntu-dock@ubuntu.com', 'ding@rastersoft.com', 'nvidia-power@someone', 'Vitals@CoreCoding.com', 'dock@cleanest-ubuntu-setup', 'tray@ostrich-ubuntu']|" "$GS"
	mkdir -p "$EXT_HOME/monitor@ostrich-os" && echo old >"$EXT_HOME/monitor@ostrich-os/extension.js"
	run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	# keeps unrelated extensions, drops the ones ours replace (including a ported original)
	grep -q "enabled-extensions \['ding@rastersoft.com', 'monitor@ostrich-os'" "$GS"
	grep -q "disabled-extensions .*'nvidia-power@someone'" "$GS"
	grep -q "disabled-extensions .*'dock@cleanest-ubuntu-setup'" "$GS" # the project's former names
	grep -q "disabled-extensions .*'tray@ostrich-ubuntu'" "$GS"
	[ "$(cat "$XDG_STATE_HOME"/ostrich-os/backups/*"$EXT_HOME"/monitor@ostrich-os/extension.js)" = old ]
}

@test "gnome: an extension the user switched off stays off after an update" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	sed -i "s|disabled-extensions @as \[\]|disabled-extensions ['blur@ostrich-os']|" "$GS"
	run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	grep -q "enabled-extensions .*'dock@ostrich-os'" "$GS"
	! grep -q "enabled-extensions .*'blur@ostrich-os'" "$GS"
}

@test "gnome: warns when GNOME disabled user extensions" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	sed -i 's/disable-user-extensions false/disable-user-extensions true/' "$GS"
	run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"GNOME has disabled all user extensions"* ]]
}

@test "gnome: copies space-bar's name map once, never over an existing one" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	echo "/org/gnome/shell/extensions/space-bar/state/workspace-names-map '{\"firefox_firefox\":[\"1\"]}'" >"$DCONF"
	run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	grep -q 'dconf write /org/gnome/shell/extensions/ostrich-os/workspaces/names-map' "$CALLS"
	: >"$CALLS"
	run "$ROOT/modules/gnome/install.sh"
	! grep -q 'dconf write' "$CALLS"
}

@test "gnome: carries over Just Perfection's animation speed and start-in-overview" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	printf '%s\n' "/org/gnome/shell/extensions/just-perfection/animation 5" "/org/gnome/shell/extensions/just-perfection/startup-status 1" >"$DCONF"
	run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	grep -q 'dconf write /org/gnome/shell/extensions/ostrich-os/tweaks/animation-speed 0.8' "$CALLS"
	grep -q 'org.gnome.shell start-in-overview true' "$GS"
	# Turned off by the user afterwards: an update leaves it off.
	sed -i 's/^org.gnome.shell start-in-overview true$/org.gnome.shell start-in-overview false/' "$GS"
	run "$ROOT/modules/gnome/install.sh"
	grep -q 'org.gnome.shell start-in-overview false' "$GS"
}

@test "gnome: carries over Tiling Assistant's settings once" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	local ta=/org/gnome/shell/extensions/tiling-assistant ours=/org/gnome/shell/extensions/ostrich-os/tiling
	printf '%s\n' "$ta/focus-hint-color 'rgb(203,67,20)'" "$ta/tiling-popup-all-workspace true" "$ta/window-gap 8" "$ta/focus-hint 2" >"$DCONF"
	run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	grep -q "dconf write $ours/focus-hint-color 'rgb(203,67,20)'" "$CALLS"
	grep -q "dconf write $ours/fill-popup-all-workspaces true" "$CALLS"
	grep -q "dconf write $ours/window-gap uint32 8" "$CALLS"
	grep -q "dconf write $ours/focus-hint true" "$CALLS"
	: >"$CALLS"
	run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	! grep -q "dconf write $ours" "$CALLS"
}

@test "gnome: carries over Dash to Dock's hiding, icon size and its own colour" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	local dd=/org/gnome/shell/extensions/dash-to-dock ours=/org/gnome/shell/extensions/ostrich-os/dock
	# Always hidden until the bottom edge, 34 px, purple at 20 %: the owner's dock.
	printf '%s\n' "$dd/dock-fixed false" "$dd/autohide true" "$dd/intellihide false" "$dd/dash-max-icon-size 34" \
		"$dd/custom-background-color true" "$dd/background-color 'rgb(145,65,172)'" "$dd/background-opacity 0.2" >"$DCONF"
	run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	grep -q "dconf write $ours/autohide true" "$CALLS"
	grep -q "dconf write $ours/intellihide false" "$CALLS"
	grep -q "dconf write $ours/icon-size uint32 34" "$CALLS"
	grep -q "dconf write $ours/background-color '#9141ac'" "$CALLS"
	grep -q "dconf write $ours/background 'custom'" "$CALLS"
	grep -q "dconf write $ours/background-opacity 0.2" "$CALLS"
	: >"$CALLS"
	run "$ROOT/modules/gnome/install.sh"
	! grep -q "dconf write $ours" "$CALLS" # once: ours are set now
}

@test "gnome: a Dash to Dock colour it didn't use isn't copied" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	printf '%s\n' "/org/gnome/shell/extensions/dash-to-dock/background-color 'rgb(145,65,172)'" >"$DCONF"
	run "$ROOT/modules/gnome/install.sh"
	! grep -q "dconf write /org/gnome/shell/extensions/ostrich-os/dock/background" "$CALLS"
}

@test "gnome: carries over Vitals' top-bar readings, place and interval once" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	local v=/org/gnome/shell/extensions/vitals ours=/org/gnome/shell/extensions/ostrich-os/monitor
	printf '%s\n' "$v/hot-sensors ['_processor_usage_', '_memory_usage_', '__temperature_avg__', '_gpu#1_', '__network-rx_max__']" \
		"$v/position-in-panel 0" "$v/update-time 2" >"$DCONF"
	run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	grep -q "dconf write $ours/panel-items \['cpu.usage', 'mem.usage', 'temp.package', 'net.down'\]" "$CALLS"
	grep -q "dconf write $ours/panel-box 'left'" "$CALLS"
	grep -q "dconf write $ours/interval-ac uint32 2" "$CALLS"
	: >"$CALLS"
	run "$ROOT/modules/gnome/install.sh"
	! grep -q "dconf write $ours" "$CALLS"
}

@test "gnome: carries over Blur my Shell's strength and brightness from its pipelines once" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	python3 -I -c 'from gi.repository import GLib' 2>/dev/null || skip "needs PyGObject"
	gnome_setup
	local bms=/org/gnome/shell/extensions/blur-my-shell ours=/org/gnome/shell/extensions/ostrich-os/blur
	printf '%s\n' "$bms/pipelines {'pipeline_default': {'name': <'Default'>, 'effects': <[<{'type': <'native_static_gaussian_blur'>, 'id': <'effect_0'>, 'params': <{'radius': <30>, 'brightness': <0.6>}>}>]>}, 'pipeline_folders': {'name': <'Folders'>, 'effects': <[<{'type': <'native_static_gaussian_blur'>, 'id': <'effect_1'>, 'params': <{'radius': <60>, 'brightness': <0.2>}>}>]>}}" \
		"$bms/panel/pipeline 'pipeline_default'" "$bms/appfolder/pipeline 'pipeline_folders'" >"$DCONF"
	run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	grep -q "dconf write $ours/panel-radius uint32 30" "$CALLS"
	grep -q "dconf write $ours/panel-brightness 0.6" "$CALLS"
	grep -q "dconf write $ours/folders-radius uint32 60" "$CALLS"
	grep -q "dconf write $ours/folders-brightness 0.3" "$CALLS" # ours goes no darker than 0.3
	! grep -q "dconf write $ours/dock-radius" "$CALLS"          # it had no dock pipeline set
	: >"$CALLS"
	run "$ROOT/modules/gnome/install.sh"
	! grep -q "dconf write $ours" "$CALLS"
}

@test "gnome: a fixed Dash to Dock stays shown in ours" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	printf '%s\n' "/org/gnome/shell/extensions/dash-to-dock/dock-fixed true" >"$DCONF"
	run "$ROOT/modules/gnome/install.sh"
	grep -q "dconf write /org/gnome/shell/extensions/ostrich-os/dock/autohide false" "$CALLS"
}

# ---- tools module (a fake build or a fake release; nothing real is downloaded) ----

tools_fake_bins() {
	# The media decoders count as installed, so a second run changes nothing.
	printf '%s\n' gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav >>"$INSTALLED"
	mkdir -p "$1"
	local b
	for b in ostrich ostrich-drawer ostrich-setup ostrich-store ostrich-store-gtk ostrich-theme ostrich-speakers ostrich-system-helper; do
		printf '#!/bin/sh\necho %s\n' "$b" >"$1/$b"
		chmod +x "$1/$b"
	done
}

@test "tools: installs a local build, stages the helper, autostarts the drawer; idempotent" {
	export BUILD_DIR="$BATS_TEST_TMPDIR/build" DIST="$BATS_TEST_TMPDIR/dist"
	# The helper and its policy go to a fake root, and "sudo" really copies them there, so the second
	# run finds them in place.
	export HELPER_DEST="$BATS_TEST_TMPDIR/root/helper" POLICY_DEST="$BATS_TEST_TMPDIR/root/policy"
	stub sudo 'echo "sudo $*" >>"$CALLS"; "$@"'
	tools_fake_bins "$BUILD_DIR"
	# Default apps, remembered between runs: "default ID TYPE" sets, "query default TYPE" answers.
	stub xdg-mime 'm="$BATS_TEST_TMPDIR/mime"; case $1 in default) for t in "${@:3}"; do echo "$t $2" >>"$m"; done ;; query) awk -v t="$3" "\$1 == t { d = \$2 } END { if (d) print d }" "$m" 2>/dev/null ;; esac'
	run "$ROOT/modules/tools/install.sh"
	[ "$status" -eq 0 ]
	[ -x "$HOME/.local/bin/ostrich" ] && [ -x "$HOME/.local/libexec/ostrich-os/ostrich-store" ] && [ -x "$HOME/.local/libexec/ostrich-os/ostrich-drawer" ]
	[ -x "$DIST/ostrich-system-helper" ]
	[ ! -e "$HOME/.local/bin/ostrich-system-helper" ]
	[ -x "$HELPER_DEST" ] && [ -f "$POLICY_DEST" ]
	[ -f "$HOME/.config/systemd/user/ostrich-store-updates.timer" ]
	grep -q "^ExecStart=$HOME/.local/libexec/ostrich-os/ostrich-store-gtk --check-updates$" "$HOME/.config/systemd/user/ostrich-store-updates.service"
	grep -q "^Exec=$HOME/.local/libexec/ostrich-os/ostrich-drawer --hidden$" "$HOME/.config/autostart/ostrich-drawer.desktop"
	[ -f "$HOME/.config/autostart/ostrich-setup.desktop" ]
	[ -f "$HOME/.local/share/applications/ostrich_os.setup.desktop" ]
	[ "$(xdg-mime query default application/vnd.flatpak.ref)" = ostrich_os.store.desktop ]
	grep -q '^MimeType=application/vnd.flatpak.ref;' "$HOME/.local/share/applications/ostrich_os.store.desktop"
	run "$ROOT/modules/tools/install.sh"
	[ "$status" -eq 0 ]
	[[ $output != *CHANGE* ]]
}

@test "tools: everyday files get a default app when they have none, once" {
	export BUILD_DIR="$BATS_TEST_TMPDIR/build" DIST="$BATS_TEST_TMPDIR/dist"
	tools_fake_bins "$BUILD_DIR"
	export APP_DIRS="$BATS_TEST_TMPDIR/share"
	mkdir -p "$APP_DIRS/applications"
	touch "$APP_DIRS/applications/org.gnome.Showtime.desktop" "$APP_DIRS/applications/libreoffice-writer.desktop"
	stub xdg-mime 'm="$BATS_TEST_TMPDIR/mime"; case $1 in default) for t in "${@:3}"; do echo "$t $2" >>"$m"; done ;; query) awk -v t="$3" "\$1 == t { d = \$2 } END { if (d) print d }" "$m" 2>/dev/null ;; esac'
	echo "video/webm someone-elses.desktop" >"$BATS_TEST_TMPDIR/mime"
	run "$ROOT/modules/tools/install.sh"
	[ "$status" -eq 0 ]
	[ "$(xdg-mime query default video/mp4)" = org.gnome.Showtime.desktop ]
	[ "$(xdg-mime query default video/webm)" = someone-elses.desktop ]
	[ "$(xdg-mime query default application/vnd.openxmlformats-officedocument.wordprocessingml.document)" = libreoffice-writer.desktop ]
	[ -z "$(xdg-mime query default audio/mpeg)" ]
	run "$ROOT/modules/tools/install.sh"
	[[ $output != *"default app"* ]]
	# An app xdg-mime can't see (a snap off the data path) still counts once mimeapps.list names it.
	mkdir -p "$HOME/.config"
	printf '[Default Applications]\naudio/mpeg=some-snap_player.desktop\n' >"$HOME/.config/mimeapps.list"
	touch "$APP_DIRS/applications/org.gnome.Decibels.desktop"
	run "$ROOT/modules/tools/install.sh"
	[[ $output != *"default app for audio/mpeg"* ]]
	[[ $output == *"default app for audio/flac"* ]]
}

@test "tools: no welcome autostart once the wizard is finished" {
	export BUILD_DIR="$BATS_TEST_TMPDIR/build" DIST="$BATS_TEST_TMPDIR/dist"
	tools_fake_bins "$BUILD_DIR"
	mkdir -p "$HOME/.config/ostrich-os" && touch "$HOME/.config/ostrich-os/welcome-done"
	run "$ROOT/modules/tools/install.sh"
	[ "$status" -eq 0 ]
	[ ! -e "$HOME/.config/autostart/ostrich-setup.desktop" ]
	[ -f "$HOME/.local/share/applications/ostrich_os.setup.desktop" ]
}

# A clip "download" from a local file, a stubbed GStreamer, and a fake ostrich-speakers that writes
# the excerpt where the real one would.
tools_clip_setup() {
	export BUILD_DIR="$BATS_TEST_TMPDIR/build" DIST="$BATS_TEST_TMPDIR/dist"
	tools_fake_bins "$BUILD_DIR"
	printf '#!/bin/sh\nmkdir -p "$HOME/.local/share/ostrich-os/audio" && touch "$HOME/.local/share/ostrich-os/audio/$2.wav"\n' >"$BUILD_DIR/ostrich-speakers"
	stub gst-launch-1.0 'for a in "$@"; do case $a in location=*) out=${a#location=} ;; esac; done; echo wav >"$out"'
	echo "some audio" >"$BATS_TEST_TMPDIR/song.ogg"
	local sum
	sum=$(sha256sum "$BATS_TEST_TMPDIR/song.ogg" | cut -d' ' -f1)
	printf 'tune\tA song\tMusic\tfile://%s\t%s\t0\t20\tCC0\tSomeone\n' "$BATS_TEST_TMPDIR/song.ogg" "${1:-$sum}" >"$CLIPS_TSV"
}

@test "tools: installs the media decoders the drawer and the clips need" {
	export BUILD_DIR="$BATS_TEST_TMPDIR/build" DIST="$BATS_TEST_TMPDIR/dist"
	tools_fake_bins "$BUILD_DIR"
	: >"$INSTALLED"
	run "$ROOT/modules/tools/install.sh"
	[ "$status" -eq 0 ]
	grep -q 'DPkg::Lock::Timeout=300 install -y --no-install-recommends gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav' "$CALLS"
}

@test "tools: speaker-tuning clips are downloaded, checked and cut once" {
	command -v curl >/dev/null || skip "needs curl"
	tools_clip_setup
	run "$ROOT/modules/tools/install.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"speaker-tuning clip: A song (CC0, Someone)"* ]]
	[ -f "$HOME/.local/share/ostrich-os/audio/tune.wav" ]
	run "$ROOT/modules/tools/install.sh"
	[[ $output != *"speaker-tuning clip"* ]]
}

@test "tools: a clip with the wrong checksum is skipped (pink noise), the install goes on" {
	command -v curl >/dev/null || skip "needs curl"
	tools_clip_setup 0000000000000000000000000000000000000000000000000000000000000000
	run "$ROOT/modules/tools/install.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"couldn't get the speaker-tuning clip A song"* ]]
	[ ! -e "$HOME/.local/share/ostrich-os/audio/tune.wav" ]
}

@test "tools: downloads the release and verifies it; refuses a bad checksum" {
	command -v curl >/dev/null || skip "needs curl"
	export BUILD_DIR="$BATS_TEST_TMPDIR/none" DIST="$BATS_TEST_TMPDIR/dist"
	local v rel name
	v=$(cat "$ROOT/VERSION")
	rel="$BATS_TEST_TMPDIR/release"
	name="ostrich-os-tools-v$v-amd64"
	tools_fake_bins "$rel/$name/bin"
	echo zip >"$rel/monitor@ostrich-os.shell-extension.zip"
	tar -C "$rel" -czf "$rel/$name.tar.gz" "$name"
	(cd "$rel" && sha256sum "$name.tar.gz" monitor@ostrich-os.shell-extension.zip >SHA256SUMS)
	export RELEASE_URL="file://$rel"
	run "$ROOT/modules/tools/install.sh"
	[ "$status" -eq 0 ]
	[ -x "$HOME/.local/libexec/ostrich-os/ostrich-theme" ]
	[ -f "$DIST/monitor@ostrich-os.shell-extension.zip" ]

	rm -rf "$DIST" "$HOME/.local/bin" "$HOME/.local/libexec"
	echo tampered >>"$rel/$name.tar.gz"
	run "$ROOT/modules/tools/install.sh"
	[ "$status" -ne 0 ]
	[[ $output == *"checksum mismatch"* ]]
	[ ! -e "$HOME/.local/libexec/ostrich-os/ostrich-theme" ]
}

# ---- hardware modules (sysfs fixtures; sudo, prime-select, systemctl stubbed) ----

hw_setup() {
	export SYSFS_ROOT="$BATS_TEST_TMPDIR/sys" HELPER_SRC="$BATS_TEST_TMPDIR/helper"
	printf '#!/bin/sh\n' >"$HELPER_SRC" && chmod +x "$HELPER_SRC"
	export HELPER_DEST="$BATS_TEST_TMPDIR/root/helper" POLICY_DEST="$BATS_TEST_TMPDIR/root/policy"
	stub systemctl 'echo "systemctl $*" >>"$CALLS"; [[ $1 != is-enabled ]]'
	stub powerprofilesctl 'echo balanced'
}

pci() { # pci <slot> <class> <vendor>
	mkdir -p "$SYSFS_ROOT/bus/pci/devices/$1"
	echo "$2" >"$SYSFS_ROOT/bus/pci/devices/$1/class"
	echo "$3" >"$SYSFS_ROOT/bus/pci/devices/$1/vendor"
}

@test "nvidia-optimus: skips without hybrid graphics" {
	hw_setup
	pci 0000:00:02.0 0x030000 0x8086
	run "$ROOT/modules/hardware/nvidia-optimus/install.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"no NVIDIA hybrid graphics"* ]]
	[ ! -s "$CALLS" ]
}

@test "nvidia-optimus: installs prime tools and the helper, sets hybrid once, enables runtime D3" {
	hw_setup
	pci 0000:00:02.0 0x030000 0x8086
	pci 0000:01:00.0 0x030200 0x10de
	mkdir -p "$SYSFS_ROOT/module/nvidia"
	export NVIDIA_PARAMS="$BATS_TEST_TMPDIR/params" MODPROBE_CONF="$BATS_TEST_TMPDIR/root/nvidia-pm.conf"
	echo 'DynamicPowerManagement: 0' >"$NVIDIA_PARAMS"
	stub prime-select 'if [[ $1 == query ]]; then echo nvidia; else echo "prime-select $*" >>"$CALLS"; fi'
	run "$ROOT/modules/hardware/nvidia-optimus/install.sh"
	[ "$status" -eq 0 ]
	grep -q 'DPkg::Lock::Timeout=300 install -y --no-install-recommends nvidia-prime switcheroo-control' "$CALLS"
	grep -q "sudo install -D -m 0755 $HELPER_SRC $HELPER_DEST" "$CALLS"
	grep -q 'sudo prime-select on-demand' "$CALLS"
	grep -q "install -D -m 0644 .* $MODPROBE_CONF" "$CALLS"
	: >"$CALLS"
	run "$ROOT/modules/hardware/nvidia-optimus/install.sh"
	! grep -q 'prime-select on-demand' "$CALLS"
}

@test "power: installs the helper and enables the boot unit" {
	hw_setup
	mkdir -p "$SYSFS_ROOT/devices/system/cpu/intel_pstate" && echo 0 >"$SYSFS_ROOT/devices/system/cpu/intel_pstate/no_turbo"
	export UNIT_DEST="$BATS_TEST_TMPDIR/root/ost-power.service"
	run "$ROOT/modules/hardware/power/install.sh"
	[ "$status" -eq 0 ]
	grep -q "sudo install -D -m 0644 .* $UNIT_DEST" "$CALLS"
	grep -q 'sudo systemctl reenable ostrich-os-power.service' "$CALLS"
}

@test "power: skips on machines without the knobs" {
	hw_setup
	run "$ROOT/modules/hardware/power/install.sh"
	[ "$status" -eq 0 ]
	[[ $output == *skipping* ]]
	! grep -q sudo "$CALLS"
}

@test "package.sh: packs the binaries and zips the installer downloads, with checksums" {
	local bins="$BATS_TEST_TMPDIR/bins" zips="$BATS_TEST_TMPDIR/zips" out="$BATS_TEST_TMPDIR/out"
	tools_fake_bins "$bins"
	mkdir -p "$zips" && echo z >"$zips/dock@ostrich-os.shell-extension.zip"
	run "$ROOT/tools/package.sh" "$bins" "$zips" "$out"
	[ "$status" -eq 0 ]
	(cd "$out" && sha256sum --quiet -c SHA256SUMS)
	tar -tzf "$out/ostrich-os-tools-v$(cat "$ROOT/VERSION")-amd64.tar.gz" | grep -q '/bin/ostrich$'
	# what package.sh writes is what the tools module accepts (it downloads with curl)
	command -v curl >/dev/null || skip "needs curl for the install half"
	export BUILD_DIR="$BATS_TEST_TMPDIR/none" DIST="$BATS_TEST_TMPDIR/dist" RELEASE_URL="file://$out"
	run "$ROOT/modules/tools/install.sh"
	[ "$status" -eq 0 ]
	[ -x "$HOME/.local/bin/ostrich" ]
}

@test "gnome: --clean switches off every other user extension and resets its settings" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	sed -i "s|enabled-extensions @as \[\]|enabled-extensions ['dash-to-dock@micxgx.gmail.com']|" "$GS"
	mkdir -p "$EXT_HOME/dash-to-dock@micxgx.gmail.com/schemas"
	echo '<schemalist><schema id="x" path="/org/gnome/shell/extensions/dash-to-dock/"/><schema id="y" path="/org/gnome/shell/extensions/dash-to-dock-unset/"/></schemalist>' >"$EXT_HOME/dash-to-dock@micxgx.gmail.com/schemas/x.gschema.xml"
	echo "/org/gnome/shell/extensions/dash-to-dock/dock-fixed true" >>"$DCONF"
	INSTALL_MODE=clean run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	grep -q "disabled-extensions .*'dash-to-dock@micxgx.gmail.com'" "$GS"
	grep -q 'dconf reset -f /org/gnome/shell/extensions/dash-to-dock/' "$CALLS"
	! grep -q 'dash-to-dock-unset' "$CALLS"          # nothing set there: nothing to reset or log
	[ -d "$EXT_HOME/dash-to-dock@micxgx.gmail.com" ] # never deleted
}

@test "gnome: keep (the default) leaves other extensions on" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	sed -i "s|enabled-extensions @as \[\]|enabled-extensions ['dash-to-dock@micxgx.gmail.com']|" "$GS"
	mkdir -p "$EXT_HOME/dash-to-dock@micxgx.gmail.com"
	run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	grep -q "enabled-extensions \['dash-to-dock@micxgx.gmail.com'" "$GS"
	! grep -q 'dconf reset' "$CALLS"
}

@test "tools: Ostrich Store takes App Center's place in the dock, once" {
	export BUILD_DIR="$BATS_TEST_TMPDIR/build" DIST="$BATS_TEST_TMPDIR/dist"
	tools_fake_bins "$BUILD_DIR"
	echo "['firefox_firefox.desktop', 'snap-store_snap-store.desktop', 'org.gnome.Yelp.desktop']" >"$BATS_TEST_TMPDIR/favs"
	stub gsettings 'f="$BATS_TEST_TMPDIR/favs"; case $1 in list-schemas) echo org.gnome.shell ;; get) cat "$f" ;; set) echo "$4" >"$f" ;; esac'
	run "$ROOT/modules/tools/install.sh"
	[ "$status" -eq 0 ]
	[ "$(cat "$BATS_TEST_TMPDIR/favs")" = "['firefox_firefox.desktop', 'ostrich_os.store.desktop', 'org.gnome.Yelp.desktop']" ]
	run "$ROOT/modules/tools/install.sh"
	[[ $output != *"favorite-apps"* ]]
	# Taken out of the dock by the user: an update leaves it out.
	echo "['firefox_firefox.desktop']" >"$BATS_TEST_TMPDIR/favs"
	run "$ROOT/modules/tools/install.sh"
	[ "$(cat "$BATS_TEST_TMPDIR/favs")" = "['firefox_firefox.desktop']" ]
}

# home/run_onchange_after_ostrich-settings.sh.tmpl, as chezmoi renders it (the hash line aside).
@test "dotfiles: settings.dconf is applied, unless it's only comments or sets a command" {
	script="$BATS_TEST_TMPDIR/load.sh"
	sed '/{{/d' "$ROOT/home/run_onchange_after_ostrich-settings.sh.tmpl" >"$script"
	stub dconf 'cat >>"$BATS_TEST_TMPDIR/loaded"; echo "$@" >>"$CALLS"'
	f="$HOME/.config/ostrich-os/settings.dconf"
	mkdir -p "$(dirname "$f")"
	cp "$ROOT/home/dot_config/ostrich-os/settings.dconf" "$f"
	run bash "$script"
	[ "$status" -eq 0 ] && [ ! -e "$BATS_TEST_TMPDIR/loaded" ]
	printf '# mine\n[dock]\nicon-size=uint32 48\n' >"$f"
	run bash "$script"
	[ "$status" -eq 0 ]
	grep -q "load /org/gnome/shell/extensions/ostrich-os/" "$CALLS"
	[ "$(cat "$BATS_TEST_TMPDIR/loaded")" = "$(printf '[dock]\nicon-size=uint32 48')" ]
	rm "$BATS_TEST_TMPDIR/loaded"
	printf '[drawer]\nhost-command=%s\n' "'sh -c evil'" >"$f"
	run bash "$script"
	[[ $output == *"not applied"* ]] && [ ! -e "$BATS_TEST_TMPDIR/loaded" ]
	printf '[../../desktop/background]\npicture-uri=%s\n' "'x'" >"$f"
	run bash "$script"
	[[ $output == *"not applied"* ]] && [ ! -e "$BATS_TEST_TMPDIR/loaded" ]
}

@test "gnome: a zip older than its source is rebuilt (a checkout after a pull)" {
	command -v /usr/bin/gnome-extensions >/dev/null || skip "needs gnome-extensions to build zips"
	gnome_setup
	"$ROOT/modules/gnome/install.sh"
	touch -d 2000-01-01 "$DIST/dock@ostrich-os.shell-extension.zip"
	run "$ROOT/modules/gnome/install.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"building extensions: dock"* ]]
	[ "$DIST/dock@ostrich-os.shell-extension.zip" -nt "$ROOT/modules/gnome/extensions/build.sh" ]
}
