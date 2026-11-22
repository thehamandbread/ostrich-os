# 00 — Audit (2026-11-21)

Read-only audit of the repo at `wip-ui` (dcac648, v0.5.0) plus container and web evidence. No code or config was changed. Raw container output is kept in `docs/plans/evidence/`.

## A1. The current setup prompt and "Ostrich Settings"

### What exists today (it is not what the task brief assumes)

| Piece | Reality |
|---|---|
| Install-time prompt | `install.sh` asks **one** question, `choose_mode()` (install.sh:249): "Keep them / Clean start", and only when other GNOME extensions are installed, on a TTY, not in `--dry-run`. Plain Bash `read`, no whiptail. Flags `--keep` / `--clean` skip it. |
| whiptail | `lib/prompts.sh` has `has_gui_session` and `ask_yes_no` only. Nothing in the installer calls them for choices. |
| Welcome wizard | `tools/welcome` → binary **`ostrich-setup`**, **Rust, gtk4-rs 0.11 + libadwaita-rs 0.9** (`Cargo.toml`: GTK 4.18 feature, libadwaita 1.8 feature), 2774 lines in `src/main.rs`. Autostarts on first login (`ostrich-setup --tour`), reopened from the app grid. |
| "Ostrich Settings" | **The same binary.** `--tour` is the wizard (steps in order); no flag = Settings (sidebar of pages, Ctrl+F search); `--step NAME` opens one page. Single window, second launch navigates the running one. |
| How a choice is applied | Rows are bound **directly to GSettings** (`switch_row`, `combo_row`, `spin_row`, `pin_row`) on each extension's schema `org.gnome.shell.extensions.ubuntu-ostrich.<ext>`. Changes apply live. **No module is re-run and there is no options file.** |
| Where choices persist | dconf (`/org/gnome/shell/extensions/ubuntu-ostrich/…`) plus `~/.config/ubuntu-ostrich/` (`drawer.toml`, `environments/`, `schemes/`, `scheme/`, `settings.dconf`). `home/run_onchange_after_ostrich-settings.sh.tmpl` loads `settings.dconf` through chezmoi. |
| Installer modules | `MODULES=(core dotfiles terminal tools gnome dev apps claude-code hardware/nvidia-optimus hardware/dell hardware/power hardware/touchscreen)`, run in order by `run_modules`. Each is `modules/<m>/install.sh` using `lib/module.sh`. Failure of one aborts the run (`die`). |

### Wizard / Settings pages, in order, with what each row does

Page list is `tools/welcome/src/lib.rs` (`ALL`); hardware pages are hidden by `Hardware::detect` (sysfs/udev). "Rows" are the option rows in `main.rs`; the count excludes action buttons and custom widgets.

| # | Page (`--step`) | Gate | Rows (GSettings key → label) | Module / change |
|---|---|---|---|---|
| 1 | What's included (`welcome`) | — | "Where things are" group (this page also holds the extension on/off helper `set_extension_enabled()`, which edits `org.gnome.shell enabled-extensions`) | No module |
| 2 | Theme (`theme`) | — | `color-scheme` "Appearance"; colour-scheme cards (`schemes.rs`, written by `ostrich theme scheme`); accent; "New scheme…" editor | `palette` tool writes `~/.config/gtk-{3,4}.0/gtk.css`, Ghostty theme, per-extension stylesheets in `~/.config/ubuntu-ostrich/scheme/` |
| 3 | Top bar (`top-bar`) | — | 7 pinned readouts (`cpu.usage`, `mem.usage`, `temp.average`, `temp.package`, `gpu.state`, `net.down`, `net.up`), `hide-zeros`, `section-rows`, `animation-speed`, `folder-colour`, `accent-follows-wallpaper`, `today-panel`, `show-events`, `now-playing-pill`, `quick-settings-corner`, `clock-menu-quiet`, `quick-settings-style` | monitor + tweaks extensions (GSettings only) |
| 4 | Dock (`dock`) | — | `autohide`, `intellihide`, `click-action`, `indicator`, `previews`, `badges`, `show-apps-at-start`, `icon-size`, `background`, `background-opacity` (10 rows; the earlier count of 9 missed the opacity spin row, visible in the headless screenshot in `02-tour-and-settings.md`) | dock extension |
| 5 | Workspaces and tiling (`windows`) | — | 12 rows (`dynamic-workspaces`, `num-workspaces`, `smart-names`, `show-empty`, `indicator-style`, `show-icons`, `active-style`, `drag-tiling`, `fill-popup`, `raise-together`, `window-gap`, `focus-hint`) | workspaces + tiling extensions |
| 6 | Blur (`blur`) | — | per-surface Blur/Solid rows with sigma/brightness spin rows, `high-contrast`, `lock-screen`, `static-on-battery-saver` | blur extension |
| 7 | Notifications (`notifications`) | — | `show-banners` | GNOME `org.gnome.desktop.notifications` |
| 8 | Ostrich Drawer (`drawer`) | — | `open-on-hover`, `hover-delay-ms`, `bar-max`, `position`, `width`, `height`, `hide-on-focus-loss`, site list (pin/add/remove), recommended sites | drawer extension + `ostrich-drawer` host (GApplication actions) |
| 9 | Focus mode (`focus`) | — | "allow" group, environments (saved workspaces) with per-env drawer sites, `restore-app-contents` | focus extension, `ostrich env` |
| 10 | Graphics (`graphics`) | hybrid GPU | Integrated / Hybrid / Discrete | `system-helper` via pkexec → `prime-select`; needs log-out |
| 11 | Power (`power`) | battery | power mode rows, `auto-saver-percent`, `saver-desktop`, `memory-warning`, calibration | `system-helper` power action; boot unit `ubuntu-ostrich-power.service` |
| 12 | Speakers (`speakers`) | sound card | presets, model correction, mic calibration, A/B test | `audio-tune` writes `~/.config/pipewire/pipewire.conf.d/` |
| 13 | Touchscreen (`touchscreen`) | touchscreen | on/off | `system-helper` unbind/rebind + udev rule |
| 14 | Apps (`apps`) | — | recommended apps list, GitHub-link install | Store (`store-core`), nothing pre-selected |
| 15 | All set (`finish`) | — | shortcut cheat sheet | removes autostart entry |

### Mismatches and gaps to fix

1. **Labels versus behaviour.** The audit found no option that does the opposite of its label. It found these wording problems:
   - **Too long (> 5 words, against the owner's target):** "Top-right corner opens quick settings", "Open a site by hovering over its icon", "Bring back what was open inside the apps", "Accent colour follows the wallpaper" (5, borderline), "Do Not Disturb and Focus in the clock menu", "Site icons in the top bar (the rest are in its ⌄ menu)".
   - **Unclear titles:** "Monitor menu size" (`section-rows`), "Wide sites: width (% of the screen)" and "Quick settings" (`quick-settings-style`) do not say what changes.
   - **Misleading state coupling:** `show-banners` is labelled "Show banners" with the summary "Off is the same as Do Not Disturb". That is accurate, but the page title is "Notifications" and it is the only row, so users read it as a notifications page; DND itself is elsewhere (clock menu).
   - **Unit in the title:** "Hover delay (milliseconds)", "Switch to power saver at (%)". HIG puts units in the control, not the title.
   - **Spelling:** the repo uses British "colour". GNOME HIG and libadwaita docs use American English. Decide once (see the design-skill gap list in `02-tour-and-settings.md`).
2. **Pages above ≤7 options** (owner's target, `02-tour-and-settings.md`): Top bar 18, Windows 12, Dock 10, Drawer 7 + lists, Power. These need grouping into sub-pages or collapsible groups.
3. **Modules with no revert path.** Every module is idempotent and backs up first (`lib/backup.sh` restore point), but **none has a per-module revert.** Revert is global only: `install.sh --uninstall` (`lib/uninstall.sh`) restores the whole restore point. Per module:

   | Module | Idempotent | Revert |
   |---|---|---|
   | core, terminal, dev, apps, claude-code | yes | none (packages stay unless `--remove-packages`); no per-module path |
   | dotfiles (chezmoi) | yes | restore point only |
   | tools (binaries, icons, polkit, `.desktop`) | yes | restore point only |
   | gnome (gsettings, extension enable) | yes | restore point only |
   | hardware/nvidia-optimus | yes ("Hybrid set once") | needs `prime-select` + restore point; log-out |
   | hardware/power | yes | boot unit removal only via uninstall |
   | hardware/touchscreen | yes | udev rule + state file removal only via uninstall |
   | hardware/dell | no-op | n/a |

   The earlier plan's idea of per-option module re-runs is dropped (see `02-tour-and-settings.md`): nearly every option is a GSettings key, not a module. If a module revert is wanted later, the table above is the work list.
4. No single copy source exists. Wording lives in Rust string literals (`tools/welcome/src/main.rs`), each extension's gschema `<summary>`, `docs/DESIGN.md`/`DEFAULTS.md`/`FEATURES.md` prose and `ostrich config help`. Plan 02 proposes `tools/welcome/data/copy.toml`.
5. **The installer needs no pre-install answers.** The only question `install.sh` asks is Keep/Clean for other extensions (`choose_mode`, install.sh:249), and it has flags. So no options file or choices file is needed (plan 02).

## A2. `rg -i "ubuntu.?ostrich"` — 699 matching lines, grouped

Counted with `rg -i "ubuntu.?ostrich"` excluding `node_modules`, `graphify-out`, `dist`, `.claude/worktrees`, `tools/target`. Variants found: `Ubuntu Ostrich` (111), `ubuntu-ostrich` (the large majority), `ubuntu_ostrich` (34), `ubuntuostrich` (14). **P = persisted on installed machines (needs migration).**

| Group | Identifiers | Where | P |
|---|---|---|---|
| User-visible strings | "Ubuntu Ostrich" in `install.sh` usage and prompts, `tools/ostrich/src/main.rs` (17 hits), `tools/welcome`, `tools/palette`, `tools/store-gtk`, READMEs, whiptail title, uninstall messages | many | no (rebuilt each release) |
| Project constants | `PROJECT="ubuntu-ostrich"`, `STATE_DIR=~/.local/state/ubuntu-ostrich`, `SRC_DIR=~/.local/share/ubuntu-ostrich/src`, `LOG_FILE=…/install.log` | `install.sh:11,22-24` | **P** |
| Config dir | `~/.config/ubuntu-ostrich/` (`drawer.toml`, `settings.dconf`, `schemes/`, `scheme/`, `environments/`, `palette.json`), `ghostty/themes/ubuntu-ostrich` | `home/dot_config/ubuntu-ostrich/`, `tools/ostrich/src/config.rs` | **P** |
| Data dir | `~/.local/share/ubuntu-ostrich/` (`src/`, `drawer/<service>/` **holds web logins and cookies**, VM images in dev) | `drawer-host`, `install.sh` | **P** (logins!) |
| State dir | `~/.local/state/ubuntu-ostrich/` (`backups/`, `install.log`, `source`) | `lib/backup.sh`, `lib/restore.sh` | **P** (restore points) |
| Binaries / libexec | `~/.local/libexec/ubuntu-ostrich/{ostrich-setup,ostrich-store-gtk,ostrich-drawer}`, `/usr/libexec/ubuntu-ostrich/system-helper` (root) | `modules/tools`, `lib/helper.sh` | **P** |
| CLI | `ostrich` (no "ubuntu"), `ostrich-setup`, `ostrich-drawer`, `ostrich-store-*`, `ostrich-icon-style` | `tools/*/Cargo.toml` | no name change needed |
| systemd units | `ubuntu-ostrich-power.service` (system), `ostrich-store-updates.{service,timer}` (user) | `modules/hardware/power`, `tools/store-*` | **P** (power unit is root-owned) |
| Polkit | `org.ubuntu-ostrich.system-helper.{graphics,touchscreen,power}` in `modules/hardware/org.ubuntu-ostrich.system-helper.policy` → `/usr/share/polkit-1/actions/` | `lib/helper.sh` | **P** (root) |
| udev / state | `/etc/udev/rules.d/90-ubuntu-ostrich-touchscreen.rules`, `/var/lib/ubuntu-ostrich/touchscreen.state`, `/run/ubuntu-ostrich` | `modules/hardware/touchscreen` | **P** (root) |
| gsettings schema IDs | `org.gnome.shell.extensions.ubuntu-ostrich.{blur,dock,drawer,focus,monitor,tiling,tweaks,workspaces}` (8 gschema.xml; `…-dev.critique` is test-only) | `modules/gnome/extensions/*/schemas/` | **P** (every user's dconf under `/org/gnome/shell/extensions/ubuntu-ostrich/<ext>/`) |
| Extension UUIDs | `<name>@ubuntu-ostrich` × 11 (`blur dock drawer focus holder-monitor monitor search-new-window tiling tray tweaks workspaces`) in `metadata.json`, `~/.local/share/gnome-shell/extensions/<uuid>`, `org.gnome.shell enabled-extensions`, zip name `<uuid>.shell-extension.zip` | `modules/gnome/extensions/*/metadata.json`, `lib/*`, `docs/DESIGN.md` | **P** |
| D-Bus / app IDs | GApplication `ubuntu_ostrich.drawer` (**underscore**, since 2026-10-31 for the portal's dash rule; `tools/drawer-host/src/main.rs:45`), path `/ubuntu_ostrich/drawer`, per-site `ubuntu_ostrich.drawer.<service>` (`service_app_id`, main.rs:128; notification attribution and generated `.desktop` files in `~/.local/share/applications/`), `ubuntu_ostrich.{store,setup,drawer}.desktop`. `docs/DESIGN.md` still shows the dash form (see A6) | `tools/drawer-host`, `tools/store-gtk`, `tools/welcome`, `modules/tools/install.sh:146`, `lib/uninstall.sh:195` | **P** (desktop files; GNOME's per-app notification children are keyed by these ids) |
| GNOME per-app notification settings | children of `org.gnome.desktop.notifications.application` whose `application-id` is `ubuntu_ostrich.drawer.<service>.desktop` etc. | GNOME's dconf, not ours | **P** (a new app id starts a new, empty child; plan 01 migrates them) |
| Earlier slugs | `cleanest-ubuntu-setup`, `ostrich-ubuntu` (renamed 2026-10-20 and 10-21): the installer disables extensions under those UUID suffixes (`modules/gnome/install.sh:32`) and `tests/modules.bats:141-142` checks it; no directory or settings migration exists for them | `docs/DECISIONS.md` 2026-10-20/21 | only on pre-0.4.0 private builds (owner's machines, VM snapshots) |
| Autostart | `ostrich-setup.desktop` (autostart), `ostrich-firstboot.desktop` (image) | `modules/tools`, `image/firstboot` | **P** until wizard done |
| chezmoi source | `home/dot_config/ubuntu-ostrich/`, `home/run_onchange_after_ostrich-settings.sh.tmpl` (path `~/.config/ubuntu-ostrich/settings.dconf`) | `home/` | **P** (chezmoi state records source paths) |
| Image / ISO | `/opt/ubuntu-ostrich`, `/usr/local/sbin/ubuntu-ostrich-portable-esp`, `/opt/ubuntu-ostrich/release` | `image/` | P on built images only |
| URLs | `https://github.com/thehamandbread/ubuntu-ostrich` (README, `metadata.json` `url` × 11, About text), `https://raw.githubusercontent.com/thehamandbread/ubuntu-ostrich/main/install.sh` (README, `tools/ostrich/src/main.rs:142`, `docs/INSTALLING.md`), `https://api.github.com/repos/$REPO_SLUG/releases/latest` (`install.sh:122`, `tools/store-core/src/github.rs:201`), release assets `…/releases/download/vX/<uuid>.shell-extension.zip`, `SHA256SUMS`, tools tarball | `install.sh`, `tools/`, `docs/`, `.github/workflows/release.yml` | **P**: already-installed 0.5.0 binaries carry the old slug and old API URL |
| CI | `ci.yml` (docker tag `ubuntu-ostrich-test`, lint paths), `release.yml` (asset names), `.github/` | `.github/workflows/` | no |
| Tests / dev | `tests/**` (VM paths `~/.local/share/ubuntu-ostrich/vm`, `ubuntu-ostrich-test`, `ubuntu-ostrich-lint`), `spikes/*/…@ubuntu-ostrich/` | `tests/`, `spikes/` | dev only |
| Docs | `docs/DESIGN.md`, `DECISIONS.md`, `DEFAULTS.md`, `INSTALLING.md`, `docs/council/*` (historical; do not rewrite) | `docs/` | no |

Highest-risk persisted items: **dconf paths and schema IDs** (settings loss), **extension UUIDs** (extensions vanish), **drawer data dir** (logins), **polkit action IDs / root helper path** (privileged features break), **state dir restore points** (uninstall stops working), **API URL baked into old binaries** (updates stop).

## A3. Container evidence (fresh `ubuntu:26.04`, 26.04.1 LTS)

Full output: `docs/plans/evidence/a3-container-output.txt` and `a3b-apport-handler-output.txt`. Excerpts below are verbatim.

```
$ dpkg -l apport systemd-coredump whoopsie
dpkg-query: no packages found matching apport
dpkg-query: no packages found matching systemd-coredump
dpkg-query: no packages found matching whoopsie

$ apt-cache policy systemd-coredump
systemd-coredump:
  Installed: (none)
  Candidate: 259.9-0ubuntu0.1
  Version table:
     259.9-0ubuntu0.1 500  http://archive.ubuntu.com/ubuntu resolute-updates/universe amd64 Packages
     259.5-0ubuntu3.4 500  http://security.ubuntu.com/ubuntu resolute-security/universe amd64 Packages
     259.5-0ubuntu3 500    http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages
```

(Container is minimal, so apport/whoopsie are absent; a desktop install has them. `systemd-coredump` is in **universe**.)

```
$ ls /usr/lib/sysctl.d/ /etc/sysctl.d/   # before installing anything
/etc/sysctl.d/: README.sysctl
/usr/lib/sysctl.d/: 55-bufferbloat.conf 55-console-messages.conf 55-ipv6-privacy.conf
  55-kernel-hardening.conf 55-magic-sysrq.conf 55-map-count.conf 55-network-security.conf
  55-ptrace.conf 55-zeropage.conf
$ grep -rn core_pattern /usr/lib/sysctl.d /etc/sysctl.d
(no match)
```

So stock Ubuntu ships **no `kernel.core_pattern` in sysctl.d**. The handler sets it at runtime: `apport-core-dump-handler` contains only `/usr/lib/systemd/system/apport.service` and `/etc/init.d/apport` (no sysctl file). Confirmed in a second run with the package installed: `grep -rn core_pattern /usr/lib/sysctl.d /etc/sysctl.d /usr/lib/systemd` found nothing, so the pattern is written by the service at boot, not by sysctl.d.

```
$ apt-cache policy gir1.2-gtk-4.0 gir1.2-adw-1 libnotify-bin jq gh gdb debuginfod xdg-terminal-exec gitleaks   # Candidate lines
gir1.2-gtk-4.0      4.22.4+ds-0ubuntu0.2
gir1.2-adw-1        1.9.1-0ubuntu0.2
libnotify-bin       0.8.8-1
jq                  1.8.1-4ubuntu2
gh                  2.46.0-4          (old: Ubuntu archive lags upstream)
gdb                 17.1-2ubuntu1
debuginfod          0.194-4
xdg-terminal-exec   0.14.0-1ubuntu0.1
gitleaks            8.16.0-1build2    (old: CLI differs from 8.19+, see plan 04)
```

All nine are installable from the archive, so no third-party download is needed (the tools are Rust; GTK 4.22 and libadwaita 1.9 match `tools/welcome`'s dependencies).

```
$ notify-send --version
notify-send 0.8.8
$ notify-send --help      # relevant lines
  -w, --wait                        Wait for the notification to be closed before exiting.
  -A, --action=[NAME=]Text...       Specifies the actions to display to the user. Implies --wait to wait for user input. May be set multiple times. The name of the action is output to stdout. ...
  --selected-action-fd              File descriptor where to write the action chosen by the user.
  --activation-token-fd             File descriptor where to write the action activation token. The daemon must support it.
```

`--action` and `--wait` are supported by the binary. **But** `CONTEXT.md` (2026-11-18) records that on GNOME 50 `notify-send` drops actions and the Store notifies over D-Bus instead; the repo already sends notifications through `org.gtk.Notifications.AddNotification` (`tools/drawer-host/src/main.rs:615`). Plan 04 follows the repo, not `notify-send`.

```
$ apt-get install -s systemd-coredump        # with apport + apport-core-dump-handler installed
Remv apport-core-dump-handler [2.34.1-0ubuntu0.1] [apport:amd64 ]
Inst systemd-coredump (259.9-0ubuntu0.1 Ubuntu:26.04/resolute-updates [amd64])
$ dpkg -s systemd-coredump | grep Conflicts
Conflicts: core-dump-handler            # apport-core-dump-handler, corekeeper, minicoredumper
$ ls /usr/lib/sysctl.d/   # after install
10-coredump-debian.conf  50-coredump.conf  50-default.conf  50-pid-max.conf  55-*.conf ...
$ grep -rn core_pattern /usr/lib/sysctl.d /etc/sysctl.d
/usr/lib/sysctl.d/10-coredump-debian.conf:1:kernel.core_pattern=core
/usr/lib/sysctl.d/50-coredump.conf:16:kernel.core_pattern=|/usr/lib/systemd/systemd-coredump %P %u %g %s %t %c %h %d %F
```

**Which file wins:** `sysctl --system` applies files in lexical order of base name across `/etc`, `/run`, `/usr/lib`; later wins. `50-coredump.conf` sorts after `10-coredump-debian.conf`, so **`systemd-coredump`'s pattern (`|/usr/lib/systemd/systemd-coredump …`) wins**. `10-coredump-debian.conf` is the Debian "plain `core`" default for when no handler is installed. This container's sysctl cannot be applied (read-only), so this is derived from file order and systemd's documented rule, not observed on a live kernel. Verify in the VM (plan 04 test).

**Does apport still get crashes?** Yes, by a different route. With `systemd-coredump` as the kernel handler, the `apport` package ships:

```
/usr/lib/systemd/system/systemd-coredump@.service.d/apport-coredump-hook.conf
    [Unit]
    OnSuccess=apport-coredump-hook@%i.service
/usr/lib/systemd/system/apport-coredump-hook@.service
    ExecStart=/usr/share/apport/apport --from-systemd-coredump %i      # writes /var/crash/*.crash
```

This is the apport ≥ 2.28 integration (Launchpad #2048136, Fix Released: "support systemd-coredump as core dump handler"). Caveats found by the web check: installing `systemd-coredump` **removes** `apport-core-dump-handler` (apt would remove it, shown above), and Launchpad #2139266 (Jan 2026) reports the hook needing `python3-systemd` on 26.04 with apport 2.33.1; the container has apport 2.34.1, whose status for that bug is unverified. **Not proven end to end** (no kernel crash was produced in a container). Plan 04 therefore keeps apport as the default and gates the advanced option on a VM test.

## A4. Omarchy browser-picker prior art

- `basecamp/omarchy` now redirects to `omacom/omarchy`, **MIT**, default branch `quattro`. Fork `seanpk/omarchy` is MIT (Shell).
- **No browser-picker or `all-fixes` branch found** in `seanpk/omarchy` (branches: `quattro`, `feat/machine-local-overlays`, `feat/plugin-post-enable`, `fix/restart-app-oneshot-cgroup`, `fix/webapp-startup-wmclass`). Its PRs are unrelated (#11872, #11487, #9807, #9621). Other forks were not searched. The branch may be private, deleted or named differently.
- Closest upstream work: **PR #9679** "Add browser profile picker to web app setup" (cbullard, open): Bash, edits `bin/omarchy-webapp-install`; reads Chromium-family profile state and writes `--profile-directory` into the generated `.desktop` launcher; picker only when several profiles exist. This is an install-time launcher generator, not a runtime picker. Also #13664 (own Chromium profile per web app) and a mention of #6105 (profile-aware runtime on the old `dev` branch, not opened).
- Nothing copied. Plan 03 designs from the spec; if any Omarchy code is later reused, keep the MIT notice.

## A5. Name check: "Ostrich OS"

| Place | Result |
|---|---|
| GitHub `thehamandbread/ostrich-os` | free (not found) |
| GitHub repos named `ostrich-os` / `ostrichos` | none; "ostrich" hits are unrelated (a Scala stats lib, an SMT solver, OstrichDB, a font, an optimisation toolkit, a Game Boy sound player, a CDN cache server, a Nostr job board) |
| Flathub | 0 results for "ostrich" |
| Snap Store | 0 results via the API (empty response, moderate confidence) |
| PyPI `ostrich-os`, `ostrichos` | 404 (free) |
| npm / crates.io `ostrich-os`, `ostrichos` | 404 (free) |
| Web | one "OstrichOS" Google Sites page (self-published; "simple, fast system for business and education"; unclear if Linux): https://sites.google.com/view/ostrichos |

**Collisions:** one minor, no registry or distro collision. `OstrichDB` is a different product with a nearby name. A formal trademark search (USPTO/EUIPO/WIPO) was **not** done and is recommended before wide release.

## A6. Drawer doc drift (docs disagree with each other or with the code)

Found while auditing the drawer for plan 03. Each has a proposed fix; none is applied here (docs-only task, and the owner chooses the hover value).

| # | Drift | Where | Which is right | Proposed fix |
|---|---|---|---|---|
| 1 | **Loaded dot.** `docs/FEATURES.md` DRW-1 and `docs/DESIGN.md:100` say the icon "has a dot while loaded"; `docs/DECISIONS.md` 2026-11-19 says the white "loaded" dot is gone and an unloaded icon is grey, nothing else. (`docs/DECISIONS.md` line 84, 2026-10-22, also says "loaded dot": superseded history.) | FEATURES.md:173, DESIGN.md:100 | DECISIONS 2026-11-19 (later, the owner's call; `CONTEXT.md` agrees) | Reword DRW-1 to "greyed while unloaded; no dot" and DESIGN.md:100 the same. Add a drawer-test assertion that no loaded-dot actor exists (the test comment at `tests/vm/drawer-test.sh:687` mentions a different "dot"; check it is not this). |
| 2 | **Hover delay.** `docs/DESIGN.md:101`, FEATURES DRW-2 and DECISIONS 2026-10-22 say hover opens after **300 ms**; the gschema default of `hover-delay-ms` is **500** (`modules/gnome/extensions/drawer/schemas/…drawer.gschema.xml`, range 100-2000) and `docs/council/2026-10-24-round-2-and-whole-os.md:138` already says to correct "stale 0.3 s" to 500 ms. The fold-back delay is 500 ms in code (`HOVER_CLOSE_MS`, `barlogic.js:6`), matching the docs. | DESIGN.md:101, FEATURES.md:174, DECISIONS 2026-10-22 | The gschema (the code, and a council note that says 500) | Pick **500** in the docs (owner confirms); update DESIGN.md:101 and DRW-2 to "hover 500 ms (setting `hover-delay-ms`)"; leave the dated DECISIONS entry and append a note instead of editing history. If the owner prefers 300, change the gschema default and the test instead. |
| 3 | **Per-site sizes.** DECISIONS 2026-11-19 removed per-site narrow/wide shapes and saved sizes from the shell ("the host still reads them from drawer.toml and ignores them"), but the host still defines `set-size((suu))` (`tools/drawer-host/src/main.rs:16,1762`), `shape`/`width` in `drawer.toml` (`config.rs:13-14,34-36,79`), and `docs/DESIGN.md:97,121` still list "shape, saved size" and `set-size`. | main.rs, config.rs, DESIGN.md:97,121 | The decision (the shell ignores them) | Remove `set-size` and per-site shape/size from the host after confirming nothing calls them (`git grep set-size` finds only the host; the extension has none); keep parsing old `drawer.toml` keys tolerantly (ignore unknown), and drop them from DESIGN.md. A separate small task in the README build order. |
| 4 | **Dash form of the app id.** `docs/DESIGN.md` (drawer section, notifications and D-Bus lines, around :112 and :121) still names `ubuntu-ostrich.drawer`, `ubuntu-ostrich.drawer.<service>` and "GApplication actions on `ubuntu-ostrich.drawer`", while the code uses `ubuntu_ostrich.drawer` since 2026-10-31 (main.rs:45) and the path `/ubuntu_ostrich/drawer`. The same dash/underscore trap is exactly what the portal crash was. | DESIGN.md | The code | Fix the doc now (it will be rewritten for `ostrich_os` by the rename anyway; do the doc fix inside that task so it is edited once). |
