#!/usr/bin/env bash
# lib/logging.sh: logging and the dry-run-aware `run_cmd` wrapper. Source, don't execute.
#
# Callers set (or inherit) DRY_RUN=0|1 and LOG_FILE; log_init creates the log file.

DRY_RUN="${DRY_RUN:-0}"

log_init() {
	mkdir -p "$(dirname "$LOG_FILE")"
	touch "$LOG_FILE"
	LOG_READY=1
}

log() {
	local level=$1
	shift
	local line
	line="$(date '+%Y-%m-%dT%H:%M:%S%z') [$level] $*"
	printf '%s\n' "$line" >&2
	if [[ -n ${LOG_READY:-} ]]; then
		printf '%s\n' "$line" >>"$LOG_FILE"
	fi
}

info() { log INFO "$@"; }
warn() { log WARN "$@"; }

die() {
	log ERROR "$@"
	exit 1
}

# Records that something changed (or would change, in a dry run).
changed() {
	if ((DRY_RUN)); then
		log WOULD "$@"
	else
		log CHANGE "$@"
	fi
}

# run_cmd <cmd> [args...]: run a state-changing command, or only log it in a dry run.
run_cmd() {
	if ((DRY_RUN)); then
		log WOULD "run: $(printf '%q ' "$@")"
		return 0
	fi
	log RUN "$(printf '%q ' "$@")"
	"$@"
}
