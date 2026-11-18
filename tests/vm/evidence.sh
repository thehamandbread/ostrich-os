#!/usr/bin/env bash
# tests/vm/evidence.sh: the design council's evidence pack (docs/council/PROTOCOL.md). Everything the
# council's seats argue from: measurements, screenshots of the desktop next to the original setup's,
# our apps, and the owner's critique notes, with index.md listing each file with a caption.
#
#   evidence.sh OUTDIR [--ours SNAPSHOT] [--pre SNAPSHOT] [--runs N]
#                      (defaults: ours = post-fresh, pre = pre, 2 baseline runs each)
#
# Uses the test VM throughout (about 90 minutes); nothing else may use it meanwhile. A step that
# fails is recorded in index.md and the rest go on.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VM="$HERE/vm.sh"
PROJECT="ubuntu-ostrich"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
OURS=post-fresh
PRE=pre
RUNS=2
OUT=${1:-}
[[ -n $OUT && $OUT != -* ]] || {
	echo "usage: evidence.sh OUTDIR [--ours SNAPSHOT] [--pre SNAPSHOT] [--runs N]" >&2
	exit 2
}
shift
while (($# > 0)); do
	case $1 in
	--ours) OURS=$2 && shift ;;
	--pre) PRE=$2 && shift ;;
	--runs) RUNS=$2 && shift ;;
	*)
		echo "evidence: unknown option $1" >&2
		exit 2
		;;
	esac
	shift
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
STATUS="$OUT/.status"
: >"$STATUS"
log() { printf '[evidence] %s\n' "$*" >&2; }
# step NAME COMMAND...: runs a step, records whether it worked, keeps its output.
step() {
	local name=$1
	shift
	log "$name"
	if "$@" >"$OUT/$name.log" 2>&1; then
		echo "$name ok" >>"$STATUS"
	else
		echo "$name FAILED (see $name.log)" >>"$STATUS"
		log "$name failed; going on"
	fi
	"$VM" stop >/dev/null 2>&1 || true
}
# shellcheck disable=SC2016 # expands in the VM
SESSION='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0;'
run() { "$VM" ssh "$SESSION $*"; }

# ---- measurements ----

# A measurement only counts with the extensions running: GNOME sometimes switches user extensions
# off for a boot (docs/DECISIONS.md), and then the numbers measure a bare desktop.
all_active() { # label
	local f
	for f in "$VM_DIR/results/$1".run*; do
		[[ $(sed -n 's/^extensions_active=//p' "$f") == "$(sed -n 's/^extensions_enabled=//p' "$f")" ]] || return 1
	done
}

baseline() {
	local label
	for label in "$PRE" "$OURS"; do
		"$HERE/baseline.sh" run "$label" "$RUNS" || return 1
		if ! all_active "$label"; then
			log "$label: extensions weren't all active while measuring; measuring again"
			"$HERE/baseline.sh" run "$label" "$RUNS" || return 1
			all_active "$label" || echo "$label: extensions not all active in the measurement (see results)" >>"$OUT/warnings.txt"
		fi
	done
	"$HERE/baseline.sh" report "$PRE" "$OURS" >"$OUT/baseline.md"
}

bench() {
	local snap
	for snap in "$PRE" "$OURS"; do
		"$VM" stop
		"$VM" snapshot restore "$snap"
		"$VM" start
		sleep 60 # past login and the first-boot work
		run "pkill -x ostrich-setup; true"
		{
			echo "## $snap"
			echo "extensions active: $(run "gnome-extensions list --enabled --details | grep -c 'State: ACTIVE'") of $(run "gnome-extensions list --enabled | wc -l")"
			"$HERE/shell-bench.sh" idle 30 3
			"$HERE/shell-bench.sh" overview 30 3
		} >>"$OUT/bench.txt"
		"$VM" stop
	done
}

# ---- screenshots ----

compare_all() {
	"$HERE/compare.sh" --originals "$PRE" --ours "$OURS" --out "$OUT/compare-light" &&
		"$HERE/compare.sh" --originals "$PRE" --ours "$OURS" --out "$OUT/compare-dark" --dark &&
		"$HERE/compare.sh" --originals "$PRE" --ours "$OURS" --out "$OUT/compare-glass" --dark \
			--wallpaper /usr/share/backgrounds/mendhak-Red_Acer.jpg
}

store() { "$HERE/store-test.sh" --snapshot "$OURS" --out "$OUT/store"; }

# Every page of Ostrich Settings, as settings (not the tour).
settings_pages() {
	local ids page
	ids=$(sed -n 's/^ *Step::[A-Za-z]* => "\([a-z-]*\)",$/\1/p' "$ROOT/tools/welcome/src/lib.rs" | awk '!seen[$0]++' | head -15)
	mkdir -p "$OUT/settings"
	"$VM" stop
	"$VM" snapshot restore "$OURS"
	"$VM" start
	sleep 40
	run "pkill -x ostrich-setup; true"
	for page in $ids; do
		[[ $page == finish ]] && continue
		run "setsid -f ~/.local/libexec/ubuntu-ostrich/ostrich-setup --step $page </dev/null >/dev/null 2>&1"
		sleep 4
		"$VM" screenshot "$OUT/settings/$page.png" >/dev/null
		run "pkill -x ostrich-setup; true"
		sleep 1
	done
	"$VM" stop
}

# The shell's warnings on a normal session, and the extensions' states.
journal() {
	"$VM" stop
	"$VM" snapshot restore "$OURS"
	"$VM" start
	sleep 60
	run "gnome-extensions list --enabled --details | grep -E '^[a-z].*@|State:'" >"$OUT/extensions.txt"
	run "journalctl --user -b -o cat /usr/bin/gnome-shell | grep -Ei 'warn|error|critical' | sort | uniq -c | sort -rn | head -40" >"$OUT/journal.txt"
	"$VM" stop
}

# ---- the owner's notes ----

critiques() {
	local d dest
	mkdir -p "$OUT/critiques"
	for d in "$VM_DIR"/critiques/*/; do
		[[ -f $d/note.json ]] || continue
		dest="$OUT/critiques/$(basename "$d")"
		mkdir -p "$dest"
		cp "$d"/note.json "$d"/crop-*.png "$dest"/ 2>/dev/null
		for f in status.json after.png errors.txt; do
			[[ -f $d/$f ]] && cp "$d/$f" "$dest/"
		done
	done
	true
}

step baseline baseline
step bench bench
step compare compare_all
step store store
step settings settings_pages
step journal journal
step critiques critiques

# ---- index.md ----

python3 -I - "$OUT" "$ROOT" "$PRE" "$OURS" <<'EOF'
import json, os, sys
out, root, pre, ours = sys.argv[1:5]
L = []
w = L.append
w("# Evidence pack\n")
w(f"Built {os.popen('date -u +%Y-%m-%dT%H:%MZ').read().strip()} from the test VM: `{pre}` is the replica of the owner's "
  f"original setup (their extensions: Blur my Shell, Vitals, Space Bar, Dash to Dock...), `{ours}` is a fresh "
  f"Ubuntu Ostrich install (commit {os.popen(f'git -C {root!r} rev-parse --short HEAD').read().strip()}). "
  "The VM renders with llvmpipe (software), so compositing cost shows up as gnome-shell CPU; "
  "watts can't be measured here.\n")
w("## Steps\n")
for line in open(os.path.join(out, ".status")):
    w(f"- {line.strip()}")
w("")
p = os.path.join(out, "warnings.txt")
if os.path.exists(p):
    w("**Warnings (treat the affected numbers with care):**\n")
    for line in open(p):
        w(f"- {line.strip()}")
    w("")
def section(title, text):
    w(f"## {title}\n")
    w(text.rstrip() + "\n")
p = os.path.join(out, "baseline.md")
if os.path.exists(p):
    section(f"Idle cost: {pre} (original) vs {ours} (ours)",
            "Medians of the baseline runs (tests/vm/measure.sh): gnome-shell CPU and memory, wakeups, "
            "services, boot time.\n\n" + open(p).read())
p = os.path.join(out, "bench.txt")
if os.path.exists(p):
    section("gnome-shell CPU under a workload", "tests/vm/shell-bench.sh: idle, and the overview opened "
            "and closed every 1.5 s.\n\n```\n" + open(p).read() + "```")
scenes = {"1-desktop": "the desktop with a Files window, named workspaces",
          "2-dock": "the dock shown", "3-menu": "quick settings over the desktop",
          "4-overview": "the overview", "5-monitor": "the system monitor's popup (Vitals on the original)",
          "6-clock": "the clock menu", "7-notification": "a notification banner"}
for kind, desc in [("compare-light", "default light style"), ("compare-dark", "dark style"),
                   ("compare-glass", "dark style over a busy photo, to judge the glass")]:
    d = os.path.join(out, kind)
    if not os.path.isdir(d):
        continue
    items = [f"- `{kind}/side-{k}.png`: {v} (original left, ours right)" for k, v in scenes.items()
             if os.path.exists(os.path.join(d, f"side-{k}.png"))]
    section(f"Side by side: {desc}", "\n".join(items) + f"\n\nSingle shots: `{kind}/originals/` and `{kind}/ours/`.")
d = os.path.join(out, "store")
if os.path.isdir(d):
    section("Ostrich Store", "- `store/1-explore.png`: the Explore page\n- `store/2-search.png`: a search\n"
            "- `store/3-app.png`: an app page")
d = os.path.join(out, "settings")
if os.path.isdir(d):
    section("Ostrich Settings, page by page", "\n".join(f"- `settings/{f}`" for f in sorted(os.listdir(d))))
for name, title in [("extensions.txt", "Extensions and their states"), ("journal.txt", "gnome-shell warnings in a normal session (count, message)")]:
    p = os.path.join(out, name)
    if os.path.exists(p):
        section(title, "```\n" + open(p).read()[:6000] + "\n```")
d = os.path.join(out, "critiques")
if os.path.isdir(d):
    rows = []
    for nid in sorted(os.listdir(d)):
        try:
            n = json.load(open(os.path.join(d, nid, "note.json")))
        except Exception:
            continue
        st = {}
        sp = os.path.join(d, nid, "status.json")
        if os.path.exists(sp):
            st = json.load(open(sp))
        label = "; ".join(b.get("label", "") for b in n.get("boxes", []))
        status = st.get("status", "open")
        after = " (after: `after.png`)" if os.path.exists(os.path.join(d, nid, "after.png")) else ""
        rows.append(f"- **{status}** `critiques/{nid}/` [{n.get('kind')}] {label}: \"{n.get('text','')}\"{after}"
                    + (f"\n  - fixed: {st['note']}" if st.get("note") else ""))
    section("The owner's critique notes (from the VM, Super+Alt+C)",
            "Each folder: `note.json` (the words, what was boxed, settings, versions), `crop-1.png` (what was boxed), "
            "and for handled ones `after.png` and `status.json`.\n\n" + "\n".join(rows))
section("Documents", "\n".join(f"- `{p}`" for p in ["docs/DESIGN.md", "docs/DECISIONS.md", "docs/PARITY.md",
        "docs/DEFAULTS.md", "docs/BASELINE.md", "docs/INVENTORY.md", "docs/council/PERSONAS.md", "CLAUDE.md"]))
open(os.path.join(out, "index.md"), "w").write("\n".join(L))
print(os.path.join(out, "index.md"))
EOF
log "done: $OUT/index.md"
