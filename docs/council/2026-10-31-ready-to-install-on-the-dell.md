# Verdict: is Ubuntu Ostrich ready to install on the owner's Dell?

## Summary

**Conditional GO.** No seat called no-go, and I agree. The tests show the default install and uninstall round trip is clean (tests.md #3), the restore point is real on a normal account (#14, 2012 bytes), nothing polls outside `PowerAwareTimer` (#27), and the saver desktop heals itself (#28). The conditions are what the tests turned up:

- **The tools-build trap (#1, #2).** A real install from this checkout would download the 0.1.4 tools or die halfway. I found one more problem that every seat missed: the fix they all gave, "run `tests/vm/build-tools.sh --check`", does not fix it on its own (Ruling 2).
- **Four places where uninstall or Classic loses data or does damage**, each reproduced in the lab: #8, #9, #10 and #3b.
- **GNOME's own High contrast setting makes our banners unreadable** (#11: 1.71:1).

Eight small items fix these, all bash, a few lines of Rust and one JS function. After them comes one round trip on the final commit. Then install, by the route in "How to install safely".

One thing no seat raised: `docs/DESIGN.md:301` and `docs/DECISIONS.md:36` say the live machine is set up only after the build passes **both** the VM and the external-SSD tests. The SSD stage has not been done. My ruling is go for the SSD now. Going straight to the internal disk needs the owner to waive that rule, and only the owner can (Question 1).

## Rulings

**R1. Go or no-go, and where.**
- The sides: nine seats said conditional go. Access, security and simplicity said go with precautions.
- Ruling: go once the must tier is done and the gate below is green. The first hardware run goes on the external SSD, as `DESIGN.md:324-328` describes. The internal disk follows the SSD hour, or follows the owner's explicit waiver.
- Why: the SSD gives the same hardware answers (NVIDIA, battery, speakers, touchscreen) without risking the owner's only machine. Skipping it changes a written project rule, so it is a question for the owner, not a ruling.

**R2. Is "run `build-tools.sh --check` first" enough? No.**
- The sides: all twelve seats gave that as the fix for the stale build.
- What they missed: `tests/vm/build-tools.sh:4,16` copies the binaries to `$VM_DIR/tools-bin`. The installer looks in `$REPO/tools/target/release` (`modules/tools/install.sh:21`). Running the script leaves `have_build` false, and the installer still goes to `fetch_release`.
- Ruling: install with `BUILD_DIR="$HOME/.local/share/ubuntu-ostrich/vm/tools-bin"`. `BUILD_DIR` is already an override at `:21`, and e2e uses the same binaries. Must item 1 also turns the silent fallback into a stop that tells you this.

**R3. Root-path allowlist: must or should?**
- The sides: quality and owner said should, because exploiting it needs same-uid malware and the sudo password. Security and maintainer said must.
- Ruling: **must**.
- Why: test #9 deleted a root-owned canary. The fix is one function and one bats case. Uninstall is the owner's safety net, and a safety net that runs `sudo rm` on a list any user process can edit is not finished.

**R4. Empty `dconf.ini`: a `[[ -s ]]` guard or a marker?**
- Ruling: the marker, plus failing the install when the dump fails. The `[[ -s ]]` guard is rejected.
- Why: facts D1 shows an empty dump can be legitimate, so the size guard would block a valid uninstall. The marker matches the one dangerous case exactly. #14 shows the risk is low on the Dell, but the bad case wipes every setting, and the fix is about six lines.

**R5. Classic deleting `gtk.css`: fix it, or tell the owner not to use Classic?**
- Ruling: **fix it**.
- Why: the owner asked for colour schemes, and Classic is the way back out of one. A "don't use the way back" rule is not acceptable for a headline feature.
- A warning for the clerk: as I read the current code, it should keep the user's line. `restore_before` takes only our block out (`tools/palette/src/main.rs:325-337`, `output.rs:114-122`). Yet #10 lost the line. The cause lies on a path the read didn't find, so write a failing test of #10's exact sequence before touching code.

**R6. High contrast: must or should?**
- The sides: access, design, newcomer and security said must. Quality, owner and maintainer said should.
- Ruling: **must this round, but not an install gate.**
- Why: #11 is a proven readability failure in shipped code (6.10:1 falls to 1.71:1), and the fix reuses the existing solid mode. The owner doesn't use High contrast, so if this slips, the day-one note "leave GNOME High contrast off" covers the Dell.

**R7. Should Messages and Chat stay loaded (keep-alive) by default?**
- The sides: lowend, simplicity and mobile wanted it off or tied to RAM. The owner wanted it kept, and claimed there is no switch in the GUI.
- On the switch: the owner's grep covered only `tools/welcome`. A per-site "Keep loaded in the background (about N MB)" switch already exists in the drawer icon's right-click menu (`modules/gnome/extensions/drawer/bar.js:126`). The Settings Drawer page lacks one.
- Ruling: **should.** When the default `drawer.toml` is first created, keep-alive for Messages and Chat is on only if `MemTotal` is 12 GB or more. Add the switch to the Drawer page.
- Why: #4 proved 505 MB `mem_used`. A 5570 has 16 GB or more, so the owner's setup doesn't change, and it is not a gate.
- Condition (from design): re-shoot the unloaded drawer bar first. #23's shot was covered by the portal dialog.

**R8. Saver turning "never blank" (`idle-delay 0`) into 120 s.**
- The sides: owner and mobile wanted 0 respected. The current behaviour is deliberate: `tests/js/monitor-battery.test.js:33` asserts 0 becomes 120.
- Ruling: **respect 0 (should).** An explicit "never" is the user's choice, not a default, and shortening a finite delay still saves the power.
- Until then, the day-one note is to switch `saver-desktop` off.

**R9. A media player on a fresh install.**
- The sides: everyday wanted Showtime preinstalled. Simplicity and owner opposed preinstalling. Newcomer wanted a player first in "Start here".
- Ruling: no preinstall. VLC goes into "Start here".
- Why: #18 proved a Flathub VLC becomes the default for mp4 **and** mp3 by registration alone. Showtime would cover mp4 only. Tests #19 and #18 also rule out `-ugly` and any default-setting code in the Store.

**R10. Hide GNOME Settings behind Ostrich Settings?** Rejected. #6 proved Users, Printers and Accessibility would have no visible route. Simplicity withdrew it.

**R11. Dash to Dock settings are not carried over.**
- Ruling: correct the docs now (must 8). The migration itself is should.
- Why: `DEFAULTS.md:19,46` promise something the installer doesn't do (facts #9). That is a cheap truth fix. The migration is 30 lines nobody needs on day one.

**R12. The now-playing pill.** Keep it, off by default. Decide after E1 on the Dell. The maintainer withdrew the cut, and #27 found no polls.

**R13. Banners forced on.** They stay on, as decided in `DESIGN.md:264`. The owner turns them off in Settings. Changing the design default is the owner's call (Question 5).

**R14. CLI defects without a terminal** (#30: `store --help` exits 101, `theme --help` exits 2, `theme scheme list` prints ANSI escapes). Should. Nothing on day one pipes them.

**R15. NavigationAction policy, GitHub-dialog wording, the `.deb` temp copy, dock private-field guards, extension merges, the single blur slider.** Not now. Each touches tested code for a low or future harm, and every seat that raised them deferred them.

## Scorecard

Weights: Reach ×3, Impact ×3, Cost ×2 (5 = cheapest), Risk ×2 (5 = safest), Effort ×1 (5 = least), Evidence ×2. Maximum 65. The tier is set by "does it gate the install", not by score alone. That is why S2 outscores some musts but stays in should: it doesn't touch the Dell.

| Proposal | Seats | Reach | Impact | Cost | Risk | Effort | Evid | Total |
|---|---|---|---|---|---|---|---|---|
| M1 Build gate + version stamp | maintainer, quality, security, owner, all | 4 | 5 | 5 | 5 | 5 | 5 | **62** |
| M2 Uninstall keeps user config | power, quality, owner, security | 4 | 4 | 5 | 5 | 5 | 5 | **59** |
| M7 Blur follows system High contrast | access, design, newcomer, security | 3 | 5 | 5 | 4 | 5 | 5 | **57** |
| S5 VLC + Simple Scan in "Start here" | everyday, newcomer, simplicity, owner | 4 | 3 | 5 | 5 | 5 | 5 | **56** |
| M4 Honest dconf snapshot (marker) | security, power, owner, maintainer | 3 | 5 | 5 | 5 | 5 | 3 | **55** |
| M5 Keep-new restores scheme keys | quality, power, access | 3 | 4 | 5 | 4 | 4 | 5 | **53** |
| M8 Docs truth + day-one notes | owner, design, quality, newcomer | 4 | 2 | 5 | 5 | 5 | 5 | **53** |
| S2 Keep-alive RAM rule + Settings switch | lowend, mobile, simplicity, owner | 4 | 4 | 5 | 3 | 3 | 5 | **53** |
| M6 Classic keeps user `gtk.css` | power, owner, maintainer, design | 3 | 4 | 5 | 4 | 3 | 5 | **52** |
| M3 Root-path allowlist | security, maintainer | 3 | 3 | 5 | 4 | 5 | 5 | **51** |
| S4 Tour text + portal-dialog Help line | newcomer, simplicity, design | 4 | 2 | 5 | 5 | 5 | 4 | **51** |
| S7 Accessibility link in Ostrich Settings | access, newcomer | 3 | 3 | 5 | 5 | 4 | 4 | **50** |
| S8 Release gate + wider `state.sh` | maintainer, quality | 2 | 3 | 5 | 5 | 4 | 5 | **49** |
| S11 `--remove-packages` typed confirm | security, quality | 2 | 3 | 5 | 5 | 4 | 5 | **49** |
| S1 Saver keeps `idle-delay 0` | owner, mobile, power | 2 | 3 | 4 | 5 | 5 | 5 | **48** |
| Showtime preinstalled (rejected, R9) | everyday | 3 | 2 | 4 | 5 | 5 | 5 | 48 |
| N1 Dock private-field guards + ledger | maintainer | 5 | 2 | 5 | 4 | 3 | 3 | 48 |
| S3 CLI safe without a terminal | power | 2 | 2 | 5 | 5 | 4 | 5 | **46** |
| S6 Store failure toasts in plain words | newcomer | 3 | 3 | 5 | 4 | 3 | 3 | **45** |
| S9 Night Glass wallpaper pair | design | 1 | 2 | 5 | 5 | 5 | 5 | **44** |
| S10 Dash to Dock migration | owner | 1 | 3 | 5 | 4 | 3 | 5 | **43** |
| N2 NavigationAction policy | security | 3 | 2 | 5 | 2 | 3 | 4 | 40 |
| N3 Blur strengths under "Advanced" | simplicity | 3 | 2 | 5 | 4 | 3 | 2 | 40 |
| Fold holder-monitor / search-new-window into tweaks | simplicity | 1 | 1 | 4 | 2 | 2 | 3 | 26 |

## The plan

### Must fix before installing (this round)

Build each item on its own and commit it on its own. Run shellcheck, shfmt, bats, `tests/js-test.sh` and lint-js after each one.

**M1. Stop on a missing or stale tools build, and stamp the version.** Serves the owner and everyone who installs from a checkout.
- In `install.sh`, before `take_restore_point` and before any module, run a preflight using `have_build` from `modules/tools/install.sh:33-38`. Move it to `lib/` so both can call it.
- If `$BUILD_DIR` holds some but not all of the binaries, `die` with: `run tests/vm/build-tools.sh --check, then BUILD_DIR=$VM_DIR/tools-bin ./install.sh`.
- If it holds all of them but a file under `$REPO/tools` (excluding `target/`) is newer than `ostrich-system-helper`, `die` with the build's date. Allow `--allow-stale` only if it's free to add; otherwise skip it.
- `--dry-run` prints which source it would use: the local path, or "download vX".
- Bump `VERSION` to the number from Question 2 (0.1.5 if the owner says nothing). Then `ostrich --help` prints it.
- Tests:
  - New cases in `tests/modules.bats`, next to `:217`/`:315`: a partial build stops before the restore point, a stale build stops, a complete build passes, and the dry run names the source.
  - In the VM, `ostrich --help | head -1` shows the new version.

**M2. Uninstall copies the user's config before deleting it.** Serves the owner, Priya and Rosa.
- In `lib/uninstall.sh`, before the loop at `:148-150`, copy `drawer.toml`, `environments/` and `settings.dconf` from `$CFG/ubuntu-ostrich` into `$RESTORE_DIR/kept-config/`. The whole folder becomes `restore/used-<date>/` at `:196`.
- The last output line prints that path. The dry run lists it.
- The per-site sign-in data (`$DATA/ubuntu-ostrich/drawer`) is still removed, on purpose. Say so in the prompt at `:57-66`.
- Tests:
  - A bats case in `tests/restore.bats`: the files exist under `used-*/kept-config` after `uninstall_main`.
  - Re-run lab test #8: `drawer.toml` is found.

**M3. Root `rm` and `mv` act only on our own paths.** Serves everyone, and the security seat's concern.
- In `lib/uninstall.sh:115-120`, add `root_path_ok()`. It accepts only:
  - `/usr/libexec/ubuntu-ostrich/*`
  - `/usr/share/polkit-1/actions/org.ubuntu-ostrich.*`
  - `/etc/systemd/system/ubuntu-ostrich-*`
  - `/etc/modprobe.d/ubuntu-ostrich-*`
  - `/etc/udev/rules.d/90-ubuntu-ostrich-*`
  - For `originals-root.txt`, also require the copy to be `"$path.before-ubuntu-ostrich"`, as `lib/helper.sh:21` writes it.
- Anything else gets a `warn` and is skipped.
- The bats sandbox overrides `HELPER_DEST` and the other destinations. Build the allowlist from those same variables, with the fixed patterns above as their defaults.
- Tests:
  - A bats case: a canary line in `created-root.txt` is skipped and named.
  - Re-run lab test #9: the canary survives.

**M4. A restore point that is honest about dconf.** Serves the owner and Tomás, who reinstalls.
- In `lib/restore.sh:31-35`: if `dconf dump /` fails, remove the half-written folder and `die`. If `dconf` is absent, write an empty `dconf.ini` and a `dconf.missing` marker.
- In `lib/uninstall.sh:174-177`: if `dconf.missing` exists, do not run `dconf reset -f /`. Take the keep-new branch instead and say why.
- Tests: two bats cases, a failing dump and the marker that blocks the reset.

**M5. `--keep-new-settings` puts back what a scheme changed.** Serves the owner, Daniel (a blank wallpaper changes contrast) and Priya.
- In `lib/uninstall.sh`'s keep-new branch (`:166-171`), and before `$CFG/ubuntu-ostrich` is removed at `:148`: if `$CFG/ubuntu-ostrich/scheme/before/settings` exists, `gsettings set` each of its lines (`schema<TAB>key<TAB>value`, the four `BEFORE_SETTINGS` keys from `palette/src/main.rs:270-275`).
- Then, if `picture-uri` or `picture-uri-dark` still points under `$DATA/backgrounds/ubuntu-ostrich`, reset that key.
- No dependency on the `ostrich` binary.
- Tests:
  - A bats case with a fake `before/settings` and a fake `gsettings`.
  - Re-run lab test #3b: `picture-uri*`, `icon-theme` and `accent-color` are back to their pre-scheme values, and the wallpaper file exists.

**M6. Classic keeps the user's own `gtk.css`.** Serves the owner and Priya.
- First, add a Rust test in `tools/palette`, with a temp `XDG_CONFIG_HOME` and a fake `gsettings`, that replays #10:
  1. Apply forest.
  2. Append `/* my own line */` to `gtk-4.0/gtk.css`.
  3. Apply night-glass.
  4. Apply classic.
  5. Assert the line survives, our block is gone, and no `*.before-palette` file is left.
- Then fix whatever path the test catches. The read of `restore_before` and `strip_block` says it should already pass, so check the binary on try-me against the source too.
- Name the backups of the Ghostty theme and `palette.json` correctly, or stop making them. `write()` at `main.rs:142-147` makes `ubuntu-ostrich.css.before-palette` for files that aren't CSS.
- Tests: the cargo test, plus a re-run of lab test #10.

**M7. Blur follows GNOME's own High contrast.** Serves Daniel, Rosa, and Tomás on a dim panel.
- In `modules/gnome/extensions/blur/extension.js`, make `_on()` (`:471-473`) also return false when `org.gnome.desktop.a11y.interface high-contrast` is true.
- Connect `changed::high-contrast` on that schema to `_rebuild()` and `_styleLock()`, as `:216-217` does for blur's own key.
- Drop the connection in `disable()`.
- Tests:
  - Re-run lab test #11. Every banner line must read at least 4.5:1 with system High contrast on.
  - `tests/vm/ext-test.sh blur` (40 cycles).
  - `ui-test.sh`.
  - E3 with High contrast off, unchanged (±3 points).

**M8. Docs that tell the truth, and the day-one notes.** Serves the owner and newcomers.
- `docs/DEFAULTS.md:19,46`: say that Dash to Dock, Blur my Shell and Vitals settings are not carried over, and that Space Bar, Just Perfection and Tiling Assistant are.
- Add a "your old settings" table: banners off, intellihide off, 34 px icons, the purple dock, idle never, keep-alive. Each row names the setting that returns it.
- Scope `docs/DECISIONS.md:143` to the clock menu.
- Add an "Installing on your own machine" section with the steps below and the portal-dialog note. Put it in `README.md` or `docs/INSTALL.md`, wherever the install line already lives.
- Test: read the docs against `modules/gnome/install.sh:135-206`.

**The gate, on the final commit, before the SSD or the Dell:**
- `tests/vm/build-tools.sh --check`.
- In `tests/vm/state.sh`, filter `apps/update-manager launch-time` so #3's noise doesn't hide real failures.
- `tests/vm/e2e.sh --pipe --from pre --uninstall` twice: once with a default uninstall, and once after `ostrich theme scheme apply forest` with `--keep-new-settings`.
- Re-run lab tests #3b, #8, #9, #10, #11 and #14.
- `ext-test`, `drawer-test`, `a11y-test`, `polkit-test`, `dconf-test`, `bats tests/`, shellcheck, shfmt.
- Read `git diff v0.1.4..HEAD -- tools/system-helper` (or wherever the helper's source lives). If it isn't empty, run `security-review` on it before it runs as root on the Dell. Nobody reviewed it this council, and the security seat flagged that gap.

### Should (next; build as many as time allows after the must tier)

- **S1. Saver keeps `idle-delay 0`** (owner, mobile).
  - `modules/gnome/extensions/monitor/battery.js:48`: keep the current value when `current === 0` or when `0 < current < saverValue`.
  - Flip `tests/js/monitor-battery.test.js:33` so 0 stays 0.
  - Verify: `tests/js-test.sh`, then lab test #29 should read 0.
- **S2. Keep-alive follows RAM** (lowend, mobile, simplicity, owner).
  - `tools/drawer-host/src/config.rs:127-140`: only when the default config is first created, `keep = MemTotal >= 12 GB`. An existing `drawer.toml` is never changed.
  - Add a "Keep loaded in the background (about N MB)" row per kept site to the Drawer page in `tools/welcome/src/main.rs`, through the existing `keep(sb)` action.
  - Unit-test the threshold.
  - Re-shoot `t23` (the unloaded bar) before shipping.
- **S3. CLI safe without a terminal** (power).
  - `tools/store-tui/src/main.rs:613-645`: handle `--help`/`-h`. With no TTY, print a usage line and exit 2 instead of starting ratatui.
  - `ostrich theme --help`: print usage before touching the wallpaper.
  - `theme scheme list`: no colour swatches when stdout isn't a TTY.
  - Verify: re-run lab test #30. Everything exits 0 or 2, and `grep -c $'\e'` finds nothing.
- **S4. Tour text** (newcomer, simplicity).
  - Remove the backticks and "in a terminal" text at `tools/welcome/src/main.rs:2120,2210`.
  - Skip-the-tour ends on a short "You're all set" page, with the shortcuts behind a link.
  - A Help line: "Ubuntu may show an 'internal error' dialog the first time a drawer site opens. It's Ubuntu's xdg-desktop-portal. Close it; nothing is wrong with your files."
  - Verify: screenshot the end page on a fresh try-me.
- **S5. "Start here" is six apps** (everyday, newcomer, owner): LibreOffice, Thunderbird, VLC, Steam, Discord, Simple Scan. Shotwell moves down, since Loupe already opens photos. Change `tools/welcome/data/recommended.toml:8-14`. Verify: `store-test.sh`, then install VLC from "Start here" and run `xdg-mime query default audio/mpeg`.
- **S6. Store failures in plain words** (newcomer).
  - `tools/store-gtk/src/main.rs:256-260,1551-1557`: a cause and a next step, with the raw text behind "Show details". Follow the pattern at `:1243`.
  - Verify: lab test #15 with the network off.
- **S7. An Accessibility link in Ostrich Settings** (access). One row that runs `gnome-control-center universal-access`. Verify: `a11y-test.sh` names it, and a click opens the panel.
- **S8. Release gate** (maintainer, quality).
  - `.github/workflows/release.yml`: `needs:` the CI job.
  - `tests/vm/state.sh:17-23`: add `~/.local/share/{icons,backgrounds,ubuntu-ostrich}`, `~/.config/mimeapps.list` and the udev rule.
  - A short `docs/RELEASING.md` that names the gate above.
- **S9. Night Glass uses Big Dipper for both styles.** One file, `tools/icons/schemes/night-glass.toml:35-36`. Verify: lab test #22.
- **S10. Dash to Dock migration**, if the owner says yes (Question 4). Add `migrate_dash_to_dock` in `modules/gnome/install.sh` next to `:174`, a one-time copy of intellihide, icon size and background, plus a bats case.
- **S11. `--remove-packages` asks before removing.** `lib/uninstall.sh:182-192`: show the list and require a typed `remove`. The prompt and `DEFAULTS.md` say packages are only listed by default.

### Experiments (only real hardware can settle these)

| # | What | Measurement | Keep / revert line |
|---|---|---|---|
| X1 (E1) | Pill on vs off on battery | Dell on battery, 15 min each in `measure.sh` with `power_now`, pill off vs pill on and paused | The gap must be under 0.2 W to stay offered. At 0.3 W or more, it gets cut or limited to AC only. |
| X2 | dGPU stays asleep | The 10de `runtime_status` after 10 s idle, then after opening the monitor popup and the clock menu, with nothing NVIDIA pinned | Must read `suspended` throughout. `active` is a must-fix bug (DESIGN principle 3). |
| X3 (E5) | `static-blur-on-battery` | 15 min live blur vs static, `power_now` | Turn it on by default only if it saves 0.3 W or more. Otherwise remove the key. |
| X4 | An open drawer's real cost | `power_now` and gnome-shell CPU with Messages open 5 min vs closed, on the Iris Xe | #20's 35× is llvmpipe. If the Dell's gap is under 0.5 W, no change. If it's over 1 W, look at the drawer's slide and compositing. |
| X5 (test #5) | Hidden keep-alive sites' wakeups | Dell, 5 min windows, keep-alive on vs off | 5 wakeups/s or more, or 1% CPU or more, reopens a lid-close pause. Otherwise, no change. |
| X6 | Wallpaper memory per scheme | One fresh boot per scheme, `measure.sh` shell PSS | Over +40 MB against Classic means that scheme's wallpaper gets downscaled. |
| X7 (test #25) | Every private `_name` exists in GNOME 50 | A grep of `/usr/share/gnome-shell/js` (extract the gresource) against the names in `dock/`, `blur/`, `focus/` and `tweaks/` | Any missing name is a live bug and becomes must. Otherwise it becomes ledger N1. |

### Not now

- **N1. Dock private-field guards and a private-API ledger** (maintainer). Wrap the dock's calls (`modules/gnome/extensions/dock/extension.js:73,98-106,199-233,295`) in `shellField` and `Patches.replace`, and add a ledger script. Serves everyone at the GNOME 51 port. Verify with ext-test and a renamed-field run (test #26).
- **N2. NavigationAction policy, a confirmation before an unverified AppImage or tarball, permissions in the Flatpak-bundle dialog, and copying the `.deb` to a root-owned folder** (security). `tools/drawer-host/src/main.rs:650-669`, `tools/store-gtk/src/main.rs:744-778`, `tools/store-core/src/ghinstall.rs:184`. Re-run `drawer-test.sh` for the sign-in redirects.
- **N3. Blur strengths folded under "Advanced", all 22 keys kept** (simplicity, owner). `tools/welcome/src/main.rs`, the Blur page. Verify: every key still reachable through `ostrich config`.
- **N4. Accent check in the scheme editor, and the High contrast scheme's accent** (`#1c62b9` is about 3.5:1 on black) (access). `tools/palette/src/scheme.rs:190-251`, `tools/icons/schemes/high-contrast.toml`. Verify: a unit test for the check, then `contrast.sh`.
- **N5. Full walk at 200% text, Tab and Orca** (access, tests #12 and #13). This needs real hardware (X5 in the 2026-10-24 verdict).
- **N6. Dotfiles** (power): chezmoi re-applies the scheme id, the Ghostty config references the scheme's theme, `ostrich config where`. Files: `home/run_onchange_after_ostrich-settings.sh.tmpl`, `home/` Ghostty config.
- **N7. Extension memory over 40 enable/disable cycles** (lowend). `tests/vm/ext-test.sh`, with a budget of +10 MB per extension.
- **N8. Folding holder-monitor and search-new-window into tweaks** (simplicity). After the Dell, with ext-test re-run.

## How to install safely

The owner runs every command. Claude prints the `sudo` lines and never runs them.

**0. Before anything:** the must tier and the gate above are green on one commit, and `git status` is clean.

**1. Recommended first: the external SSD** (`DESIGN.md:324-328`). Install Ubuntu 26.04 plus this build on the SSD from inside the VM, boot it from the firmware's one-time menu, and do the first-hour checks in step 6. The internal disk is never touched. Skip this step only if the owner waives it (Question 1).

**2. On the internal disk: take your own copies first.** Don't rely only on the restore point.
```bash
mkdir -p ~/ostrich-pre && cd ~/ostrich-pre
dconf dump / > dconf-before.ini
apt-mark showmanual > packages-before.txt
gnome-extensions list --enabled > extensions-before.txt
prime-select query > prime-before.txt 2>/dev/null
cp -a ~/.config/gtk-4.0 ~/.config/gtk-3.0 ~/.config/ghostty . 2>/dev/null
systemctl is-active docker ufw ollama > services-before.txt 2>&1; grep -l howdy /etc/pam.d/* > pam-before.txt
```
If you have a home-folder backup tool, run it now.

**3. Dry run, using the exact binaries the gate tested:**
```bash
export BUILD_DIR="$HOME/.local/share/ubuntu-ostrich/vm/tools-bin"
./install.sh --dry-run 2>&1 | tee ~/ostrich-pre/dryrun.log
```
Check:
- It says "using the tools built in …/tools-bin", never "would be downloaded".
- It mentions taking a restore point.
- The hardware modules detected are nvidia-optimus, dell, power and touchscreen.
- Nothing is listed that you don't expect.

**4. Install on AC power,** with the same `BUILD_DIR`: `./install.sh`. The installer asks for your password itself.

**5. Straight after install, before logging out:**
- `wc -c ~/.local/state/ubuntu-ostrich/restore/original/dconf.ini`. On your machine this should be tens of KB. **If it is 0, stop and ask before doing anything else.**
- `ostrich --help | head -1` shows the new version.
- `for e in $(gnome-extensions list --enabled); do echo "$e $(gnome-extensions info "$e" | grep State)"; done` shows ACTIVE for all eleven of ours. Blur my Shell, Vitals, Space Bar and Dash to Dock should be off, not deleted.
- Diff `systemctl is-active docker ufw ollama` and the howdy PAM file against step 2. They must be unchanged.
- Run `ostrich config export ~/ostrich-pre/ostrich-settings.dconf`, then `ostrich uninstall --dry-run`, and read the output once.
- Run `./install.sh --dry-run` again. It should list no changes.

**6. Log out and back in. The first hour, which only real hardware can show:**
- **NVIDIA:** `cat /sys/bus/pci/devices/*/power/runtime_status` for the 10de device reads `suspended`. Open the monitor popup and the clock menu, and it still reads `suspended` (X2). A graphics-mode switch asks for a password and says you need to log out.
- **Battery:** unplug, then 15 minutes of `measure.sh` with `power_now`, pill off (X1, X3). Close the lid, resume, and check shell wakeups/s.
- **Drawer:** open Messages. Expect Ubuntu's portal "internal error" dialog: close it and don't report it as Ostrich. Then play one YouTube video (never played in the VM).
- **Speakers:** run the A/B test in Ostrich Settings and listen for the glitch from critique `20261023-192734`.
- **Touchscreen:** off and on, then the same after a suspend.
- **Your choices:** banners, dock auto-hide and size, idle-delay. Use the "your old settings" table from M8.
- **Transitions:** look at the three open motion critiques on the real GPU.
- **Everyday:** a printer, Steam on the dGPU, a screen share and Bluetooth audio, when convenient.

**7. Day-one rules for anything that slipped from the must tier:**
- If M5 or M6 didn't land: no colour schemes, and no Classic.
- If M7 didn't land: GNOME High contrast stays off.
- If S1 didn't land: turn `saver-desktop` off if you want the screen never to blank.
- Never pass `--remove-packages`.

**8. To undo:** run `ostrich uninstall` (the default mode, proven clean by #3), then log out. Note that the default puts back **every** setting from install time, including ones you changed since. Check the kept-config path it prints, then `dconf dump / | diff - ~/ostrich-pre/dconf-before.ini`.

## Rejected

- **`gstreamer1.0-plugins-ugly`:** test #19 shows mp3, H.264 and AAC decode without it.
- **The Store setting default apps:** test #18 shows Flathub apps register themselves.
- **Decibels:** not in resolute (facts D3).
- **Preinstalling Showtime:** R9. VLC in "Start here" covers mp3 too.
- **Hiding GNOME Settings:** test #6.
- **`[[ -s ]]` guard on `dconf.ini`:** R4. It blocks a legitimate empty snapshot.
- **"The installer falls back to the local build":** facts D7 says that's wrong.
- **Killing gnome-shell with `kill -9` as a crash test:** facts #44. It ends the whole Wayland session.
- **Removing the per-surface blur strengths:** they are Blur my Shell parity, and the owner asked for them in critique `20261023-193347`.
- **Cutting the pill now:** R12.
- **A first-run memory question:** the RAM rule does the job without a new screen.
- **Merging extensions before the Dell:** risk for no gain. Every seat deferred it.

## Owner vs most people

- **Keep-alive:**
  - Most people: off below 12 GB, which saves 505 MB on an 8 GB machine.
  - The owner: unchanged on the Dell.
  - The setting that lets both win: the per-site "Keep loaded" switch, already in the right-click menu and added to Settings > Drawer by S2.
- **Banners:** most people get them on, which `DESIGN.md:264` decided. Access adds that banners are the only notice for people who can't hear a sound. The owner had them off; switch them off in Settings > Notifications. The M8 table names it.
- **Dock:** most people get Ubuntu-like defaults (intellihide, 40 px, black or white). The owner's intellihide off, 34 px and purple 20% are three settings on the Dock page, or automatic if the owner chooses S10.
- **Saver and blanking:** most people get a 2-minute blank in power saver. An explicit "never" is kept (S1). The `saver-desktop` switch turns the whole saver desktop off.
- **A media player:** most people get VLC first in "Start here". The owner already uses VLC, so the two agree.
- **The pill:** off for most people. It is the owner's request and stays one switch away, pending the X1 measurement.

## Questions for the owner

1. **The SSD gate.** `DESIGN.md:301` and `DECISIONS.md:36` say the live machine is set up only after the VM **and** external-SSD tests. Do the SSD hour first (recommended), or waive it for this install? A waiver should be recorded in `DECISIONS.md`.
2. **Version.** Is this build 0.1.5 or 0.2.0? Do you want it pushed and released before the Dell, or installed from the local checkout with `BUILD_DIR` as above?
3. **`idle-delay 0`:** confirm "never blank" should survive power saver. S1 assumes yes.
4. **Dash to Dock:** carry your intellihide off, 34 px and purple dock over automatically (S10), or set them once by hand?
5. **Banners:** keep the design default (on), which you turn off yourself, or change `DESIGN.md:264`?
6. **The Dell's RAM** (`grep MemTotal /proc/meminfo`). It confirms the 12 GB keep-alive line leaves your setup alone.
7. **Portal crash:** file the drafted xdg-desktop-portal 1.21.1 report with Ubuntu?
8. **"Start here":** VLC and Simple Scan in, Shotwell down? This one is taste; opinion decided it.

---
Files: verdict inputs in `~/.local/share/ubuntu-ostrich/vm/council/2026-10-31-ready-to-install-on-the-dell/`. Code cited: `modules/tools/install.sh`, `.../tests/vm/build-tools.sh`, `.../lib/uninstall.sh`, `.../lib/restore.sh`, `.../modules/gnome/extensions/blur/extension.js`, `.../modules/gnome/extensions/monitor/battery.js`, `.../tools/palette/src/main.rs`, `.../modules/gnome/extensions/drawer/bar.js`.

Not checked: I read the round-1 openings only through the curator's board and facts.md, and of round 2 only owner and simplicity. I ran no git command and no VM. The root cause of #10 is unresolved, because the code as read should keep the user's line, so M6 starts with a failing test. The biggest risk: the build seats recommended won't be the one installed unless `BUILD_DIR` points at `tools-bin` or M1 lands.
