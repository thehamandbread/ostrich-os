#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Runs INSIDE the test VM, in the desktop session: reads GNOME Shell's accessibility tree over
# AT-SPI, as a screen reader does. Used by a11y-test.sh.
#
# usage: a11y-tree.py where NAME    print "x y", the centre of the first node called NAME
#        a11y-tree.py showing NAME  the same, but only for a node that is on screen (hidden actors stay in the tree)
#        a11y-tree.py box NAME      "x y width height" of the first node called NAME that is on screen
#        a11y-tree.py check         ok/FAIL lines for our buttons' names; exits 1 on any FAIL
#
# The checks: every button under the dock ("Dock") and the workspace bar ("Workspaces"), every
# top-bar menu button (drawer icons, Monitor, the now-playing pill) and every toggle button (the
# Monitor popup's rows) has a name; and the names we build are there (a current workspace, a row
# named by its value and checked while pinned, a named app in the dock).
import re
import sys

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

R = Atspi.Role
BUTTONS = (R.PUSH_BUTTON, R.TOGGLE_BUTTON, R.MENU, R.MENU_ITEM)
SCOPES = ("Dock", "Workspaces")
# Our quick-settings tiles and top-bar buttons, by the text they hold (to tell them from GNOME's).
OURS = ("Focus", "Workspaces", "Touchscreen", "Now playing")


def shell():
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app is not None and app.get_name() == "gnome-shell":
            return app
    sys.exit("FAIL: no gnome-shell in the AT-SPI tree")


def walk(node, path=()):
    path = (*path, node)
    yield node, path
    for i in range(node.get_child_count()):
        child = node.get_child_at_index(i)
        if child is not None:
            yield from walk(child, path)


def label(path):
    return " / ".join(f"{n.get_role_name()}:{n.get_name() or '?'}" for n in path[1:])


def hint(node):
    """The first text inside an unnamed node, to tell whose it is."""
    for n, _ in walk(node):
        if n is not node and n.get_name():
            return f" (holds '{n.get_name()}')"
    return ""


def where(name):
    for node, _ in walk(shell()):
        if node.get_name() == name:
            r = node.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
            print(r.x + r.width // 2, r.y + r.height // 2)
            return 0
    print(f"FAIL: no node called {name}", file=sys.stderr)
    return 1


def showing(name):
    for node, _ in walk(shell()):
        if node.get_name() == name and node.get_state_set().contains(Atspi.StateType.SHOWING):
            r = node.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
            print(r.x + r.width // 2, r.y + r.height // 2)
            return 0
    print(f"FAIL: nothing on screen called {name}", file=sys.stderr)
    return 1


def box(name):
    for node, _ in walk(shell()):
        if node.get_name() == name and node.get_state_set().contains(Atspi.StateType.SHOWING):
            r = node.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
            print(r.x, r.y, r.width, r.height)
            return 0
    print(f"FAIL: nothing on screen called {name}", file=sys.stderr)
    return 1


def check():
    failures = 0
    gnome = []
    names = []
    in_dock = []
    for node, path in walk(shell()):
        role, name = node.get_role(), node.get_name()
        if role not in BUTTONS:
            continue
        scoped = any(n.get_name() in SCOPES for n in path[:-1])
        if not name and (scoped or role in (R.MENU, R.TOGGLE_BUTTON)):
            # GNOME 50's own quick-settings tiles and clock aren't named either: listed, not ours.
            held = hint(node)
            if scoped or any(f"'{t}'" in held for t in OURS):
                print(f"  FAIL: no name: {label(path)}{held}")
                failures += 1
            else:
                gnome.append(held.strip(" ()") or label(path).split(" / ")[-1])
        checked = role == R.TOGGLE_BUTTON and node.get_state_set().contains(Atspi.StateType.CHECKED)
        names.append((role, name, checked))
        if name and any(n.get_name() == "Dock" for n in path[:-1]):
            in_dock.append(name)

    def expect(what, found):
        nonlocal failures
        if found:
            print(f"  ok: {what}")
        else:
            print(f"  FAIL: {what}")
            failures += 1

    expect("a workspace pill says it is current", any(re.fullmatch(r"Workspace \d+(: .+)?, current", n or "") for _, n, _c in names))
    # The pin is the toggle's checked state, which a screen reader says itself: the name is only the
    # value ("Processor Usage 3%"), so it isn't announced twice (council 2026-11-05, M4). Processor and
    # Memory usage are pinned by default.
    expect("a pinned Monitor row is a checked toggle named by its value", any(r == R.TOGGLE_BUTTON and c and re.fullmatch(r"(Processor|Memory) Usage [\d.]+%", n or "") for r, n, c in names))
    expect(f"the dock's buttons are named ({', '.join(in_dock[:5])})", len(in_dock) > 0)
    if gnome:
        print(f"  note: GNOME's own, unnamed (not ours): {', '.join(sorted(set(gnome)))}")
    if failures == 0:
        print("  ok: every button of ours has a name")
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "where":
        sys.exit(where(sys.argv[2]))
    if len(sys.argv) == 3 and sys.argv[1] == "showing":
        sys.exit(showing(sys.argv[2]))
    if len(sys.argv) == 3 and sys.argv[1] == "box":
        sys.exit(box(sys.argv[2]))
    if len(sys.argv) == 2 and sys.argv[1] == "check":
        sys.exit(check())
    sys.exit("usage: a11y-tree.py where NAME | showing NAME | box NAME | check")
