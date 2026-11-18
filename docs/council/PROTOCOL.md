# How the council debates

The council decides what Ubuntu Ostrich should do next to be the best Linux desktop for as many
people as possible. Twelve advocates first explore (the web, other systems and devices, what people
say, and lab copies of the VM), a curator gathers what they found, then they argue in three rounds;
a researcher checks the facts, disputed claims are tested in the VM, a judge rules, and the owner
approves the verdict before anything is built. `/council` runs it
(`.claude/commands/council.md`); this file is the rulebook every seat follows.

## What every seat reads first
1. The agenda, given in your task.
2. From round 1 on: the curator's `inspiration.md` (what all the seats found while exploring).
3. The evidence pack's `index.md` (its path is in your task). It lists every screenshot,
   measurement and note with a caption, and gives the numbers. Open the files it lists when
   they bear on your case.
4. `docs/council/PERSONAS.md`: the people you argue for.
5. As needed: `docs/DESIGN.md` (what the project is and its principles), `docs/DECISIONS.md` (why
   things are the way they are), `docs/PARITY.md`, `docs/DEFAULTS.md`, `CLAUDE.md` (the rules),
   and the code under `modules/` and `tools/`.

## Rules
- **Evidence or "opinion".** Every claim cites a file, a screenshot or a number from the pack, a
  line of code (`path:line`), your own lab screenshot or measurement, or a web source (with its
  link). A claim without one is labelled *(opinion)*. In round 2 the
  researcher's `facts.md` is evidence too; a claim it marks wrong must be dropped or re-argued
  with new evidence.
- **When the facts run out, test it.** You can check a claim yourself in a lab VM
  (`tests/vm/lab.sh`) and cite what you saw. For tests the lab can't do (long measurements, our own
  test scripts, a fresh install), request up to three per round (rounds 1 and 2) that would settle
  a disputed claim. Each test is a
  measurement, a screenshot of a scene, or a variant with a setting changed, and it comes with the
  result that would prove the claim and the one that would disprove it. The clerk runs what the test
  VM can run after round 2 (`tests.md`). A claim a test disproves must be dropped in round 3.
- **Opinion is allowed, and weighed as opinion.** Taste (a colour, a word, a feel) can't always be
  tested; say so. The owner's own words are evidence of what the owner wants, not of what most
  people want; for that, cite a source or label it opinion.
- **Name the people.** Every proposal says which personas gain and which lose.
- **Count the cost.** Every proposal says what it costs the other seats: battery, memory, effort,
  upkeep, simplicity, control, looks. A proposal that pretends to be free will be discounted.
- **Concrete.** Say what changes and where (files, extensions, settings, screens). "Improve UX" is
  not a proposal; "the monitor popup's rows drop to 28 px and the footer to icons only
  (`modules/gnome/extensions/monitor/stylesheet.css`)" is.
- **Inside the project's rules.** CLAUDE.md and DESIGN.md bind every proposal: Ubuntu 26.04 and
  GNOME 50 only; event-driven, nothing polls without a visible reason; never wake the dGPU; no
  third-party assets committed; idempotent, reversible installs. To change a principle, say so
  openly: that becomes a question for the owner, not a quiet assumption.
- **Inspiration, not imitation.** Bring ideas from anywhere (other desktops, phones, cars,
  consoles, products, design writing, forums), but argue for what they do for our people, never
  for "making it like" another system.
- **Plain words.** Write the way a knowledgeable person talks. No filler, no grandstanding.
- **Stay in your lane, argue across it.** Champion your seat's concern hard, but concede when
  another seat is right; a seat that never concedes loses the judge's trust.

## Round formats
Reply in markdown with exactly these sections; the clerk saves your reply as your round's file.

### Round 0: exploration
Research freely from your seat's point of view: the agenda first, then whatever you think matters
most for your people. Use the web (what other systems and devices do, design writing, reviews,
what people say) and a lab VM (book a slot, look around as your persona would, change settings,
screenshot to `evidence/lab/<seat>/`, measure, release). Then:
```
# <seat>: exploration
## What I looked at
Searches, sources and lab sessions, briefly.
## What I found
Each finding: what it is, where (link or lab screenshot), and why it matters for my people.
## Ideas
At most eight, each a sentence or two: what Ubuntu Ostrich could do, inspired by what (with source),
who gains, and the cost as far as I know it.
## Agenda items
A short take on each agenda item from my side.
```

### The curator
Reads every exploration and writes `inspiration.md`: ideas by theme with their sources and who raised
them, what bears on each agenda item, where seats disagree, and every source once
(`.claude/agents/council-curator.md`).

### Round 1: opening
```
# <seat>: opening
## Where we stand
Three to six sentences: how the OS serves your concern today, with evidence.
## Proposals
### 1. <short name>
- What: ...
- Where: files / extensions / screens
- Serves: personas (and who loses)
- Evidence: ...
- Cost to others: ...
(at most five proposals, most important first)
## Red lines
What you will not accept another seat doing, and why (at most three).
## Tests requested
At most three, for claims that matter and that the evidence doesn't settle:
- Claim: ... | Test: what to run or capture in the VM | Proves it if: ... | Disproves it if: ...
```

### Round 2: rebuttal
```
# <seat>: rebuttal
## Responses
One short paragraph per other seat that matters to you: attack, concede or merge, with evidence.
## Facts check
Which of your claims facts.md confirmed or refuted, and what you changed.
## Revised proposals
Your list after this round (same fields as round 1; mark merged ones "merged with <seat>").
## Tests requested
At most three new ones (same form as round 1), now that you've seen the other seats' claims.
```

### Round 3: closing
Read `tests.md` first: a claim a test disproved is dropped; one it proved is now evidence.
```
# <seat>: closing
## Top three
Your final three asks, each in two or three sentences with its strongest evidence.
## What I give up
What you concede to get them.
## Where I agree with
Proposals from other seats you support.
```

## The researcher
Reads every opening and checks factual claims: GNOME 50 APIs and behaviour, what other systems
(Windows, macOS, Fedora, Zorin, Pop!_OS, elementary) actually do, upstream plans, and that the cited
evidence says what the seat says it does. Writes:
```
# Facts
| # | Seat | Claim | Verdict (confirmed / wrong / unproven) | Source |
## Notes
Anything the seats all missed.
```

## Tests between rounds
After round 2 the researcher reads every "Tests requested" section, merges duplicates, and sorts each
request into: **runnable** in the test VM with the existing tools (`tests/vm/baseline.sh`,
`shell-bench.sh`, `compare.sh`, `ext-test.sh`, `ui-test.sh`, `drawer-test.sh`, `store-test.sh`, a
scene with a gsettings variant, a screenshot), **needs a build** (a feature that doesn't exist yet),
or **can't be settled here** (watts on real hardware, how people would feel). It writes
`test-plan.md`:
```
# Test plan
| # | Requested by | Claim | Test (exact command or scene) | Proves if | Disproves if | Kind |
```
The clerk runs the runnable ones, at most about an hour of VM time, most-requested first, and writes
`tests.md` with each result (numbers, screenshot paths) and a verdict per claim: proved, disproved,
or inconclusive. Results and screenshots go into the evidence pack (`evidence/tests/`).

Seats may also run their own lab checks between rounds and cite them; those count as evidence like
the clerk's.

What can't be tested here isn't thrown away: the judge may still choose it, but as an **experiment**
in the plan (try it, measure, keep or revert, with the pass/fail line), never as a settled fact.

## The judge
Reads everything and rules. The rubric, applied to each proposal that survived:

| | Weight |
|---|---|
| Reach: how many personas gain | 3 |
| Impact: how much better it gets for them | 3 |
| Cost to battery and resources (measured where possible) | 2 |
| Risk and upkeep (the maintainer's case) | 2 |
| Effort | 1 |
| Strength of evidence (after the facts check and the tests) | 2 |

Scores are 1–5 per row. Writes:
```
# Verdict: <agenda>
## Summary
One paragraph: what the council decided and why.
## Rulings
One per real dispute: the question, the sides, the ruling, and why.
## Scorecard
Table: proposal, seat, each rubric score, total.
## The plan
### Must (this round)
### Should (next)
### Experiments
Untested ideas worth trying: what, the measurement, and the line that decides keep or revert.
### Not now
Each item: what, where (files), who it serves, how to verify it.
## Rejected
Proposals turned down, and why.
## Owner vs most people
Where the owner's stated taste and the majority pull apart: the default chosen and the setting
that lets both win.
## Options for the owner
Only when the agenda says the owner chooses (a colour scheme, an icon style): two or three complete
options instead of one winner, each specified well enough to build and preview as it stands (for a
scheme: every colour token for light and dark, the accent, how the icons, glass, dock and top bar
use it), with the seats who back it and what each costs.
## Questions for the owner
Anything that would change DESIGN.md or CLAUDE.md, or that the evidence couldn't settle.
```
