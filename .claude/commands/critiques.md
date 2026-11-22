---
description: Read the critiques flagged in the test VM (Super+Alt+C) and plan the fixes
---

The user has been testing Ostrich OS in the VM and flagging problems with the critique tool
(Super+Alt+C: a box around the problem and a note). The notes are in the host inbox that the VM
writes into directly.

1. Run `tests/vm/critique.sh list` to see the open notes (and `--all` if the user asks about done ones).
2. For every open note, read `note.json` (the text, the kind, what was boxed and which extension owns
   it, that extension's settings, the versions) and `errors.txt`, and look at `screen.png` and each
   `crop-N.png` with the Read tool. `tests/vm/critique.sh show ID` prints a summary. Notes marked
   `need-info` have a question for the user: ask it again, with the screenshot in mind.
3. Write a fix plan: group the notes by owner (dock, drawer, blur, workspaces, a window, ...), quote
   each note's id and its words, say what's wrong in the code (file and line) and what the fix is.
   If a note is unclear, say so and ask, rather than guessing. Present the plan before changing code.
4. After the user approves and the fixes are made and tested in the VM, open the same scene in the
   VM, take an "after" screenshot (`tests/vm/vm.sh screenshot`), and mark each note done:
   `tests/vm/critique.sh done ID COMMIT after.png "what changed"`. For a note that needs the
   user's input, `tests/vm/critique.sh ask ID "question"`.

Never install the critique tool anywhere but the test VM. Notes stay on the user's computer and are
never committed.

$ARGUMENTS
