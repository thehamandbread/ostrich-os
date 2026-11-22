# Plans: Ostrich OS rename, drawer integration, browser picker, crash agent, tour redesign

Docs only. First written 2026-11-21 from `CLAUDE.md`, `docs/DESIGN.md`, `docs/DECISIONS.md`, `CONTEXT.md` and a read of the code at `wip-ui`; **amended the same day** by the owner to match repo reality (Rust tools, the existing tour and council, the id rules, the drawer integration). Nothing outside `docs/` is changed by this work. `docs/INVENTORY.md` was not read (private, not needed).

| File | What |
|---|---|
| `00-audit.md` | What exists, every old-name identifier (persisted ones marked), container evidence (A3), Omarchy and name checks, **drawer doc drift (A6)** |
| `01-rename.md` | Ostrich OS: `ostrich-os` vs `ostrich_os` ids, one migration table for three slugs, drawer logins and per-site notification settings, trademark clauses, wget URL test |
| `02-tour-and-settings.md` | Redesign plan for `tools/welcome` (the tour and Ostrich Settings): `copy.toml`, one council session (to approve before it runs), design-skill gaps |
| `03-browser-picker.md` | `tools/browser-picker` / `ostrich-browser`, every drawer call site, shared `site-match` crate, `open` drawer action, activation token |
| `04-crash-agent.md` | Crash watcher, report, redaction, agents, skills |
| `evidence/` | Raw container output (A3), the headless screenshot script. `docs/screenshots/ostrich-setup-dock-headless.png` is its proof |

There is **no** `05` file: the design skill and the council already exist; real gaps in the skill are listed in `02-tour-and-settings.md`.

## Findings that matter

1. **`install.sh` needs no pre-install answers** (its only question is Keep/Clean, which has flags), so there is no `options.json`, `jq` or `choices.json`. One copy file instead: `tools/welcome/data/copy.toml`.
2. **Renaming is ids, not the CLI.** `ostrich` is already the CLI. `ostrich-os` for paths, UUIDs and schemas; `ostrich_os` (no dash before the last part) for app, `.desktop` and D-Bus ids because of the portal crash. The risks are drawer logins (cookies under `~/.local/share/ubuntu-ostrich/drawer/`), per-site notification settings (keyed by app id), the `favorite-apps` drawer entries, root-owned helper files, and old installs reaching the new release only through GitHub's redirect.
3. **Once the picker is the default browser, six drawer call sites open it**, and two of them (the "didn't load → Open in browser" button and the DRM-site launcher) pass the site's *own* URL and would loop. `drawer_offer ⇒ stays_in_drawer` over a shared crate is the no-loop proof.
4. **The drawer passes no launch context anywhere**, so GNOME shows "… is ready" instead of focusing the picker; the fix and a VM test with a negative control are planned.
5. **Drawer docs disagree with the code in four places** (A6): loaded dot, 300 vs 500 ms hover, per-site sizes the host still carries, and the dash-form app id in `DESIGN.md`.
6. **Headless screenshots work for the real app** in `ubuntu:26.04` (light, 100 % text); dark and 200 % text do not and stay VM-only.
7. **systemd-coredump replaces the apport kernel handler** (it `Conflicts` with it); apport still gets crashes through its drop-in, but that is not proven end to end, so the option stays hidden until a VM test passes.

## All CONFLICT lines (20 in the plan files, then task-level notes)

Where the owner's spec or amendment and the repo (or a checked fact) disagree. Full text and reasoning are in the named file.

### 01-rename.md
1. **Dock/`favorite-apps` entries hold the drawer's old app id** and would lose the icon → migrate any entry equal to an old drawer/Store/setup id in the same step.
2. **"Re-enable extensions under new UUIDs"** can't finish in the running Wayland session → write the new UUIDs to `enabled-extensions`, then ask for a log-out.
3. **Per-app notification child naming and keys not verified** → read them from a VM first, record the rule, then implement.
4. **"OS" in the name vs an installer on stock Ubuntu, and the ISO builder** → publish no ISO until Canonical's terms are cleared.

### 02-tour-and-settings.md
5. **`/council --panel` accepts only full/design/system**, none of which is the five-seat panel → add `--panel tour` (newcomer, everyday, simplicity, design, access; judge, researcher, curator always) to `.claude/commands/council.md` and `CLAUDE.md` before the session.

Also noted there (not a conflict now): if the council makes "Minimal" mean *fewer things installed*, the installer would need a pre-install answer, which would contradict "drop `choices.json`". Keep Minimal = fewer things switched on.

### 03-browser-picker.md
6. **Tour/wizard drawer calls carry no token either** → out of scope (they run from the wizard's focused window); only the six drawer sites are in scope.
7. **Spec's `ostrich-browser.desktop`** vs the `ostrich_os.<name>` id rule → `ostrich_os.browser.desktop`, `Exec=ostrich-browser %U`.
8. **"Offered only when ≥2 profiles"** vs drawer sites as targets → ≥2 profiles **or** ≥1 drawer site; with one target and no drawer match the picker never shows.
9. **Super+B** is free in the repo; the GNOME 50 custom-keybinding path is unconfirmed → verify in the VM; prefer an extension keybinding.
10. **"Measure cold and warm" sets no numbers** → cold ≤400 ms, warm ≤80 ms in the VM.
11. **Firefox flags** for the right running instance → four-case VM matrix; ship only observed behaviour.
12. **Snap Firefox profile paths and confinement** → `-P` names only; test.
13. **`xdg-settings` covers only http/https** → also `xdg-mime default` for `text/html`; save the previous default for revert.
14. **"URL never lost" vs "Esc cancels"** → Esc is a deliberate cancel; the rule is about errors.

### 04-crash-agent.md
15. **Journal follower vs apport path unit** → read `core_pattern` and start the matching source; dedupe.
16. **"Use systemd-coredump" option not proven** → hidden until a VM test passes.
17. **`notify-send --action`** works in the binary but the repo says GNOME 50 drops actions (unverified upstream) → GNotification from an app with its own ID.
18. **Gemini CLI** may be replaced by Antigravity CLI (one unverified source) → agents as data files; recheck before release.
19. **gitleaks 8.16.0 in the archive** has an older CLI → version-detect; built-in redaction is primary.
20. **`gh issue create --web`** (gh 2.46.0) can't reliably prefill long bodies → prefilled URL plus report path; nothing posted.

### Task-level notes
- **"`git diff --stat` shows only docs/"** cannot list new files until they are added; use `git status --short` and `git diff --cached --stat`.
- **`spikes/agent/`** appeared in the working tree during the first pass and is not part of these plans; it was left alone and is not in either commit.
- **A5 name check** and **A4 Omarchy** results from the first pass stand unchanged.

## Build order

One module per task. Each ends with shellcheck, shfmt, bats, `cargo test`/`clippy` where Rust is touched, `gitleaks` (the pre-commit hook), and a commit. Tests run in Docker `ubuntu:26.04` or the VM, **never on the live machine**. The order is the owner's:

| # | Task | Files to touch | Done when | Test |
|---|---|---|---|---|
| 1 | **Rename + migration** (plan 01), one release with nothing else (0.6.0) | everything in plan 01's table and code list; `lib/migrate.sh`; `tests/{migrate.bats,appid-lint.sh}`; `tests/vm/rename-test.sh`; README trademark notice; `docs/DECISIONS.md`, `docs/RELEASING.md` (never recreate the old repo name) | Migration bats green (three slugs, mixed, twice); app-id lint green; **VM proof that a signed-in stand-in site stays signed in** (and the negative control fails); per-site notification setting survives; dock keeps the drawer icon; wget old-URL chain ends `200` at `ostrich-os`; `rg` leftovers only allowed ones | bats + Docker smoke; VM upgrade from 0.5.0 via the old URL; owner runs the post-rename wget checks |
| 2 | **Drawer doc drift** (A6) | `docs/FEATURES.md` (DRW-1, DRW-2), `docs/DESIGN.md` (drawer section: dot, hover, sizes, ids), `docs/DECISIONS.md` (a dated note, no history edits); owner confirms 500 vs 300 ms | The four drifts are gone; `rg "loaded dot|300 ms|set-size|ubuntu-ostrich.drawer" docs/` hits only dated history; drawer-test asserts the chosen hover default and no dot | Docs review; `tests/vm/drawer-test.sh` |
| 3 | **Shared same-site crate** (plan 03) | new `tools/site-match/` (moved `host_of`, `site_of`, `same_site`, `SIGN_IN_HOSTS`, `stays_in_drawer`, new `drawer_offer`), `tools/drawer-host/{Cargo.toml,src/config.rs,src/main.rs}`, `tools/Cargo.toml`; also remove the unused per-site `set-size`/shape code (A6 #3) | Drawer's existing tests pass unchanged against the crate; **property test: `drawer_offer ⇒ stays_in_drawer`**; drawer-test unchanged | `cargo test`, `clippy -D warnings`, Docker; `tests/vm/drawer-test.sh` (63 checks) |
| 4 | **Browser picker** (plan 03): discovery, rules, launch, UI, module, Settings page | new `tools/browser-picker/`, `modules/browser-picker/`, desktop + D-Bus service files, `tools/welcome` Browser page, `tests/fixtures/browsers/`, `tests/browser-picker.bats`, `tests/vm/browser-test.sh`; first the two spikes (Firefox flag matrix and profile-group schema; Super+B on GNOME 50) | Plan 03 done criteria 2–5, 8–10 | `cargo test` + fixtures in Docker; VM with real browsers; timings in `docs/BASELINE.md` |
| 5 | **Drawer ↔ picker integration** (plan 03) | `tools/drawer-host` (`open((ss))` action, `--open` CLI, `open_external` with the launch context at all six sites, `--no-drawer`/`--from-drawer` handling), picker `drawer.rs`, `tests/vm/{picker-drawer-test,picker-focus-test}.sh`, `docs/FEATURES.md` (DRW-13) | Plan 03 done criteria 6–7: no loop (negative control fails), picker takes focus, no "is ready" notification, "Open in Drawer" works and rejects off-host URLs | VM only |
| 6 | **Crash watcher** (plan 04): classifier, report, redaction, sources, notification, rate limit, mute, boot-time class | new `tools/crash/`, `tools/ostrich/src/main.rs` (`ostrich crash …`), `modules/crash/`, units, `tests/fixtures/crash/*`, `tests/crash-{classify,redact}.bats`, `tests/vm/crash-test.sh` | Plan 04 done criteria 1–4, 8, 9 | `cargo test` + Docker for classifier/redaction; VM for real crashes under apport, `kill -SEGV gnome-shell`, QEMU resets |
| 7 | **Crash skill + agent page in the tour** (plan 04; the page's placement is provisional until step 8) | `share/ostrich-os/{agents.d,skills/diagnose-crash,skills/ostrich}`, consent dialog, `tools/welcome` Crash help page, `copy.toml` entries | Plan 04 done criteria 5–7: consent first, per-agent skill install and revert, read-only skill verified with a fake agent and one real run on a throwaway account | VM with a fake agent that records argv |
| 8 | **Tour/Settings council** (plan 02), then its build | Council: add `--panel tour`, `tests/vm/evidence.sh` tour/Settings screenshots at 100 %/200 % text, `ostrich-setup --list-pages`; **owner approves before it runs**. Build after approval: `tools/welcome/data/copy.toml`, `tools/welcome/src/{lib.rs,main.rs}`, `tools/ostrich/src/config.rs` (`describe`, `docs`), generated `docs/DEFAULTS.md`, design-skill gap fixes | Plan 02 done criteria 1–6 (the five council targets, copy tests, 200 % text clean) | council verdict with `tests.md`; `cargo test -p welcome`; VM screenshots light/dark at 100 %/200 % |

Dependencies: 1 before everything (names and ids); 3 before 4 and 5; 4 before 5; 6 before 7; 7 and the picker's tour offer feed 8 (the council decides where those pages sit). Steps 2 and 3 can run in either order after 1.

## Decisions needed from the owner

1. Hover delay: 500 ms (the code, and a council note) or 300 ms (the older docs) (A6 #2).
2. Whether the rename ships alone as 0.6.0 (recommended).
3. British or American spelling (design skill gap list, plan 02).
4. Keep "Ostrich **OS**" given the installer-not-distro reality and the ISO builder (plan 01), and a formal trademark search before wide release (not done).
5. Approval of the council session in plan 02 (agenda, five seats plus judge, evidence list) before anything runs.
6. Drop or keep `gemini` as an agent (plan 04).

## What was not verified

Marked in the plan text; none of it was run on a real kernel, VM or the live machine.

- Which `core_pattern` wins at runtime (derived from sysctl.d order in a container with a read-only sysctl), and that apport gets crashes after `systemd-coredump` is installed.
- That `raw.githubusercontent.com` follows a repo rename for the old installer URL (test after the rename, with wget).
- GNOME's per-app notification child naming and key set, and the GNOME 50 custom-keybinding path.
- Exact Canonical trademark wording (fragments from a page summary; re-read the page before the README text is final).
- Firefox profile-group sqlite filename and schema, snap Firefox flags.
- That a `GdkAppLaunchContext` from the drawer yields a token the shell accepts in every one of the six cases (the VM test with a negative control is the check).
- Whether `notify-send --action` works on GNOME 50 (the repo says no; upstream gives no reason).
- Opencode `--prompt` and Codex `codex "<prompt>"` invocations.
- Headless dark and 200 % text: tried several ways in the container, none worked; VM only.
- The name search covered GitHub, PyPI, npm, crates.io, Flathub, the Snap Store and the web, not trademark registers.
