# 02 — Setup wizard and Settings rebuild

Depends on `00-audit.md` (what exists) and `01-rename.md` (new names; this plan uses `ostrich` paths). UI work needs `05-design-skill.md` first.

## Spec (kept as written)

- One options schema `share/ostrich/options.json` (bash reads via `jq`, Python natively). Per option: `id`, `group`, `title` (≤5 words, sentence case), `summary` (one plain sentence: what changes on the computer), `detail` (optional, 2–3 sentences: why/tradeoff), `default`, `presets[]`, `module`, `detect` (hardware/software gate; hidden if absent), `requires_reboot`, `reversible`, `screenshot` (optional).
- First-run wizard: Python 3 + PyGObject + GTK4 + libadwaita. Pages: Welcome → Preset (Recommended / Minimal / Everything / Customize) → [Customize only] one page per group, ≤7 options each → Detected hardware (auto-filled with reasons) → Review (N changes, download size, reboot needed) → Install progress (bar + collapsible log) → Done ("change anything later in Ostrich Settings").
- The wizard writes `~/.config/ostrich/choices.json`; the installer runs non-interactively: `install.sh --choices FILE`. The same file = unattended install + CI fixtures.
- whiptail = fallback only when there is no `WAYLAND_DISPLAY`/`DISPLAY`, generated from the same schema.
- GUI never runs as root. Elevation handled separately (pkexec or one sudo) — mechanism proposed below.
- Settings app: same schema, AdwPreferences UI, search, current state, per-option apply (re-runs only that module; modules must be idempotent and revertible), "Reset to recommended", "Re-run setup".
- All user-facing copy lives in `options.json` only.

Versions verified in the `ubuntu:26.04` container (audit A3): `python3-gi 3.56.2`, `gir1.2-gtk-4.0 4.22.4`, `gir1.2-adw-1 1.9.1` (libadwaita 1.9), Python 3.14.4, `jq 1.8.1`, `whiptail` from `whiptail`/`newt` (stock).

## CONFLICTs with the repo

CONFLICT: "Python 3 + PyGObject" — the wizard **and** Settings already exist as one Rust binary, `ostrich-setup` (`tools/welcome`, gtk4-rs 0.11 / libadwaita-rs 0.9, 2.8k lines, 15 pages, hardware gating, live GSettings binding, speaker A/B test, drawer site manager, scheme editor). `docs/DESIGN.md` makes Rust the language for tools. A Python rewrite would duplicate all of it — RECOMMEND: keep Rust for the app; make the *schema* the shared artefact (it is language-neutral JSON, so the spec's goal holds). Use Python only where a Python-only decision is made later for small helpers (the picker and crash agent in plans 03/04 can be Rust or Python; see their notes). **Owner decision needed**; the rest of this plan is written to work either way, and code samples below are language-neutral.

CONFLICT: "installer runs non-interactively with `--choices FILE`; wizard runs *before* install" — today the order is reversed by design: `install.sh` installs the base without prompts, the wizard runs at the first login and changes settings **live through GSettings** (no module is involved). Only a minority of options are install-time (packages, hardware modules). — RECOMMEND: two option kinds in one schema: `"kind": "install"` (module-backed: packages, GPU/power/touchscreen modules, Dell) and `"kind": "setting"` (a GSettings key or config file, applied live). `choices.json` holds both; `install.sh --choices` consumes the `install` kind, the app applies `setting` kind itself. The "wizard before installer" flow then needs the one-liner to be able to start a GUI: see **Flow** below.

CONFLICT: "`module` per option" and "per-option apply re-runs only that module" — modules have no per-module revert and most settings have **no module at all** (audit A1) — RECOMMEND: add a `target` object instead of the single `module` string: `{"module": "hardware/power"}` or `{"gsettings": {"schema": "...", "key": "..."}}` or `{"file": "…"}`. Add `revert` to every module (below).

CONFLICT: "title ≤5 words", "≤7 options per page", "every option = title + one sentence" — existing pages break these (Top bar 18 rows, Windows 12, Dock 9; six titles over five words, audit A1) — RECOMMEND: one-time copy pass (plan 05 copy review) and split the big pages into groups of ≤7 as part of this task.

CONFLICT: "AdwPreferences UI" — the current Settings is a sidebar plus stack of `PreferencesGroup`s in custom `adw::*Row` code — RECOMMEND: keep it; render rows from the schema so each row type (switch, combo, spin, action) maps to the stock Adw row. Custom pages (theme cards, speakers A/B test, drawer sites, environments) stay hand-built and are listed in the schema as `"type": "custom", "page": "speakers"` so search and the review page still know about them.

## Schema: `share/ostrich/options.json`

Installed to `/usr/share/ostrich/options.json` (read-only, root-owned copy used by privileged helpers) and embedded in the Rust binary with `include_str!` (single source; a build check asserts they are identical).

```jsonc
{
  "schema_version": 1,
  "presets": { "recommended": {}, "minimal": {}, "everything": {} },   // preset id -> display copy only
  "groups": [ { "id": "look", "title": "Look and feel", "order": 1 } ],
  "options": [
    {
      "id": "dock.autohide",
      "kind": "setting",                       // setting | install
      "group": "dock",
      "type": "switch",                        // switch | choice | number | action | custom
      "title": "Hide the dock",                // <=5 words, sentence case
      "summary": "The dock slides away until you push the pointer to the bottom edge.",
      "detail": "Frees the screen bottom. Turn off if you often miss the dock.",   // optional
      "default": true,
      "presets": { "recommended": true, "minimal": true, "everything": true },
      "target": { "gsettings": { "schema": "org.gnome.shell.extensions.ostrich.dock", "key": "autohide" } },
      "detect": null,                          // null = always shown; else see below
      "requires_reboot": false,                // or "logout"
      "reversible": true,
      "download_mb": 0,
      "screenshot": null
    }
  ]
}
```

`detect` (hidden when absent or false): `{"hardware": "hybrid_graphics|touchscreen|battery|sound|dell"}` (existing `Hardware::detect` names, plus `dell` from `/sys/class/dmi/id/sys_vendor`) or `{"software": "cmd:firefox"}`, `{"software": "pkg:gdb"}`. A `reason` template ("Found an NVIDIA GPU next to the Intel one") is generated by the detector and shown on the *Detected hardware* page; copy for it lives in the schema (`detect_reason`).

Rules enforced by a lint (`tests/options-lint.sh`, runs in CI): ids unique; title ≤5 words, sentence case, no trailing full stop; summary exactly one sentence, ≤140 chars, no banned jargon (list in plan 05); every `install` option's `target.module` exists and has `revert`; every `setting` option's GSettings key exists in the extension schemas (`gsettings list-keys`); preset values type-check against `type`/`default`; ≤7 options per `group`.

CI also compares keys: every user-visible GSettings key either has an option or is listed in `schema/hidden.json` with a reason (stops drift).

### How bash reads it

```bash
jq -r '.options[] | select(.kind=="install" and .target.module==$m) | .id' --arg m core options.json
```

`lib/options.sh` wraps `jq` (installed by the base `core` module; `jq 1.8.1` in the archive). If `jq` is missing, `install.sh` installs it before reading choices. Choices are validated against the schema before anything runs; unknown ids are an error, never silently ignored.

## `choices.json`

```json
{ "schema_version": 1, "preset": "recommended", "choices": { "dock.autohide": true, "dev.tools": false } }
```

Written to `~/.config/ostrich/choices.json` (mode 0600, atomic write). Only ids that differ from the chosen preset are strictly required, but the wizard writes all so the file is self-contained for CI. Fixtures: `tests/fixtures/choices/{recommended,minimal,everything,hybrid-laptop}.json`.

`install.sh --choices FILE` runs with no prompts (implies `--yes` and `--keep` unless `choose_mode`'s answer is in the file as `"extensions_mode": "keep|clean"`, which replaces the existing Bash prompt). `--dry-run` prints the exact list of changes and download size (this is the Review page's data source: Review runs `install.sh --choices FILE --dry-run --json`).

## Flow (resolving the order conflict)

1. **Terminal one-liner (unchanged):** installs prerequisites and the *base* (core, tools, extensions, wizard binary) with the current sudo prompts and no choices. Ends by opening the wizard if a GUI session exists (`ostrich-setup --first-run`), else by running the whiptail fallback.
2. **Wizard (GUI, user):** pages below. At Review it shows N changes, download size and "log out needed".
3. **Apply:** the wizard saves `choices.json`, then runs `ostrich apply --choices FILE` as the same user in a child process; progress comes from `--json-progress` lines on stdout (one JSON object per step: `{"step":"hardware/power","state":"start|done|error","message":"…"}`). The log pane tails `~/.local/state/ostrich/install.log`.
4. **Elevation:** see below.

### Elevation proposal (GUI never root)

Principle: root work is already done by **one-shot polkit helpers** (`/usr/libexec/ostrich/system-helper`, one action per command; DESIGN principle 6). Extend that instead of adding `sudo` to a GUI.

- New polkit actions `org.ostrich.system-helper.packages` (apt/Flatpak system installs) and `org.ostrich.system-helper.module` (run a root part of a module). Authentication `auth_admin_keep`, so the Review→Install run asks **once**.
- The helper never takes package names or commands from the caller. It receives `--option-id` values only, and reads the **root-owned** `/usr/share/ostrich/options.json` to look up the allowed package list or module root-step for each id. A user-writable `choices.json` therefore cannot make root install arbitrary packages.
- Modules split into `install_user` (no root) and `install_root` (executed by the helper). The existing `lib/helper.sh` `sudo_install` stays for the terminal bootstrap only.
- Fallback when no polkit agent is running (SSH, container, `--choices` in CI): the CLI uses `sudo` **once** at the start (`sudo -v`, then keep-alive) and says so on the first line; this is the "one sudo" alternative from the spec, used only where pkexec cannot show a dialog.

Rejected: running the whole wizard under pkexec (GTK as root breaks theming, dconf and the "never root" rule); a resident daemon (violates principle 1).

CONFLICT: the repo rule "Never run `sudo`" is for the assistant on the dev machine, not for the installer's own design — RECOMMEND: no change; the CLI fallback above is what the installer ships for users.

## Wizard pages

Python/Rust-neutral; labels come from the schema. Window is one `AdwWindow` with an `AdwNavigationView` (stock) and a Back / primary-action button pair. One primary action per page.

| Page | Content | Primary action |
|---|---|---|
| Welcome | What Ostrich OS is, "for Ubuntu 26.04 LTS" (trademark wording, plan 01) | Continue |
| Preset | Recommended (selected) / Minimal / Everything / Customize, one-sentence each | Continue |
| Group pages (Customize only) | one page per group from `groups[]`, ≤7 options; row = switch/combo/spin with title + summary; "Learn more" expands `detail`; optional screenshot | Next |
| Detected hardware | auto-filled switches with the *reason* subtitle (e.g. "Found: NVIDIA RTX A2000 + Intel graphics"); user can untick | Continue |
| Review | "N changes · 340 MB download · log out needed"; expandable list grouped by group; nothing hidden | Install |
| Install progress | `AdwProgressBar` or `GtkProgressBar` + collapsed `AdwExpanderRow` with the log; Cancel only between steps | (none; Cancel is secondary) |
| Done | "Change anything later in Ostrich Settings"; if log out needed: **Log out now** (primary) / Later | Done |

Preset behaviour: selecting a preset sets every option to `presets[preset]`; *Customize* starts from Recommended. Options with a `detect` that fails are never offered and never written to `choices.json`.

## whiptail fallback

`lib/prompts.sh` gains `prompt_from_schema` that builds `whiptail --checklist` pages per group (≤7 items, title as tag, summary as description line, truncated to 70 columns by the generator, full text in `--yesno` help) from the same JSON with `jq`. Used only if `has_gui_session` is false and stdin is a TTY; otherwise `--choices` or the Recommended preset is used. Output = the same `choices.json`. Test with `script` in the Docker image.

## Settings app

- Same binary, no flag. Pages built from `groups[]`; rows from `options[]`; hand-built pages for `type: custom`.
- **Current state:** each row reads its live value (GSettings, config file, or a module `status` verb: `0` = on, `1` = off, `2` = not applicable).
- **Search (Ctrl+F):** over `title`, `summary`, `detail` and group names; results link to the row (the existing `win.goto`).
- **Per-option apply:** `setting` kind applies live as today. `install` kind: toggling shows an inline "Apply" banner button on that row; apply runs `ostrich apply --only <option-id>` which runs that module's `install_user`, and if needed one polkit-authenticated `install_root`. Undo is the same call with `--revert`.
- **Reset to recommended:** per page and global; shows the Review list first ("12 settings will change"), then applies the Recommended preset. Never resets user data (sites, schemes, environments).
- **Re-run setup:** reopens the wizard with the current state preselected (preset = Customize).

### Module contract (new `lib/module.sh` verbs)

Each `modules/<m>/install.sh` supports: `status`, `install` (existing), `revert`, all idempotent, all `--dry-run`, all logging. `revert` rules: restores from the module's own restore-point entries (`lib/backup.sh` already records them); removes only what the module added; packages are not removed unless the option's `remove_packages: true` (default false, because other apps may need them); hardware modules no-op when detection fails. The audit table in `00-audit.md` is the work list: every module except `dell` needs `revert`.

## Files to touch

`share/ostrich/options.json` (new), `lib/options.sh` (new), `lib/prompts.sh`, `install.sh` (`--choices`, `--json-progress`, `--only`, `--revert`), `lib/module.sh`, every `modules/*/install.sh` (`status`, `revert`), `modules/hardware/org.ostrich.system-helper.policy`, `tools/system-helper/src/` (new actions), `tools/welcome/src/{lib.rs,main.rs}` (schema-driven rows, first-run flow), `tests/options-lint.sh`, `tests/options.bats`, `tests/fixtures/choices/*`, `docs/DESIGN.md`/`DECISIONS.md` (the language and order decisions).

## Done criteria

1. Schema lint passes; every existing user-visible key is in the schema or in `hidden.json`.
2. `install.sh --choices tests/fixtures/choices/recommended.json --dry-run` lists changes and exits 0 in Docker; two real runs are idempotent.
3. Every module has `status`, `install`, `revert`; install → revert → install leaves the machine as after the first install (bats + VM).
4. Wizard completes all pages with keyboard only; Review count equals `--dry-run --json` count.
5. No process the GUI starts runs as root (check `ps -o user` in the VM test); one password prompt for a full install with root steps.
6. Copy review (plan 05) passes on the whole file.

## Test method

Docker `ubuntu:26.04`: schema lint, `--choices` dry run and real run twice, whiptail generation (via `script`). VM (`tests/vm/`): wizard screenshots through the plan 05 loop, polkit prompt count with `tests/vm/polkit-test.sh`, install/revert round trips per module, hybrid-GPU and touchscreen fixtures. Never the live machine.
