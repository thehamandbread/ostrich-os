#!/usr/bin/env bats
# tests/lib.bats: tests for lib/ helpers, using fixture sysfs/udev trees.

setup() {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	LIB="$BATS_TEST_DIRNAME/../lib"
	export LOG_FILE="$BATS_TEST_TMPDIR/state/install.log"
	export BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
	export SYSFS_ROOT="$BATS_TEST_TMPDIR/sys"
	export UDEV_DATA="$BATS_TEST_TMPDIR/udev"
	export DRY_RUN=0
	mkdir -p "$SYSFS_ROOT" "$UDEV_DATA"
	# shellcheck source=/dev/null
	source "$LIB/logging.sh"
	source "$LIB/backup.sh"
	source "$LIB/detect.sh"
	log_init
}

pci() { # pci <name> <class> <vendor>
	mkdir -p "$SYSFS_ROOT/bus/pci/devices/$1"
	echo "$2" >"$SYSFS_ROOT/bus/pci/devices/$1/class"
	echo "$3" >"$SYSFS_ROOT/bus/pci/devices/$1/vendor"
}

@test "run_cmd executes and logs the command" {
	run run_cmd touch "$BATS_TEST_TMPDIR/made"
	[ "$status" -eq 0 ]
	[ -f "$BATS_TEST_TMPDIR/made" ]
	grep -q '\[RUN\] touch' "$LOG_FILE"
}

@test "run_cmd in dry-run only logs" {
	DRY_RUN=1
	run run_cmd touch "$BATS_TEST_TMPDIR/made"
	[ "$status" -eq 0 ]
	[ ! -e "$BATS_TEST_TMPDIR/made" ]
	[[ $output == *"[WOULD] run: touch"* ]]
}

@test "install_file installs, then is a no-op when identical" {
	echo one >"$BATS_TEST_TMPDIR/src"
	install_file "$BATS_TEST_TMPDIR/src" "$BATS_TEST_TMPDIR/out/dest"
	[ "$(cat "$BATS_TEST_TMPDIR/out/dest")" = one ]
	run install_file "$BATS_TEST_TMPDIR/src" "$BATS_TEST_TMPDIR/out/dest"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "install_file backs up a different existing file before replacing it" {
	echo new >"$BATS_TEST_TMPDIR/src"
	echo old >"$BATS_TEST_TMPDIR/dest"
	install_file "$BATS_TEST_TMPDIR/src" "$BATS_TEST_TMPDIR/dest"
	[ "$(cat "$BATS_TEST_TMPDIR/dest")" = new ]
	[ "$(cat "$BACKUP_DIR$BATS_TEST_TMPDIR/dest")" = old ]
}

@test "install_file in dry-run changes nothing" {
	DRY_RUN=1
	echo new >"$BATS_TEST_TMPDIR/src"
	echo old >"$BATS_TEST_TMPDIR/dest"
	run install_file "$BATS_TEST_TMPDIR/src" "$BATS_TEST_TMPDIR/dest"
	[ "$status" -eq 0 ]
	[ "$(cat "$BATS_TEST_TMPDIR/dest")" = old ]
	[ ! -e "$BACKUP_DIR" ]
	[[ $output == *"[WOULD] install"* ]]
}

@test "hybrid graphics: intel + nvidia" {
	pci 0000:00:02.0 0x030000 0x8086
	pci 0000:01:00.0 0x030200 0x10de
	is_hybrid_graphics
}

@test "nvidia-only desktop is not hybrid" {
	pci 0000:01:00.0 0x030000 0x10de
	pci 0000:00:1f.3 0x040380 0x8086 # Intel audio, not a display device
	! is_hybrid_graphics
}

@test "dell detection" {
	mkdir -p "$SYSFS_ROOT/class/dmi/id"
	echo "Dell Inc." >"$SYSFS_ROOT/class/dmi/id/sys_vendor"
	is_dell
}

@test "non-dell desktop" {
	mkdir -p "$SYSFS_ROOT/class/dmi/id"
	echo "LENOVO" >"$SYSFS_ROOT/class/dmi/id/sys_vendor"
	! is_dell
}

@test "touchscreen detection reads udev properties" {
	! has_touchscreen
	printf 'E:ID_INPUT=1\nE:ID_INPUT_TOUCHPAD=1\n' >"$UDEV_DATA/c13:65"
	! has_touchscreen
	printf 'E:ID_INPUT=1\nE:ID_INPUT_TOUCHSCREEN=1\n' >"$UDEV_DATA/c13:67"
	has_touchscreen
}

@test "os_id_version does not leak variables" {
	export OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os-release"
	printf 'ID=ubuntu\nVERSION_ID="26.04"\nDRY_RUN=1\n' >"$OS_RELEASE_FILE"
	[ "$(os_id_version)" = "ubuntu 26.04" ]
	[ "$DRY_RUN" = 0 ]
}

# DESIGN.md: event-driven, nothing polls without a visible reason. A timer that repeats (its
# callback returns SOURCE_CONTINUE) says why in a "// why:" comment just above it.
@test "every repeating timer in our extensions says why" {
	run python3 -I - "$BATS_TEST_DIRNAME/../modules/gnome/extensions" <<'PY'
import pathlib, re, sys
bad = []
for f in sorted(pathlib.Path(sys.argv[1]).glob("*/*.js")):
    lines = f.read_text().splitlines()
    for i, line in enumerate(lines):
        if not re.search(r"\btimeout_add(_seconds)?\(", line):
            continue
        body, depth = [], 0
        for l in lines[i:]:
            body.append(l)
            depth += l.count("{") - l.count("}")
            if depth <= 0 and len(body) > 1:
                break
        if "SOURCE_CONTINUE" in "\n".join(body) and not any("// why:" in l for l in lines[max(0, i - 4):i]):
            bad.append(f"{f.parent.name}/{f.name}:{i + 1}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
	echo "$output"
	[ "$status" -eq 0 ]
}

# A screen reader can only name a button that has a name: every icon-only St.Button in our
# extensions sets accessible_name (or has a text label).
@test "every icon-only button in our extensions has a name" {
	run python3 -I - "$BATS_TEST_DIRNAME/../modules/gnome/extensions" <<'PY'
import pathlib, re, sys
bad = []
for f in sorted(pathlib.Path(sys.argv[1]).glob("*/*.js")):
    s = f.read_text()
    for m in re.finditer(r"new St\.Button\(\{", s):
        depth, j = 0, m.end() - 1
        while depth or j == m.end() - 1:
            depth += (s[j] == "{") - (s[j] == "}")
            j += 1
        block = s[m.start():j]
        if ("St.Icon" in block or "icon_name" in block) and not ("accessible_name" in block or "label:" in block):
            bad.append(f"{f.parent.name}/{f.name}:{s[:m.start()].count(chr(10)) + 1}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
	echo "$output"
	[ "$status" -eq 0 ]
}

# The system helper's polkit policy: well-formed, one action per command, and only power and the
# touchscreen promptless (DESIGN.md, Safety); a GitHub app's sandbox profile asks.
@test "polkit policy: graphics and apparmor ask, power and touchscreen don't" {
	run python3 -I - "$BATS_TEST_DIRNAME/../modules/hardware/org.ostrich-os.system-helper.policy" <<'PY'
import sys, xml.etree.ElementTree as ET
actions = {}
for a in ET.parse(sys.argv[1]).getroot().iter("action"):
    argv1 = [x.text for x in a.iter("annotate") if x.get("key") == "org.freedesktop.policykit.exec.argv1"]
    actions[argv1[0] if argv1 else None] = a.find("defaults/allow_active").text
print(actions)
assert actions == {"power": "yes", "touchscreen": "yes", "graphics": "auth_admin_keep", "apparmor": "auth_admin_keep"}, actions
PY
	echo "$output"
	[ "$status" -eq 0 ]
}

# Every setting is reachable: a control in Ostrich Settings, or a line in DEFAULTS.md's
# "Only in `ostrich config`" table (blur's per-surface radius and brightness come from a prefix).
@test "every extension setting is in Ostrich Settings or listed in DEFAULTS.md" {
	run python3 -I - "$BATS_TEST_DIRNAME/.." <<'PY'
import glob, re, sys
root = sys.argv[1]
src = open(f"{root}/tools/welcome/src/main.rs").read()
docs = open(f"{root}/docs/DEFAULTS.md").read()
bad = []
for f in sorted(glob.glob(f"{root}/modules/gnome/extensions/*/schemas/*.xml")):
    ext = f.split("/")[-3]
    for k in re.findall(r'<key name="([^"]+)"', open(f).read()):
        if f'"{k}"' in src or f"`{ext}/{k}`" in docs:
            continue
        m = re.fullmatch(r"(\w+)-(radius|brightness)", k)
        if ext == "blur" and m and f'"{m.group(1)}"' in src:
            continue
        bad.append(f"{ext}/{k}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
	echo "$output"
	[ "$status" -eq 0 ]
}

# .claude/hooks/council-bash.py: council seats may run the lab and single read-only commands only.
@test "council hook: lab and read-only commands pass, everything else is blocked for seats" {
	hook="$BATS_TEST_DIRNAME/../.claude/hooks/council-bash.py"
	decide() { # agent command -> exit status
		python3 -I -c 'import json, sys; print(json.dumps({"agent_type": sys.argv[1], "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' "$1" "$2" | "$hook" >/dev/null 2>&1
	}
	decide council-design "tests/vm/lab.sh book design"
	decide council-design "tests/vm/lab.sh 1 ssh 'gsettings get org.gnome.desktop.interface color-scheme'"
	decide council-design "git log --oneline -5"
	decide council-design "cat docs/DESIGN.md"
	! decide council-design "tests/vm/lab.sh book x && rm -rf ~"
	! decide council-design "tests/vm/lab.sh 1 ssh 'ls | head'"
	! decide council-design "tests/vm/vm.sh stop"
	! decide council-design "rm -rf build"
	! decide council-design "git push"
	! decide council-design "find . -delete"
	! decide council-design "echo hi > file"
	decide general-purpose "rm -rf /tmp/x"
}

@test "tools build: none, partial, stale and ok are told apart" {
	run bash -c "source '$BATS_TEST_DIRNAME/../lib/tools-build.sh'
		repo='$BATS_TEST_TMPDIR/repo' dir='$BATS_TEST_TMPDIR/repo/tools/target/release'
		mkdir -p \"\$dir\" \"\$repo/tools/x/src\" \"\$repo/modules/gnome/extensions\" && echo a >\"\$repo/tools/x/src/main.rs\"
		echo \$(tools_build_state \"\$dir\" \"\$repo\")
		touch \"\$dir/ostrich\" && chmod +x \"\$dir/ostrich\" && echo \$(tools_build_state \"\$dir\" \"\$repo\")
		for b in \"\${TOOLS_BINS[@]}\"; do touch \"\$dir/\$b\"; chmod +x \"\$dir/\$b\"; done
		echo \$(tools_build_state \"\$dir\" \"\$repo\")
		tools_stamp \"\$repo\" >\"\$dir/.tools-stamp\" && echo \$(tools_build_state \"\$dir\" \"\$repo\")
		echo b >\"\$repo/tools/x/src/main.rs\" && echo \$(tools_build_state \"\$dir\" \"\$repo\")"
	[ "$status" -eq 0 ]
	[ "${lines[*]}" = "none partial unknown ok stale" ]
}

@test "gs_list_add writes an item passed twice only once" {
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	cat >"$BATS_TEST_TMPDIR/bin/gsettings" <<'STUB'
#!/bin/sh
f="$BATS_TEST_TMPDIR/list"
case $1 in
get) cat "$f" 2>/dev/null || echo "['a@x']" ;;
set) echo "$4" >"$f" ;;
esac
STUB
	chmod +x "$BATS_TEST_TMPDIR/bin/gsettings"
	export BATS_TEST_TMPDIR
	PATH="$BATS_TEST_TMPDIR/bin:$PATH"
	source "$LIB/gsettings.sh"
	gs_list_add org.gnome.shell disabled-extensions a@x b@x c@x b@x c@x
	[ "$(cat "$BATS_TEST_TMPDIR/list")" = "['a@x', 'b@x', 'c@x']" ]
}
