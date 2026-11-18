#!/usr/bin/env python3
# .claude/hooks/council-bash.py: a PreToolUse hook. Council seats (agents named council-*) may run
# tests/vm/lab.sh and a few read-only commands (git and graphify lookups among them), one at a time; anything else is blocked. Other agents
# and the main session are left alone. Chained or redirected commands (; && || | ` $( > <) are
# refused outright, so "tests/vm/lab.sh ... && something" can't slip through.
import json, re, shlex, sys

ALLOWED = {"ls", "cat", "head", "tail", "grep", "rg", "find", "wc", "file", "stat", "date", "df", "du", "pwd"}
GIT_READ = {"log", "show", "diff", "status", "blame", "ls-files"}

data = json.load(sys.stdin)
if not str(data.get("agent_type", "")).startswith("council-") or data.get("tool_name") != "Bash":
    sys.exit(0)
cmd = data.get("tool_input", {}).get("command", "").strip()


def deny(why):
    print(f"Blocked for {data['agent_type']}: {why}. Council seats may run tests/vm/lab.sh or one read-only "
          "command (ls, cat, grep, find, git log...) at a time.", file=sys.stderr)
    sys.exit(2)


if re.search(r"[;&|`<>\n]|\$\(", cmd):
    deny("no chaining, pipes or redirection")
try:
    words = shlex.split(cmd)
except ValueError:
    deny("couldn't read the command")
if not words:
    sys.exit(0)
prog = words[0]
if prog in ("tests/vm/lab.sh", "./tests/vm/lab.sh") or prog.endswith("/tests/vm/lab.sh"):
    sys.exit(0)
if prog in ALLOWED and not (prog == "find" and any(w in ("-exec", "-execdir", "-delete", "-ok") for w in words)):
    sys.exit(0)
if prog == "git":
    rest = words[1:]
    while rest and rest[0] in ("-C", "--no-pager"):  # seats outside the repo's cwd use git -C
        rest = rest[2:] if rest[0] == "-C" else rest[1:]
    if rest and rest[0] in GIT_READ:
        sys.exit(0)
# graphify's read-only lookups (the knowledge graph in graphify-out/), for a change's blast radius.
if prog == "graphify" and len(words) > 1 and words[1] in ("query", "explain", "path"):
    sys.exit(0)
deny(f"`{prog}` isn't allowed")
