#!/usr/bin/env bash
# tests/vm/critique.sh: the critique inbox. In the VM, Super+Alt+C freezes the screen; box what's
# wrong and type a note (tests/vm/critique/). Notes land straight in the host folder
# $VM_DIR/critiques (the VM mounts it at ~/critiques), one folder each:
#   screen.png (boxes drawn on it), crop-N.png, note.json (text, what was boxed, its settings,
#   versions), errors.txt (the last two minutes of warnings); status.json once handled.
#
#   critique.sh ensure SNAPSHOT     install the tool into SNAPSHOT if it's missing or changed
#                                   (vm.sh view runs this)
#   critique.sh install SNAPSHOT    install it anyway
#   critique.sh list [--all]        open notes (--all: done ones too)
#   critique.sh show ID             a note's text, element, kind and files
#   critique.sh done ID COMMIT [AFTER.png] [WORDS]   mark handled, with the fix and an after shot
#   critique.sh ask ID QUESTION     mark "need more info", with the question for the user
#   critique.sh selftest            a critique driven end to end in the VM (stock + the tool)
#
# A test tool only: it is never part of Ubuntu Ostrich or installed on a real machine.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
PROJECT="ubuntu-ostrich"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
INBOX="$VM_DIR/critiques"
SRC="$HERE/critique"
UUID="critique@ubuntu-ostrich-dev"

die() {
	echo "critique: $*" >&2
	exit 1
}
log() { echo "[critique] $*" >&2; }

# A fingerprint of the tool's files: a snapshot is re-done when the tool changes.
fingerprint() { (cd "$SRC" && find . -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum | cut -c1-16; }
marker() { echo "$VM_DIR/critique-in-$1"; }
# When the snapshot was saved: a snapshot rebuilt since the tool went in (e2e.sh ... try-me) has
# lost it, so the marker records both.
saved_at() { "$VM" snapshot list 2>/dev/null | awk -v s="$1" '$2 == s { print $5 "T" $6 }'; }
stamp() { echo "$(fingerprint) $(saved_at "$1")"; }

pack() {
	local out
	out=$(mktemp -d)
	(cd "$SRC" && gnome-extensions pack --force --out-dir="$out" --extra-source=pick.js \
		--schema="$(ls schemas/*.gschema.xml)" .) >/dev/null
	echo "$out/$UUID.shell-extension.zip"
}

cmd_install() {
	local snap=${1:?usage: critique.sh install SNAPSHOT}
	local zip
	zip=$(pack)
	mkdir -p "$INBOX"
	"$VM" stop
	"$VM" snapshot restore "$snap"
	"$VM" start
	"$VM" copy "$zip" /tmp/critique.zip
	# shellcheck disable=SC2016 # expands in the VM
	"$VM" ssh 'export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
		gnome-extensions install --force /tmp/critique.zip
		python3 - <<EOF
import ast, subprocess
get = lambda k: ast.literal_eval(subprocess.check_output(["gsettings", "get", "org.gnome.shell", k], text=True).replace("@as ", ""))
on = [u for u in get("enabled-extensions") if u != "'"$UUID"'"] + ["'"$UUID"'"]
subprocess.check_call(["gsettings", "set", "org.gnome.shell", "enabled-extensions", str(on)])
off = [u for u in get("disabled-extensions") if u != "'"$UUID"'"]
subprocess.check_call(["gsettings", "set", "org.gnome.shell", "disabled-extensions", str(off)])
EOF
		mkdir -p ~/critiques
		grep -q "^critiques " /etc/fstab || echo "critiques $HOME/critiques 9p trans=virtio,version=9p2000.L,msize=262144,nofail,x-systemd.automount 0 0" | sudo tee -a /etc/fstab >/dev/null
		sudo systemctl daemon-reload'
	sleep 30 # past the start-up window in which a power-off can make GNOME switch extensions off
	"$VM" stop
	"$VM" snapshot save "$snap"
	stamp "$snap" >"$(marker "$snap")"
	rm -rf "$(dirname "$zip")"
	log "installed in snapshot $snap: Super+Alt+C in the VM; notes go to $INBOX"
}

cmd_ensure() {
	local snap=${1:?usage: critique.sh ensure SNAPSHOT}
	[[ -f $(marker "$snap") && $(cat "$(marker "$snap")") == "$(stamp "$snap")" ]] && return 0
	log "putting the critique tool (Super+Alt+C) into snapshot $snap, once (about two minutes)"
	cmd_install "$snap"
}

# Notes as "id<TAB>status<TAB>kind<TAB>element<TAB>first line".
rows() {
	local all=$1 d
	for d in "$INBOX"/*/; do
		[[ -f $d/note.json ]] || continue
		python3 -I - "$d" "$all" <<'EOF'
import json, os, sys
d, show_all = sys.argv[1], sys.argv[2] == "1"
note = json.load(open(os.path.join(d, "note.json")))
st = {}
if os.path.exists(os.path.join(d, "status.json")):
    st = json.load(open(os.path.join(d, "status.json")))
status = st.get("status", "open")
if status == "done" and not show_all:
    sys.exit(0)
elements = "; ".join(b.get("label", "?") for b in note.get("boxes", [])) or note.get("pointer", {}).get("label", "")
first = (note.get("text") or "").splitlines()[0] if note.get("text") else "(no text)"
print("\t".join([note["id"], status, note.get("kind", ""), elements, first]))
EOF
	done
}

cmd_list() {
	local all=0
	[[ ${1:-} == --all ]] && all=1
	local out
	out=$(rows "$all")
	if [[ -z $out ]]; then
		echo "No open critiques in $INBOX. In the VM: Super+Alt+C."
		return 0
	fi
	printf '%s\n' "$out" | awk -F'\t' '{printf "%-34s %-9s %-11s %s\n    %s\n", $1, $2, $3, $4, $5}'
}

note_dir() {
	local id=${1:?which note?}
	[[ $id =~ ^[A-Za-z0-9._-]+$ && -f $INBOX/$id/note.json ]] || die "no note $id in $INBOX"
	echo "$INBOX/$id"
}

cmd_show() {
	local d
	d=$(note_dir "${1:-}")
	python3 -I - "$d" <<'EOF'
import json, os, sys
d = sys.argv[1]
n = json.load(open(os.path.join(d, "note.json")))
print(f"{n['id']}  ({n.get('kind')}, {n.get('time')})")
print(n.get("text") or "(no text)")
for i, b in enumerate(n.get("boxes", []), 1):
    print(f"  box {i}: {b.get('label')}  owner {b.get('owner')}  at {b.get('x')},{b.get('y')} {b.get('width')}x{b.get('height')}")
print(f"  pointer: {n.get('pointer', {}).get('label')}")
print(f"  versions: {n.get('versions', {}).get('ostrich')} (VERSION {n.get('versions', {}).get('version')}), GNOME Shell {n.get('versions', {}).get('shell')}")
print("  files: " + ", ".join(sorted(os.listdir(d))))
if os.path.exists(os.path.join(d, "status.json")):
    print("  status: " + open(os.path.join(d, "status.json")).read().strip())
EOF
}

write_status() { # dir json
	printf '%s\n' "$2" >"$1/status.json"
}

cmd_done() {
	local d commit=${2:?usage: critique.sh done ID COMMIT [AFTER.png] [WORDS]} after=${3:-} words=${4:-}
	d=$(note_dir "${1:-}")
	if [[ -n $after ]]; then
		[[ -f $after ]] || die "no file $after"
		cp "$after" "$d/after.png"
	fi
	write_status "$d" "$(python3 -I -c 'import json,sys; print(json.dumps({"status": "done", "commit": sys.argv[1], "after": sys.argv[2] or None, "note": sys.argv[3] or None}))' "$commit" "${after:+after.png}" "$words")"
	log "$(basename "$d"): done ($commit)"
}

cmd_ask() {
	local d question=${2:?usage: critique.sh ask ID QUESTION}
	d=$(note_dir "${1:-}")
	write_status "$d" "$(python3 -I -c 'import json,sys; print(json.dumps({"status": "need-info", "question": sys.argv[1]}))' "$question")"
	log "$(basename "$d"): asked"
}

# Drives a critique: a box over the dock, a note typed, saved; checks what landed in the inbox.
cmd_selftest() {
	local snap=critique-selftest before after
	"$VM" stop
	"$VM" snapshot restore "${SELFTEST_FROM:-post-fresh}"
	"$VM" snapshot save "$snap"
	cmd_install "$snap"
	"$VM" snapshot restore "$snap"
	"$VM" start
	sleep 30
	before=$(find "$INBOX" -mindepth 1 -maxdepth 1 -type d | wc -l)
	local shots="$VM_DIR/critique-selftest"
	rm -rf "$shots" && mkdir -p "$shots"
	"$VM" move 960 1078
	"$VM" nudge 0 20 30 # show the dock
	sleep 1
	"$VM" screenshot "$shots/1-dock.png" >/dev/null
	"$VM" key meta_l-alt-c
	sleep 3
	"$VM" screenshot "$shots/2-frozen.png" >/dev/null
	"$VM" drag 700 1010 1220 1076
	sleep 1
	"$VM" screenshot "$shots/3-boxed.png" >/dev/null
	"$VM" key d o c k
	"$VM" key minus
	"$VM" key s e l f t e s t
	"$VM" screenshot "$shots/4-typed.png" >/dev/null
	"$VM" key ret
	sleep 5
	after=$(find "$INBOX" -mindepth 1 -maxdepth 1 -type d | wc -l)
	"$VM" stop
	"$VM" snapshot delete "$snap" >/dev/null 2>&1 || true
	((after > before)) || die "selftest: no note arrived in $INBOX (screenshots of each step: $shots)"
	local d
	d=$(find "$INBOX" -mindepth 1 -maxdepth 1 -type d -name '*dock-selftest*' | sort | tail -1)
	[[ -n $d ]] || die "selftest: the note has the wrong name"
	for f in screen.png crop-1.png note.json errors.txt; do
		[[ -s $d/$f ]] || die "selftest: $f missing"
	done
	python3 -I - "$d/note.json" <<'EOF' || die "selftest: note.json is missing facts"
import json, sys
n = json.load(open(sys.argv[1]))
assert n["text"] == "dock-selftest", n["text"]
assert any(b.get("owner") == "dock@ubuntu-ostrich" for b in n["boxes"]), [b.get("label") for b in n["boxes"]]
assert "dock@ubuntu-ostrich" in n["settings"] and "icon-size" in n["settings"]["dock@ubuntu-ostrich"]
assert n["versions"]["shell"].startswith("50")
print("  ok: " + "; ".join(b["label"] for b in n["boxes"]))
EOF
	cmd_done "$(basename "$d")" selftest
	rm -rf "$d"
	log "selftest passed"
}

case ${1:-} in
ensure | install | list | show | done | ask | selftest)
	cmd=$1
	shift
	"cmd_$cmd" "$@"
	;;
*)
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
	;;
esac
