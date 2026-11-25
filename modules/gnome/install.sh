#!/usr/bin/env bash
# modules/gnome/install.sh: our GNOME Shell extensions and desktop defaults.
#
# Extensions come from dist/*.shell-extension.zip (built by modules/gnome/extensions/build.sh; release
# artifacts later). Each is installed only when its content differs from what is installed, and the
# installed copy is backed up first. New extensions load at the next login (GNOME on Wayland).
set -euo pipefail
# shellcheck source=lib/module.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/module.sh"
# shellcheck source=lib/gsettings.sh
source "$LIB_DIR/gsettings.sh"
module_init "$@"

if ! command -v gsettings >/dev/null 2>&1 || ! gsettings list-schemas 2>/dev/null | grep -qx org.gnome.shell; then
	info "GNOME Shell not found; skipping the gnome module"
	module_done
	exit 0
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST="${DIST:-$REPO/dist}"
PALETTE="${PALETTE:-$REPO/tools/icons/palette.toml}" # the colour scheme (tools/icons/schemes/)
EXT_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions"
EXTENSIONS=(monitor dock workspaces tweaks tray focus blur drawer tiling holder-monitor search-new-window)
# Extensions ours replace (by function, or the originals of the ones we ported). Ubuntu enables
# ubuntu-dock through its session mode, so replaced extensions are switched off through
# disabled-extensions as well as dropped from enabled-extensions. Nothing is uninstalled.
REPLACED=(ubuntu-dock@ubuntu.com ubuntu-appindicators@ubuntu.com space-bar@luchrioh Vitals@CoreCoding.com just-perfection-desktop@just-perfection blur-my-shell@aunetx tiling-assistant@ubuntu.com)
# The original machine's own extensions that ours are ports of (any user name before the @).
REPLACED_PREFIXES=(nvidia-power@ holder-monitor@ new-window-on-search@)
# Our own extensions under the project's former names (The Cleanest Ubuntu Setup, Ostrich Ubuntu,
# Ubuntu Ostrich): switched off here; lib/migrate.sh renames the entries it finds.
OLD_SUFFIXES=(@cleanest-ubuntu-setup @ostrich-ubuntu @ubuntu-ostrich)

uuid_of() { sed -n 's/^ *"uuid": *"\([^"]*\)".*/\1/p' "$REPO/modules/gnome/extensions/$1/metadata.json"; }

# Builds zips from source when they are missing or older than their source or the palette (a
# checkout after a pull); release installs ship them prebuilt.
ensure_built() {
	local name zip src="$REPO/modules/gnome/extensions" missing=()
	for name in "${EXTENSIONS[@]}"; do
		zip=$DIST/$(uuid_of "$name").shell-extension.zip
		if [[ ! -f $zip ]] || [[ -n $(find "$src/$name" "$src/_lib" "$src/build.sh" "$PALETTE" -newer "$zip" -print -quit) ]]; then
			missing+=("$name")
		fi
	done
	((${#missing[@]} == 0)) && return 0
	command -v gnome-extensions >/dev/null 2>&1 || die "gnome-extensions not found; is GNOME Shell installed?"
	info "building extensions: ${missing[*]}"
	DIST="$DIST" PALETTE="$PALETTE" "$REPO/modules/gnome/extensions/build.sh" "${missing[@]}" >/dev/null
}

# 0 if the installed copy of a uuid has exactly the zip's content (gnome-extensions install adds
# the compiled schemas, which the zip doesn't carry).
up_to_date() {
	local uuid=$1 zip=$2 tmp rc
	[[ -d $EXT_HOME/$uuid ]] || return 1
	tmp=$(mktemp -d)
	unzip -q "$zip" -d "$tmp"
	diff -rq -x gschemas.compiled "$tmp" "$EXT_HOME/$uuid" >/dev/null 2>&1
	rc=$?
	rm -rf "$tmp"
	return "$rc"
}

# reset_extension_settings <dir>: reset the dconf paths an extension's schemas declare.
reset_extension_settings() {
	command -v dconf >/dev/null 2>&1 || return 0
	local xml path
	for xml in "$1"/schemas/*.gschema.xml; do
		[[ -f $xml ]] || continue
		while IFS= read -r path; do
			[[ $path == /org/gnome/shell/extensions/* ]] || continue # never anything wider
			[[ -n $(dconf dump "$path" 2>/dev/null) ]] || continue   # already at defaults: nothing to log
			changed "reset settings $path ($(basename "$1"))"
			run_cmd dconf reset -f "$path"
		done < <(grep -o 'path="[^"]*"' "$xml" | sed 's/^path="//; s/"$//')
	done
}

install_extensions() {
	local name uuid zip
	local -a uuids=()
	for name in "${EXTENSIONS[@]}"; do
		uuid=$(uuid_of "$name")
		zip="$DIST/$uuid.shell-extension.zip"
		uuids+=("$uuid")
		if ((!DRY_RUN)) || [[ -f $zip ]]; then
			up_to_date "$uuid" "$zip" && continue
		fi
		# Ours from an earlier install isn't an original: only a first install records it (created).
		if [[ -e $EXT_HOME/$uuid ]]; then backup_file "$EXT_HOME/$uuid"; else record_created "$EXT_HOME/$uuid"; fi
		changed "install extension $uuid"
		run_cmd gnome-extensions install --force "$zip"
	done
	local -a replaced=("${REPLACED[@]}") prefix e
	for prefix in "${REPLACED_PREFIXES[@]}"; do
		while IFS= read -r e; do
			[[ $e == "$prefix"* && $e != *@ostrich-os ]] && replaced+=("$e")
		done < <(gs_list org.gnome.shell enabled-extensions)
	done
	local old
	for old in "${OLD_SUFFIXES[@]}"; do
		while IFS= read -r e; do
			[[ $e == *"$old" ]] && replaced+=("$e")
		done < <(gs_list org.gnome.shell enabled-extensions)
	done
	# Clean install (install.sh --clean): every other user-installed extension goes off as well, and
	# its settings are reset. Its files stay, and the restore point has its settings.
	if [[ ${INSTALL_MODE:-keep} == clean ]]; then
		local dir u
		for dir in "$EXT_HOME"/*/; do
			[[ -d $dir ]] || continue
			u=$(basename "$dir")
			[[ $u == *@ostrich-os ]] && continue
			replaced+=("$u")
			reset_extension_settings "$dir"
		done
	fi
	# Switch off what ours replace before switching ours on: the running shell applies each write at
	# once, and two docks, drawers or tilings live side by side fight over the same shortcuts and
	# settings (seen as an intermittent shell crash when upgrading from a former name).
	gs_list_remove org.gnome.shell enabled-extensions "${replaced[@]}"
	gs_list_add org.gnome.shell disabled-extensions "${replaced[@]}"
	# One write for all of ours: separate `gnome-extensions enable` calls race on the same key. One
	# the user switched off (Ostrich Settings moves it to disabled-extensions) stays off.
	local -a off on=()
	mapfile -t off < <(gs_list org.gnome.shell disabled-extensions)
	for e in "${uuids[@]}"; do
		[[ " ${off[*]} " == *" $e "* ]] || on+=("$e")
	done
	gs_list_add org.gnome.shell enabled-extensions "${on[@]}"
}

# One-time copy of space-bar's smart-name map, so names learned there carry over. Workspace names
# themselves already live in GNOME's own workspace-names key, which both use.
migrate_space_bar_names() {
	command -v dconf >/dev/null 2>&1 || return 0
	local ours=/org/gnome/shell/extensions/ostrich-os/workspaces/names-map
	local theirs=/org/gnome/shell/extensions/space-bar/state/workspace-names-map
	local current value
	current=$(dconf read "$ours")
	[[ -z $current || $current == "'{}'" ]] || return 0
	value=$(dconf read "$theirs")
	[[ -n $value && $value != "'{}'" ]] || return 0
	changed "copy space-bar workspace name map to the workspaces extension"
	run_cmd dconf write "$ours" "$value"
}

if ((DRY_RUN)); then
	info "dry run: extensions would be built/installed from $DIST"
else
	ensure_built
fi
# One-time copy of Just Perfection's animation speed and startup choice. Its animation setting is
# an index into fixed factors; startup-status 1 means "start in the overview" (GNOME's own key).
migrate_just_perfection() {
	command -v dconf >/dev/null 2>&1 || return 0
	local jp=/org/gnome/shell/extensions/just-perfection ours=/org/gnome/shell/extensions/ostrich-os/tweaks
	local anim status factor
	anim=$(dconf read "$jp/animation")
	if [[ -n $anim && -z $(dconf read "$ours/animation-speed") ]]; then
		local -a factors=(0.01 0.2 0.6 0.8 1.3 1.6 2.8) # Just Perfection's values 2..8
		if ((anim >= 2 && anim - 2 < ${#factors[@]})); then
			factor=${factors[anim - 2]}
			changed "copy Just Perfection animation speed ($factor) to tweaks"
			run_cmd dconf write "$ours/animation-speed" "$factor"
		fi
	fi
	status=$(dconf read "$jp/startup-status")
	# Once: Just Perfection's keys stay after it's off, and an update must not undo your choice.
	if [[ $status == 1 && -z $(dconf read "$ours/migrated-jp") ]]; then
		gs_set org.gnome.shell start-in-overview true
		run_cmd dconf write "$ours/migrated-jp" true
	fi
	return 0
}

# One-time copy of Tiling Assistant's gap, popup and focus-hint choices.
migrate_tiling_assistant() {
	command -v dconf >/dev/null 2>&1 || return 0
	local ta=/org/gnome/shell/extensions/tiling-assistant ours=/org/gnome/shell/extensions/ostrich-os/tiling
	local their our_key v
	[[ -z $(dconf read "$ours/migrated") ]] || return 0
	for their in window-gap:window-gap enable-tiling-popup:fill-popup tiling-popup-all-workspace:fill-popup-all-workspaces focus-hint-color:focus-hint-color; do
		our_key=${their#*:}
		v=$(dconf read "$ta/${their%%:*}")
		[[ -n $v && -z $(dconf read "$ours/$our_key") ]] || continue
		[[ $our_key == window-gap ]] && v="uint32 ${v#uint32 }"
		changed "copy Tiling Assistant ${their%%:*} ($v) to tiling"
		run_cmd dconf write "$ours/$our_key" "$v"
	done
	# Its focus hint is a style number (0 = off); ours is on/off.
	v=$(dconf read "$ta/focus-hint")
	if [[ -n $v && $v != 0 && -z $(dconf read "$ours/focus-hint") ]]; then
		changed "turn on the tiling focus outline (Tiling Assistant had one)"
		run_cmd dconf write "$ours/focus-hint" true
	fi
	run_cmd dconf write "$ours/migrated" true
}

# One-time copy of how the user's Dash to Dock (or Ubuntu Dock) hides, its icon size and, when it
# had its own colour (custom-background-color), that colour and opacity: only what they changed
# from the default (dconf read returns only what was set).
migrate_dash_to_dock() {
	command -v dconf >/dev/null 2>&1 || return 0
	local dd=/org/gnome/shell/extensions/dash-to-dock ours=/org/gnome/shell/extensions/ostrich-os/dock
	local fixed auto intel size
	fixed=$(dconf read "$dd/dock-fixed")
	auto=$(dconf read "$dd/autohide")
	intel=$(dconf read "$dd/intellihide")
	if [[ -n $fixed$auto$intel && -z $(dconf read "$ours/autohide")$(dconf read "$ours/intellihide") ]]; then
		# Unchanged keys count as Dash to Dock's own defaults (not fixed, auto-hide, intelli-hide).
		[[ ${fixed:-false} == true ]] && auto=false intel=false
		[[ ${intel:-true} == true ]] && auto=true
		changed "copy the dock's hiding from Dash to Dock (auto-hide ${auto:-true}, only when a window is in the way ${intel:-true})"
		run_cmd dconf write "$ours/autohide" "${auto:-true}"
		run_cmd dconf write "$ours/intellihide" "${intel:-true}"
	fi
	size=$(dconf read "$dd/dash-max-icon-size")
	if [[ $size =~ ^[0-9]+$ && -z $(dconf read "$ours/icon-size") ]]; then
		((size < 16)) && size=16
		((size > 64)) && size=64
		changed "copy the dock's icon size from Dash to Dock ($size px)"
		run_cmd dconf write "$ours/icon-size" "uint32 $size"
	fi
	local custom colour hex opacity
	custom=$(dconf read "$dd/custom-background-color")
	colour=$(dconf read "$dd/background-color")
	hex=$(css_hex "$colour")
	if [[ $custom == true && -n $hex && -z $(dconf read "$ours/background") ]]; then
		changed "copy the dock's colour from Dash to Dock ($hex)"
		run_cmd dconf write "$ours/background-color" "'$hex'"
		run_cmd dconf write "$ours/background" "'custom'"
		opacity=$(dconf read "$dd/background-opacity")
		if [[ $opacity =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ && -z $(dconf read "$ours/background-opacity") ]]; then
			changed "copy the dock's opacity from Dash to Dock ($opacity)"
			run_cmd dconf write "$ours/background-opacity" "$opacity"
		fi
	fi
	return 0
}

# A CSS colour as Dash to Dock stores it ('#rrggbb', 'rgb(r,g,b)' or 'rgba(r,g,b,a)', quoted as
# dconf prints it) -> #rrggbb, or nothing.
css_hex() {
	local v=${1//\'/} r g b
	v=${v// /}
	if [[ $v =~ ^#[0-9a-fA-F]{6}$ ]]; then
		echo "${v,,}"
	elif [[ $v =~ ^rgba?\(([0-9]{1,3}),([0-9]{1,3}),([0-9]{1,3})(,[0-9.]+)?\)$ ]]; then
		r=${BASH_REMATCH[1]} g=${BASH_REMATCH[2]} b=${BASH_REMATCH[3]}
		((r <= 255 && g <= 255 && b <= 255)) && printf '#%02x%02x%02x\n' "$r" "$g" "$b"
	fi
	return 0
}

# One-time copy of Vitals' readings in the top bar (its hot-sensors, mapped to ours where we have
# the same reading; the rest are left out), where they sit, and how often it updates.
migrate_vitals() {
	command -v dconf >/dev/null 2>&1 || return 0
	local v=/org/gnome/shell/extensions/vitals ours=/org/gnome/shell/extensions/ostrich-os/monitor
	local hot pins position update
	hot=$(dconf read "$v/hot-sensors")
	if [[ -n $hot && -z $(dconf read "$ours/panel-items") ]]; then
		pins=$(vitals_pins "$hot")
		if [[ -n $pins && $pins != "@as []" ]]; then
			changed "copy Vitals' top-bar readings to the monitor ($pins)"
			run_cmd dconf write "$ours/panel-items" "$pins"
		fi
	fi
	position=$(dconf read "$v/position-in-panel")
	if [[ -n $position && -z $(dconf read "$ours/panel-box") ]]; then
		case $position in
		0 | 3) position=left ;;
		1) position=center ;;
		*) position=right ;;
		esac
		changed "copy where Vitals sat in the top bar ($position)"
		run_cmd dconf write "$ours/panel-box" "'$position'"
	fi
	update=$(dconf read "$v/update-time")
	if [[ $update =~ ^[0-9]+$ ]] && ((update >= 1 && update <= 60)) && [[ -z $(dconf read "$ours/interval-ac") ]]; then
		changed "copy Vitals' update interval ($update s)"
		run_cmd dconf write "$ours/interval-ac" "uint32 $update"
	fi
	return 0
}

# Vitals' hot-sensors list (as dconf prints it) -> our panel-items, in its order, as a dconf array.
vitals_pins() {
	python3 -I - "$1" <<'EOF'
import re, sys
names = re.findall(r"'([^']*)'", sys.argv[1])
rules = [  # Vitals' sensor key (a pattern) -> our row id
    (r"_processor_usage_", "cpu.usage"), (r"_processor_frequency_", "cpu.freq"),
    (r"_memory_usage_", "mem.usage"), (r"_memory_allocated_", "mem.used"),
    (r"_memory_available_", "mem.available"), (r"_memory_swap", "mem.swap"),
    (r"temperature", "temp.package"),
    (r"network.*rx", "net.down"), (r"network.*tx", "net.up"),
    (r"_storage_free_", "disk.free"), (r"_storage_used_", "disk.used"),
    (r"_battery_rate_", "bat.rate"), (r"_battery_time", "bat.time"), (r"_battery_(level|percent)", "bat.percent"),
    (r"_system_uptime_", "sys.uptime"), (r"_system_process", "sys.processes"),
]
pins = []
for n in names:
    for pattern, ours in rules:
        if re.search(pattern, n) and ours not in pins:
            pins.append(ours)
            break
print("[" + ", ".join(f"'{p}'" for p in pins) + "]" if pins else "@as []")
EOF
}

# One-time copy of Blur my Shell's strength and brightness for each surface we blur: its own
# per-surface keys (older versions) or the blur effect in the pipeline each surface uses (v60+).
migrate_blur_my_shell() {
	command -v dconf >/dev/null 2>&1 || return 0
	local bms=/org/gnome/shell/extensions/blur-my-shell ours=/org/gnome/shell/extensions/ostrich-os/blur
	local pipelines line surface radius brightness
	[[ -z $(dconf read "$ours/migrated-bms") ]] || return 0
	pipelines=$(dconf read "$bms/pipelines")
	local -a pairs=(panel:panel dash-to-dock:dock appfolder:folders overview:overview)
	for pair in "${pairs[@]}"; do
		surface=${pair#*:}
		line=$(bms_strength "$(dconf read "$bms/${pair%%:*}/pipeline")" "$pipelines" \
			"$(dconf read "$bms/${pair%%:*}/sigma")" "$(dconf read "$bms/${pair%%:*}/brightness")")
		read -r radius brightness <<<"$line"
		if [[ $radius =~ ^[0-9]+$ ]] && [[ -z $(dconf read "$ours/$surface-radius") ]]; then
			((radius < 1)) && radius=1
			((radius > 150)) && radius=150
			changed "copy Blur my Shell's $surface strength ($radius)"
			run_cmd dconf write "$ours/$surface-radius" "uint32 $radius"
		fi
		if [[ $brightness =~ ^[01](\.[0-9]+)?$ ]] && [[ -z $(dconf read "$ours/$surface-brightness") ]]; then
			brightness=$(python3 -I -c "import sys; print(min(1.0, max(0.3, float(sys.argv[1]))))" "$brightness")
			changed "copy Blur my Shell's $surface brightness ($brightness)"
			run_cmd dconf write "$ours/$surface-brightness" "$brightness"
		fi
	done
	[[ -n $pipelines$(dconf read "$bms/panel/sigma") ]] && run_cmd dconf write "$ours/migrated-bms" true
	return 0
}

# "radius brightness" for one Blur my Shell surface: from its pipeline's blur effect when it has one
# (args: pipeline id, the pipelines dict as dconf prints it), else from its sigma and brightness.
bms_strength() {
	python3 -I - "$@" <<'EOF'
import sys
pipeline, pipelines, sigma, brightness = (a.strip("'") for a in sys.argv[1:5])
radius = sigma
try:
    from gi.repository import GLib
    effects = GLib.Variant.parse(None, sys.argv[2], None, None).unpack()[pipeline]["effects"] if pipeline else []
except Exception:  # no pipelines, an unknown pipeline or no PyGObject: the per-surface keys
    effects = []
for e in effects:
    if "blur" in e.get("type", "") and isinstance(e.get("params"), dict):
        radius = e["params"].get("radius", e["params"].get("sigma", radius))
        brightness = e["params"].get("brightness", brightness)
        break
try:
    radius = str(round(float(radius)))
except (TypeError, ValueError):
    radius = "-"
print(radius, brightness if brightness not in ("", None) else "-")
EOF
}

# A colour scheme's stylesheets replace the extensions' own: rewrite them from this version's
# templates, or rules added since the scheme was applied never show (owner, 2026-11-25: notifications
# in the clock menu stayed grey).
refresh_scheme() {
	local theme=${LIBEXEC_DIR:-$HOME/.local/libexec/ostrich-os}/ostrich-theme
	[[ -x $theme ]] || return 0
	if ((DRY_RUN)); then
		"$theme" scheme refresh --dry-run || true
	else
		"$theme" scheme refresh || warn "colour scheme not refreshed; apply it again in Ostrich Settings"
	fi
}

install_extensions
refresh_scheme
migrate_dash_to_dock
migrate_vitals
migrate_blur_my_shell
migrate_space_bar_names
migrate_just_perfection
migrate_tiling_assistant

if [[ $(gsettings get org.gnome.shell disable-user-extensions) == true ]]; then
	warn "GNOME has disabled all user extensions (usually after an extension crashed). Turn them back on in Extensions, or run: gsettings set org.gnome.shell disable-user-extensions false"
fi

# Notification banners on by default; only Do Not Disturb and focus mode hide them.
gs_set org.gnome.desktop.notifications show-banners true

module_done
