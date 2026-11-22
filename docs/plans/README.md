# Plans: Ostrich OS rename, setup wizard, browser picker, crash agent, design skill

Docs only. Written 2026-11-21 from `CLAUDE.md`, `docs/DESIGN.md`, `docs/DECISIONS.md`, `CONTEXT.md` and a read of the code at `wip-ui` (dcac648). Nothing outside `docs/` was changed. `docs/INVENTORY.md` was not read (it is private and was not needed for any plan).

| File | What |
|---|---|
| `00-audit.md` | What exists today, every "ubuntu-ostrich" identifier (persisted ones marked), container evidence, Omarchy and name checks |
| `01-rename.md` | Rename to Ostrich OS, trademark clauses, migration, URL test plan |
| `02-setup-and-settings.md` | `options.json` schema, wizard, `--choices`, elevation, Settings |
| `03-browser-picker.md` | `ostrich-browser` |
| `04-crash-agent.md` | Crash detection → report → agent, skills |
| `05-design-skill.md` | `DESIGN-SYSTEM.md`, design skill, headless screenshot loop (proved) |
| `evidence/` | Raw container output, the hello-window script and run script |

## Read this first: the findings that change the specs

1. **The wizard and Settings are one existing Rust app** (`ostrich-setup`, 2.8k lines, GTK4 + libadwaita), not a prompt, and the spec asks for Python. Settings applies changes live through GSettings, with no module and no options file. The installer's only prompt is "keep or clean other extensions" (Bash `read`).
2. **No module has a revert** except the global `--uninstall` restore point. The spec's per-option apply and revert needs that built.
3. **Renaming is mostly not the CLI** (`ostrich` already exists). The risk is persisted IDs: dconf paths, extension UUIDs, the drawer's logins directory, root-owned polkit/helper/unit files, and the update URL baked into installed 0.5.0 binaries (they reach the new release only through GitHub's redirect, so never recreate a repo at the old name).
4. **systemd-coredump replaces the apport kernel handler** (it `Conflicts` with it). apport still gets crashes through its drop-in, but that is not proven end to end, so the option stays hidden until a VM test passes.
5. **Browser picker:** Firefox has no reliable flag for "open in the other profile's running instance"; it needs a VM matrix before any flags ship. Super+B is free in the repo, but the GNOME 50 custom-keybinding path is unconfirmed.
6. **Headless screenshots work** (Xvfb, no compositor) with two defects in the first proof (cut-off window, missing icon); fixes are in plan 05.

## All CONFLICT lines (29 in the plan files, then 4 task-level notes)

Each is a place where the spec and the repo (or a checked fact) disagree. The full text, with the reasoning, is in the file named. The spec text itself was left as written.

### 01-rename.md
1. **State dir missing from the spec** (`~/.local/state/ubuntu-ostrich`) → add `~/.local/state/ostrich/`.
2. **CLI is already `ostrich`** → no binary rename; only paths, IDs, UUIDs and URLs move.
3. **"OS" name vs an installer on stock Ubuntu, and the ISO builder** → keep the name if wanted, but modified-Ubuntu ISOs need Canonical approval regardless of name; publish none.
4. **ISO/VM test paths** are dev-only → rename them in the same commit, no migration.
5. **"Re-enable extensions under new UUIDs"** cannot load in the running Wayland session → write the new UUIDs to `enabled-extensions`, then log out.

### 02-setup-and-settings.md
6. **Python + PyGObject** vs the existing Rust app and `DESIGN.md` → keep Rust for the app, make the JSON schema the shared piece. **Owner decision.**
7. **Wizard before installer** vs today's installer-then-wizard with live GSettings → two option kinds (`install`, `setting`) in one schema; the one-liner installs the base, then opens the wizard.
8. **`module` per option / per-option apply** vs most settings having no module and no revert → a `target` object (module, gsettings, or file) and a `revert` verb on every module.
9. **Title ≤5 words, ≤7 options per page, title + one sentence** vs current pages (Top bar 18 rows etc.) → copy pass and page splits.
10. **AdwPreferences UI** vs the current sidebar + custom rows → keep it, render stock rows from the schema, list custom pages in the schema.
11. **"Never run sudo" project rule** vs the installer's own elevation design → no change; polkit helper first, one `sudo` only where no polkit agent exists.

### 03-browser-picker.md
12. **Super+B** is free in the repo; GNOME 50 custom-keybinding path unconfirmed → verify in the VM; prefer an extension keybinding; append to existing custom keybindings.
13. **Python cold start** vs the measured-budget principle → build in Rust unless Python measures ≤400 ms cold.
14. **Firefox `-P name` into the correct running instance** → no single reliable flag; four-case VM matrix; ship only observed flags.
15. **Snap Firefox** profile paths and confinement → use `-P` names for snap Firefox; test.
16. **`xdg-settings` only covers http/https** → also `xdg-mime default` for `text/html`; read both back for Settings.
17. **"URL never lost" vs "Esc cancels"** → Esc is a deliberate cancel; the rule applies to errors.

### 04-crash-agent.md
18. **Journal follower vs apport path unit** → read `core_pattern` and start the matching source; dedupe when both fire.
19. **Use systemd-coredump option** not proven → hidden and disabled until a VM test passes (crash file and `coredumpctl` entry and apport dialog).
20. **`notify-send --action`** supported by the binary but the repo records it fails on GNOME 50 (unverified upstream) → send via GNotification from an app with its own ID.
21. **Gemini CLI** may be replaced by Antigravity CLI (one unverified source) → keep detection, agents as data files, recheck before release.
22. **gitleaks 8.16.0 in the archive** has an older CLI → version-detect; built-in redaction is primary; never claim a scan that did not run.
23. **`gh issue create --web`** (gh 2.46.0) can't reliably prefill long bodies → prefilled URL plus report path; nothing posted.
24. **Agent file vs "all copy in options.json"** → a `crash.agent` option whose storage is that file.

### 05-design-skill.md
25. **Skill already exists** at that path → extend it, never overwrite.
26. **"No custom CSS beyond accent"** vs shell extensions and the scheme system → scope the rule to GTK/libadwaita app windows.
27. **British vs American spelling** → owner picks once; default keep British.
28. **≤7 options per page vs 18-row pages** → "≤7 per group", the rest collapsed or on sub-pages.
29. **Broadway needs a browser to screenshot** → Xvfb + x11 + software rendering (proved).

### README / task
30. **"`git diff --stat` shows only docs/ changed"** cannot show new files, which are untracked until added → use `git status --short` and `git diff --stat --cached` after `git add docs/`.
31. **`spikes/agent/` appeared in the working tree during the work, not made by these plans** (script and results from another session) → left untouched and excluded from the commit.
32. **Plan 02 and 04 want a `ostrich settings get|set` CLI** that does not exist (`tools/ostrich/src/` has `config.rs`, `env.rs`, `main.rs`) → build it in step 6 below before the `ostrich` skill claims it.
33. **Plan 04 sends crash reports to a third-party model provider** while `DESIGN.md` says "no telemetry/network calls" for extensions → fine for tools (nothing leaves without the consent screen); state it in `DECISIONS.md`.

## Build order

One module per task. Each task ends with: shellcheck, shfmt, bats, `gitleaks git --redact` (the pre-commit hook), and a commit. Test in Docker `ubuntu:26.04` or the VM; **never on the live machine**. Version bump and a release only after the whole step passes `tests/vm/release-suite.sh`.

Order: design skill → rename → schema → wizard/Settings → picker → crash agent. The brief said "rename first" **and** "design skill before any UI". They are compatible because the rename has no UI; only the copy it renames. So: **0. design skill (docs and scripts only, no UI), then 1. rename**, then everything else. If the owner wants the rename literally first, do the rename first; step 0 touches no file that step 1 touches except the skill's own name mentions.

| # | Task | Files to touch | Done when | Test |
|---|---|---|---|---|
| 0 | **Design system and loop** (plan 05) | `docs/DESIGN-SYSTEM.md`, `.claude/skills/ostrich-design/SKILL.md` (extend), `references/{copy,headless}.md`, `tests/ui/{shot.sh,Dockerfile}`, `tests/options-lint.sh` (copy checks only), CI job | Plan 05 done criteria 1–5 | Docker: `tests/ui` screenshots of hello window, dark, 2×, full size; token-lint still passes |
| 1 | **Rename + migration** (plan 01) | every file in plan 01's list; `lib/migrate.sh`; `tests/migrate.bats`; `tests/vm/rename-test.sh`; `README.md` notice; `docs/DECISIONS.md` | Plan 01 test plan all green; `rg -i "ubuntu.?ostrich"` only allowed leftovers; redirect `curl -IL` outputs recorded; **release 0.6.0 = rename only** | bats; Docker smoke twice; VM upgrade from 0.5.0 via old URL; then GitHub repo rename by the owner and the three `curl -IL` checks |
| 2 | **Schema + lint** (plan 02) | `share/ostrich/options.json`, `lib/options.sh`, `tests/options-lint.sh`, `tests/options.bats`, `tests/fixtures/choices/*`, `schema/hidden.json` | Lint passes; every user-visible key covered or listed; copy-review pass committed (`old → new` list); no code behaviour changes yet | bats in Docker |
| 3 | **Module contract: `status` and `revert`** (plan 02) | `lib/module.sh`, `modules/*/install.sh`, `modules/hardware/*` | install → revert → install round trips leave identical state for every module | Docker for non-hardware modules; VM for hardware fixtures (hybrid GPU, touchscreen) |
| 4 | **Installer `--choices`, `--json-progress`, `--only`, `--revert`, whiptail from schema** (plan 02) | `install.sh`, `lib/options.sh`, `lib/prompts.sh`, `tests/install.bats` | Plan 02 done criteria 2; unattended install from each fixture | Docker: dry-run + real run twice; whiptail via `script` |
| 5 | **Elevation helper actions** (plan 02) | `tools/system-helper/src/`, `modules/hardware/org.ostrich.system-helper.policy`, `lib/helper.sh`, `tests/vm/polkit-test.sh` | Root steps run only through helper actions that read the root-owned schema; one password per full install | VM polkit test; fuzz: a hand-edited `choices.json` with a fake package id is refused |
| 6 | **`ostrich settings get/set` CLI** (needed by plans 02/04) | `tools/ostrich/src/main.rs` (+ new `settings.rs`) | CLI reads/writes every schema option, same validation as the lint | `cargo test`; Docker |
| 7 | **Wizard + Settings from the schema** (plan 02; needs step 0) | `tools/welcome/src/{lib.rs,main.rs}` (schema-driven rows, first-run flow, page splits), `share/ostrich/options.json` | Plan 02 done criteria 4–6; all pages ≤7 options per group; screenshots (light, dark) saved in `docs/screenshots/` | VM: keyboard-only run-through; plan 05 loop; `tests/vm/ui-test.sh`; `tests/look-check.sh --vm` |
| 8 | **Browser picker: discovery + rules + launch core** (plan 03) | `tools/browser-picker/{discover,rules,launch}.rs`, `tests/fixtures/browsers/*`, `tests/browser-picker.bats` | Fixture matrix of plan 03 criterion 1, 3, 8 in Docker | `cargo test`; Docker |
| 9 | **Browser picker: spike for Firefox flags and profile groups** (plan 03) | `docs/spikes/browser-picker.md` (VM notes) | Four-case Firefox matrix result recorded; profile-group sqlite schema dumped; Super+B path verified on GNOME 50 | VM only (real Firefox snap + deb) |
| 10 | **Browser picker UI + module + Settings page** (plan 03; needs steps 0, 7, 9) | `ui.rs`, `main.rs`, `modules/browser-picker/`, desktop + D-Bus service files, Settings Browser page, option in schema | Plan 03 done criteria 2, 4–7; cold ≤400 ms, warm ≤80 ms recorded in `docs/BASELINE.md` | VM `tests/vm/browser-test.sh` |
| 11 | **Crash: classifier, report builder, redaction** (plan 04) | `tools/crash/{classify,report,redact}.rs`, `tests/fixtures/crash/*`, `tests/crash-{classify,redact}.bats` | Fixture secrets/PII never survive; classifier scenarios pass | `cargo test`; Docker |
| 12 | **Crash: sources, notification, rate limit, mute** (plan 04) | `tools/crash/{watch,scan,notify}.rs`, units, `tools/ostrich/src/main.rs` (`crash` verbs), `modules/crash/` | Plan 04 criteria 1, 2, 8, 9 | VM: real crashes under apport; `kill -SEGV gnome-shell` |
| 13 | **Crash: boot-time class (b)** (plan 04) | `ostrich-crash-boot.service`, scan code, `tests/vm/crash-test.sh` | Scenarios (i)–(vii) classify as listed | VM with QEMU resets, sysrq; fixture journals in Docker |
| 14 | **Crash: agents, consent, skills** (plan 04; needs step 6) | `share/ostrich/agents.d/*`, `share/ostrich/skills/{diagnose-crash,ostrich}`, consent dialog, Settings Crashes page | Plan 04 criteria 5–7 | VM with a fake agent script that records argv; one real-agent run with a throwaway account |
| 15 | **Crash: systemd-coredump option** (plan 04; optional, last) | module option, hidden by default | VM test: crash file, `coredumpctl` entry, apport dialog all present; only then un-hide | VM |
| 16 | **Release 0.7.0** | `VERSION`, `tools/Cargo.toml`, `docs/RELEASING.md`, `CONTEXT.md` | `tests/vm/release-suite.sh` all PASS, CI green, README one-liner works on a fresh Ubuntu in the VM | VM release suite |

Dependencies: 2→3→4→5→7; 0→7→10→14 (UI needs the design loop); 1→everything (names); 6→14 (the `ostrich` skill).

## Decisions needed from the owner

1. Keep the app in **Rust** (recommended) or rewrite in Python (plan 02, 03).
2. British or American spelling (plan 05).
3. Whether the rename ships alone as 0.6.0 (recommended) and whether the design skill (step 0) comes before it.
4. Whether to keep "Ostrich **OS**" given the installer-not-distro reality and the ISO builder (plan 01).
5. A formal trademark search for "Ostrich OS" before wide release (not done).
6. Drop or keep `gemini` as an agent (plan 04).

## What was not verified

Everything below is marked in the plan text; none of it was run on a real kernel, VM or the live machine.

- Which `core_pattern` wins at runtime (derived from sysctl.d file order in a container whose sysctl is read-only), and that apport gets crashes after `systemd-coredump` is installed.
- That `raw.githubusercontent.com` follows a repo rename for the old installer URL (must be tested after the rename with `curl -IL`).
- Exact Canonical trademark wording (fragments came from a page summary; re-read the page before the README text is final).
- Firefox profile-group sqlite filename and schema, snap Firefox flags, GNOME 50 custom-keybinding path.
- Whether `notify-send --action` works on GNOME 50 (the repo says no; upstream gives no reason).
- Opencode `--prompt` and Codex `codex "<prompt>"` invocations.
- Name search for "Ostrich OS" covered GitHub, PyPI, npm, crates.io, Flathub, Snap Store and the web, not trademark registers.
