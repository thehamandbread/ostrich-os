#!/usr/bin/env bash
# lib/gsettings.sh: idempotent gsettings helpers that log what they change. Source after logging.sh.

# gs_set <schema> <key> <value>: set only when different (value in GVariant text form, e.g. true, 'x').
gs_set() {
	local schema=$1 key=$2 value=$3 current
	current=$(gsettings get "$schema" "$key" 2>/dev/null) || die "gsettings: no key $schema $key"
	[[ $current == "$value" ]] && return 0
	changed "gsettings $schema $key: $current -> $value"
	run_cmd gsettings set "$schema" "$key" "$value"
}

# Prints the items of a string-array setting, one per line ("@as []" and "[]" both empty).
gs_list() {
	gsettings get "$1" "$2" | sed -e 's/^@as //' -e 's/^\[//' -e 's/\]$//' | tr ',' '\n' |
		sed -e "s/^ *'//" -e "s/' *$//" | grep -v '^$' || true
}

# gs_list_add <schema> <key> <item>...: append missing items in one write.
gs_list_add() {
	local schema=$1 key=$2
	shift 2
	local -a items missing=()
	mapfile -t items < <(gs_list "$schema" "$key")
	local i
	for i in "$@"; do
		printf '%s\n' "${items[@]}" "${missing[@]}" | grep -qxF "$i" || missing+=("$i") # a uuid passed twice goes in once
	done
	((${#missing[@]} > 0)) || return 0
	local all=("${items[@]}" "${missing[@]}") out="" x
	for x in "${all[@]}"; do out+="${out:+, }'$x'"; done
	changed "gsettings $schema $key: add ${missing[*]}"
	run_cmd gsettings set "$schema" "$key" "[$out]"
}

# gs_list_remove <schema> <key> <item>...: drop items that are present, in one write.
gs_list_remove() {
	local schema=$1 key=$2
	shift 2
	local -a items kept=() removed=()
	mapfile -t items < <(gs_list "$schema" "$key")
	local x r drop
	for x in "${items[@]}"; do
		drop=0
		for r in "$@"; do [[ $x == "$r" ]] && drop=1; done
		if ((drop)); then removed+=("$x"); else kept+=("$x"); fi
	done
	((${#removed[@]} > 0)) || return 0
	local out=""
	for x in "${kept[@]}"; do out+="${out:+, }'$x'"; done
	changed "gsettings $schema $key: remove ${removed[*]}"
	run_cmd gsettings set "$schema" "$key" "[$out]"
}
