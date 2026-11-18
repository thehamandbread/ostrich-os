#!/usr/bin/env bash
# tests/vm/journal-gate.sh: sourced by the VM suites. journal_gate fails the suite on any warning or
# error in this boot's gnome-shell journal that comes from our code (docs/FEATURES.md EXT-3).
#
#   source "$HERE/journal-gate.sh"; journal_gate     (needs the suite's $VM, `ok` and `bad`)
#
# "Ours": a warning our code raised. That is a message naming one of our extensions or widgets
# (ost-…, Gjs_<ext>_ubuntu-ostrich) or starting with one of our log prefixes ("monitor: …"), or a
# stack trace whose top frame (#0) is in our code. A trace that only passes through our code (GNOME
# 50's app grid destroying a folder twice after focus's app filter changes) is GNOME's own. JS ERRORs
# count wherever they come from. Each suite starts a fresh boot, so the whole boot is checked.

# Our console.warn prefixes, one per module.
JOURNAL_PREFIXES='monitor|blur|dock|drawer|focus|environments|tweaks|now playing|mpris|tiling|tray|workspaces|holder-monitor|search-new-window'

journal_ours() {
	"$VM" ssh "journalctl --user -b -o cat /usr/bin/gnome-shell" 2>/dev/null |
		grep -E "JS ERROR|^#0 .*(ubuntu-ostrich|ubuntu_ostrich)|^[^#].*(ubuntu-ostrich|ubuntu_ostrich)|\\bost-[a-z]|non-existent keybinding|^($JOURNAL_PREFIXES): " || true
}

journal_gate() {
	local lines
	lines=$(journal_ours)
	if [[ -z $lines ]]; then
		ok "no warnings from our code in the shell journal"
	else
		bad "warnings from our code in the shell journal ($(wc -l <<<"$lines") lines):"
		sort <<<"$lines" | uniq -c | sort -rn | head -8 | sed 's/^/      /'
	fi
}
