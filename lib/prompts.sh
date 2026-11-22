#!/usr/bin/env bash
# lib/prompts.sh: whiptail prompts, used only when there is no GUI session (the welcome wizard handles choices otherwise).

has_gui_session() { [[ -n ${WAYLAND_DISPLAY:-} || -n ${DISPLAY:-} ]]; }

# ask_yes_no <question> <default yes|no>: returns 0 for yes. Non-interactive runs get the default.
ask_yes_no() {
	local question=$1 default=${2:-no}
	if [[ ! -t 0 ]] || ! command -v whiptail >/dev/null 2>&1; then
		[[ $default == yes ]]
		return
	fi
	local -a flags=()
	[[ $default == no ]] && flags+=(--defaultno)
	whiptail --title "Ostrich OS" "${flags[@]}" --yesno "$question" 10 70
}
