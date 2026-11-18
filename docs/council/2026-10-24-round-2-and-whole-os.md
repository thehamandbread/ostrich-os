# Verdict: Round 2 and the whole OS (Events card, icon scheme, whole-OS review)

## Summary

On agenda 1, the council agreed almost to a seat: hide GNOME's "Events" card and add no new data source. The tests settled the main worry. T3 shows a fresh install keeps the date header, our "This computer" card and the world-clocks card (gnome-clocks 50.0 is installed). It also shows "No Events" really does appear when no calendar is connected. The owner asked for "something else", not only a removal, so the hide comes with a redesigned "This computer" card and a `show-events` switch. The process-list card is rejected.

On agenda 2: Ostrich Store, Ostrich Settings and Ostrich Drawer get one icon scheme. Each icon is a rounded glass square with its own plain glyph. The "program" is a template SVG plus a script that runs without a GUI, in `tools/icons/`. Inkscape stays optional. A check makes sure every `Icon=` we ship actually resolves.

On agenda 3, the tests found real defects that matter more than any new feature:
- The drawer loads all four pinned sites at login, about 520 MB of memory. That breaks DESIGN.md's own rule that only keep-alive sites stay loaded.
- The drawer's + fails silently.
- The dock went INACTIVE (switched off) after 50 enable/disable cycles, with no log line.
- Two monitor labels fail contrast.
- Any app running as the user can run the root helper without a prompt. That breaks DESIGN.md principle 6.
- A fresh install has no default app for video, music, web pages or Word files.

Fixing these is most of the Must list. Blur stepping down on battery is not proven (T2 was inconclusive), so it is an experiment, not a default.

## Rulings

1. **What replaces Events?** Two positions:
   - Simplicity, Maintainer, Quality, Newcomer and Everyday: hide it and add nothing.
   - Design and Owner: hide it, and the owner asked for a redesign, so design what is left.

   **Ruling:** hide `_eventsItem`, add a `show-events` key (off by default), and redesign the "This computer" card as the main item. **Why:** T3 shows the hide leaves a real panel, not an empty one. The owner wrote "redesign this into something else" twice (193812, 032844), so a hide alone would answer half the note.

2. **Top-process and NVIDIA-holder rows in the Today card (Owner R1).** **Rejected.** Owner withdrew it, and seven seats objected. It adds a `/proc` read on every open (facts Notes) and duplicates the monitor popup. The owner's own "really fat" note (032706) points the other way. The card gets an "Open the monitor" link instead.

3. **A separate `show-events` key, or widen `today-panel`?** **A separate key.** `today-panel` already means "hide the month grid" (facts row 4). Overloading it would take away the owner's ability to have one without the other. Maintainer accepts either; Simplicity moved to the key.

4. **Drawer sites at login: keep all pinned sites loaded (owner's hidden start, DEFAULTS.md:15) or load on first open (Low-end, Security, Mobile)?** **Ruling:** at login, load only sites marked keep-alive. Every other site loads on first open. **Why:** DESIGN.md already says "only keep-alive services (messaging) stay loaded in the background". T1 shows all four pinned sites loaded hidden (WebKit 487 MB plus the network process 34 MB). So this enforces the existing design and needs no change to it. Which starters count as keep-alive is an owner question (default below). Notification permission stays as DESIGN.md:110 says; changing that is also an owner question.

5. **Polkit: one action with `allow_active=yes` (status quo) or split it (Security)?** **Split.** T8 proved any same-user process can run `graphics` and `power apply` as root with no prompt. That breaks DESIGN.md principle 6 ("every privileged action goes through polkit with user confirmation"). `graphics set` gets a password prompt. `power apply` and touchscreen stay promptless for now, so the automatic switch to power saver at 20 % battery keeps working (Mobile). Keeping `power apply` promptless is a second exception to principle 6, so it is an owner question.

6. **Hide App Center (Simplicity) or keep it (Everyday)?** **Keep it in the app grid.** Ostrich Store has no snap path at all (facts row 8). Snaps update through App Center. Simplicity conceded. It is already out of the dock, and Ostrich Store is already the default for Flatpak links (facts row 9). That is the owner's note 033049, answered as far as the evidence allows.

7. **Blur steps down on battery (Mobile, Low-end) or stays live (Owner).** **Experiment, default unchanged.** T2 found idle cost within noise, and the overview increase (+0.9 points) was the same size as the run-to-run noise (1.64 vs 0.92 in two runs with blur on). The power-saver case never switched profile. Watts can't be measured in the VM.

8. **How far the icon work goes: a full `ostrich-*-symbolic` family (Design) or only icons that fail (Maintainer)?** **App icons for our own apps now; symbolics only where a borrowed name fails or mismatches.** The agenda asks for an app-icon scheme. A whole symbolic family is not needed to answer it.

9. **Dock grid button: remove it (Simplicity R1) or keep it.** **Keep it, with a "Show apps" tooltip.** Rosa needs the equivalent of a Start button (PERSONAS). Simplicity withdrew the cut.

10. **Merge the small extensions, and turn search providers off by default.** **Not now.** The test for the 8 MB merge threshold was never run. The test plan found two of the four named targets aren't our extensions. DESIGN.md principle 5 asks for small, separate extensions.

11. **Monitor footer note "Every 2 s": fix its contrast, or delete it (Simplicity)?** **Delete the line and move the interval into the refresh button's tooltip.** This is taste, and opinion decided it. It removes a failing line and answers the owner's "fat" note too.

## Scorecard

Weights: Reach ×3, Impact ×3, Cost to battery and resources ×2 (5 = no cost), Risk and upkeep ×2 (5 = low risk), Effort ×1 (5 = little effort), Evidence ×2. The highest possible total is 65.

| Proposal | Seats | Reach | Impact | Cost | Risk | Effort | Evidence | Total |
|---|---|---|---|---|---|---|---|---|
| C. Drawer loads only keep-alive sites at login | Low-end, Security, Mobile, Owner, Simplicity | 5 | 4 | 5 | 3 | 4 | 5 | **57** |
| A. Today: hide Events, `show-events` key, redesigned card | all twelve | 5 | 3 | 5 | 4 | 4 | 5 | **56** |
| D. Drawer + shows an error, http(s) only | Quality, Newcomer, Security, Everyday | 4 | 3 | 5 | 5 | 5 | 5 | **56** |
| F. Monitor contrast fixes, state by shape | Access, Design, Quality | 4 | 3 | 5 | 5 | 5 | 5 | **56** |
| E. Dock INACTIVE root cause, `ext-test.sh` fails on silent INACTIVE | Quality, Maintainer, Low-end | 5 | 4 | 5 | 4 | 2 | 4 | **55** |
| G. Split the polkit policy | Security (+Power, Mobile conditions) | 5 | 3 | 5 | 3 | 3 | 5 | **53** |
| H. Default apps for video, music, web and docx; scanning | Everyday, Newcomer | 4 | 3 | 5 | 5 | 4 | 4 | **53** |
| I. `Patches.replace` degrades instead of throwing | Maintainer, Quality | 4 | 3 | 5 | 5 | 3 | 4 | **52** |
| S. Second confirmation before an unverified .deb | Security | 3 | 3 | 5 | 5 | 4 | 5 | **52** |
| B. Icon scheme, `tools/icons/`, `Icon=` resolve check | Design, Owner, all | 4 | 3 | 5 | 4 | 3 | 4 | **50** |
| L. `accessible_name` lint, tooltips on icon-only buttons | Access, Newcomer, Quality | 3 | 3 | 5 | 5 | 4 | 4 | **50** |
| R. Sign-in pop-up shows the host; camera/mic prompts | Security, Everyday | 4 | 3 | 5 | 4 | 3 | 3 | **48** |
| M. `// why:` lint on repeating timers; drawer hover check event-driven | Mobile, Quality | 3 | 2 | 5 | 5 | 4 | 4 | **47** |
| U. "Start here" recommended apps (mail, photos, Steam) | Everyday | 4 | 3 | 5 | 4 | 4 | 2 | **47** |
| X. `ostrich doctor` | Quality, Maintainer, Power | 3 | 3 | 5 | 4 | 3 | 3 | **45** |
| J. `ostrich config` plus chezmoi dconf layer | Power, Owner | 2 | 4 | 5 | 3 | 2 | 4 | **44** |
| K. Schema-key parity test | Power, Simplicity | 2 | 2 | 5 | 5 | 4 | 4 | **44** |
| N. High contrast / solid preset | Access, Design | 2 | 4 | 5 | 3 | 3 | 3 | **43** |
| P. Blur static on battery | Mobile, Low-end | 4 | 2 | 4 | 3 | 4 | 2 | **40** |
| O. Shared design tokens | Design | 3 | 2 | 5 | 2 | 2 | 4 | **39** |
| W. Tour button styling | Newcomer | 2 | 2 | 5 | 5 | 5 | 1 | **39** |
| T. Daily GitHub-app update timer | Security | 3 | 2 | 3 | 3 | 2 | 4 | **37** |
| V. Fold Settings pages (page budget) | Simplicity | 3 | 2 | 5 | 3 | 3 | 1 | **36** |
| Y. "Getting started" page with "Show me" buttons | Newcomer | 2 | 3 | 5 | 3 | 2 | 1 | **35** |
| Q. Weak-GPU automatic solid surfaces | Low-end | 2 | 3 | 4 | 2 | 2 | 2 | **33** |
| Top-process card (rejected) | Owner R1 | 2 | 2 | 3 | 3 | 3 | 1 | 29 |

B scores below I and S, but it is in Must because agenda 2 asks for it directly and the owner raised it in two notes.

## The plan

### Must (this round)

Every item is built and checked in the test VM, never on the live machine. Run shellcheck, shfmt, bats, ESLint and the cargo checks after each item, and commit each item on its own.

**M1. Today panel: Events hidden, one designed card, a switch** (agenda 1; scores A)
- **What changes:**
  - In `modules/gnome/extensions/tweaks/today.js`:
    - After the shape guard (lines 84-88), hide `_eventsItem` while `show-events` is false, and follow changes to the key.
    - In `disable()`, call `show()` on `_eventsItem`, inside a guard that checks `enable()` actually ran.
    - The card drops the borrowed `events-button` class (line 95) and carries only `ost-today-card`.
    - Layout: one lead line ("Battery 54 %, 3 h left", or "Charging, 80 %"), then three text rows ("Power mode: Balanced", "NVIDIA GPU asleep", "On for 2 h"), then an "Open the monitor" link.
    - Line 174: "asleep, using no power" becomes "asleep".
    - When UPower's time left reads 0, show "estimating".
    - With no battery, the battery line is hidden. The NVIDIA row shows only on supported hardware.
    - Nothing new reads data: the card still reads only the cached D-Bus properties and sysfs (facts row 1).
  - Add a `show-events` boolean (default false) to the tweaks schema in `modules/gnome/extensions/tweaks/schemas/`.
  - Style the card in `tweaks/stylesheet.css` (it replaces the styling from the stock class).
  - Add a "Show calendar events" row on the Top bar page of Ostrich Settings (`tools/welcome/src/main.rs`), to meet principle 7.
- **Serves:** the owner (the note answered), Rosa (no dead "No Events" card; plain words), Daniel (a large text lead line), Tomás (no new cost). Nobody loses: Events is one switch away, and Google Calendar is already a drawer site.
- **Verify:**
  - A state-table unit test in `tests/js/tweaks-today.test.js`: no battery, time 0, charging, NVIDIA present or absent.
  - `tests/vm/compare.sh` light, dark and glass: `ours/6-clock.png` shows no "No Events", no gap, and the card first.
  - `tests/vm/ext-test.sh tweaks` (20 cycles): ACTIVE, no JS errors, and the stock Events card is back after disable.
  - Turning `show-events` on brings Events back without a re-login.
  - `shell-bench.sh idle` with the menu shut stays within noise of 0.36 %.

**M2. Ostrich icon scheme, the program that makes it, and the three app icons** (agenda 2; scores B)
- **Scheme:**
  - A 128 px grid with a rounded-square (squircle) shell and a 4 px safe margin.
  - One top-lit glass gradient with a thin top-edge highlight, plus one Ostrich accent.
  - A plain-subject glyph with a distinct silhouette per app:
    - Store: a shopping bag.
    - Settings: three sliders. I chose sliders over a gear so it can't be confused with GNOME Settings' gear in the same grid. That is a taste call; the owner can overrule it.
    - Drawer: a bar with a panel dropping down from it.
  - Each app also gets a single-path 16 px `-symbolic` variant.
- **The program:**
  - `tools/icons/` holds `template.svg`, a `palette.toml` and an `export.sh`.
  - `export.sh` fills the template from the palette and renders PNG previews at 16, 32, 48 and 128 px with `rsvg-convert`, or Inkscape's CLI if present. It runs without a GUI, so Claude can drive it, and it is documented in a `README.md`.
  - Inkscape is not installed by default. It is already in the store's recommended list (`recommended.toml:24`) for hand-editing.
- **Where:**
  - The SVGs live in the repo; they are our own art, not third-party. A module installs them to `~/.local/share/icons/hicolor/{scalable,symbolic}/apps/` as `ostrich-store`, `ostrich-settings` and `ostrich-drawer`. The install is idempotent and updates the icon cache.
  - `Icon=` changes in `modules/tools/install.sh:102,118` and in the drawer's desktop entry.
  - Set the window icon in `tools/store-gtk/src/main.rs:116` and the Settings app.
- **Serves:** the owner (notes 032921, 033141), Rosa (an icon that says what the app is), Daniel (shape, not hue, tells them apart). Cost: about six SVGs to maintain, nothing at runtime.
- **Verify:**
  - A bats test, `tests/icons.bats`: every `Icon=` in every `.desktop` file we ship is either one of our installed names with its file present, or on a short allow-list.
  - A VM check: for each desktop file, `python3 -I` with Gtk 4 confirms `IconTheme.has_icon` for the name.
  - Screenshots of the dock and app grid at 100 % and 200 %: the three icons are distinct at 32 px.
  - `export.sh` runs clean in CI with no display.

**M3. Drawer: only keep-alive sites load at login, and the + says what went wrong** (scores C and D)
- **What changes:**
  - In `tools/drawer-host/src/main.rs`, the hidden start (autostarted from `modules/tools/install.sh:90-94`) creates web views only for sites with `keep-alive = true`. Every other pinned site stays an unloaded icon, dimmed as DESIGN.md already describes, until it is first opened.
  - The starters' keep-alive defaults follow the owner's answer to question 1. Without an answer: Google Messages and Google Chat are keep-alive; Claude and YouTube are not.
  - Rewrite `docs/DEFAULTS.md:15` to say this, and correct its stale 0.3 s hover delay to 500 ms.
  - The + menu checks the address and accepts only `http`/`https` (it adds `https://` to a bare host).
  - On an error it shows one plain line under the field and adds nothing:
    - "That isn't a web address."
    - "Can't reach that address. Check your internet and try again."
  - It sets `lastError` so tests can see the error.
- **Serves:** Tomás and every 8 GB machine (memory), the owner (memory is their second priority), Rosa (no silent button), Daniel (the error message gets an accessible name). Who loses: a non-keep-alive site can't notify until it has been opened once. That is DESIGN.md's intended behaviour, and the per-site "keep loaded in the background" right-click action stays the switch.
- **Verify:**
  - Run Recipe 1 from test-plan.md again: the number of WebKitWebProcess processes at login equals the number of keep-alive sites. "Ours" (all on minus all off) falls from 438 MB; record the new figure in `docs/BASELINE.md`.
  - `tests/vm/drawer-test.sh`: opening an unloaded site loads it, and the existing checks still pass.
  - Add a T6 case to drawer-test with `nmcli networking off`: "example.org" shows the "can't reach" line, "not a site" shows the "isn't a web address" line, nothing is added, and `lastError` is not null.

**M4. Dock goes INACTIVE after about 50 cycles: find the cause, and make the test catch it** (scores E)
- **What changes:**
  - Find the root cause in `modules/gnome/extensions/dock/extension.js`. Suspects to check first: an exception in `disable()` or `enable()` that nothing logs, an actor or signal left behind across cycles, and the single-shot timers at `:350/433`.
  - Wrap the dock's `enable()` and `disable()` so any exception is logged with the extension name.
  - In `tests/vm/ext-test.sh`, a state other than ACTIVE after any cycle fails the run, prints the last 50 journal lines, and goes on to the next extension instead of stopping at the first failure.
- **Serves:** everyone, Rosa most (a dock that vanishes is the worst failure for someone with no terminal), and the owner (it is their Dash to Dock replacement).
- **Verify:**
  - `tests/vm/ext-test.sh --cycles 100 dock` passes twice in a row.
  - `ext-test.sh --cycles 50 monitor blur drawer` reaches the monitor this time, and all stay ACTIVE.
  - PSS growth from first to last cycle is under 5 MB.

**M5. Monitor popup contrast, and state shown by shape** (scores F)
- **What changes:**
  - The "Power: Balanced" label and the NVIDIA "asleep" value lose their opacity dimming (`monitor/extension.js:52,202,423`, opacity 190 and 110) and use a full-strength secondary colour that clears 4.5:1 in both themes.
  - Find out why the earlier label fix didn't take effect (T5) and record it in the commit message.
  - Delete the "Every 2 s" footer note; the refresh button's tooltip says "Refreshes every 2 s".
  - The unpinned star becomes an outline icon and the pinned star a filled one, instead of opacity 110 (`:101`).
  - In `monitor/stylesheet.css:12`, drop the summary's 0.8 opacity, or clear 4.5:1 another way.
  - Row height does not change (the owner's density note 032706).
- **Serves:** Daniel, Rosa, the owner (the glass stays exactly as tuned).
- **Verify:**
  - Re-run the T5 computation (`evidence/tests/t5-contrast.txt` method, `python3 -I` with PIL) on `compare.sh` monitor scenes: every text region is at least 4.5:1 in light, dark and over the photo.
  - Add that computation as `tests/vm/contrast.sh`, so the fix can't silently regress again.

**M6. Split the root helper's polkit policy** (scores G)
- **What changes:** `modules/hardware/org.ubuntu-ostrich.system-helper.policy` gets three actions, matched with `org.freedesktop.policykit.exec.argv1`:
  - `power` (`apply`): `allow_active=yes`.
  - `touchscreen` (on/off): `allow_active=yes`; `--persist off` uses `auth_admin_keep`.
  - `graphics`: `status` is read-only and `allow_active=yes`; `set` uses `auth_admin_keep`, with a message in plain words ("Change the graphics mode. You'll need to log out.").
  - If argv1 matching can't separate `status` from `set`, split them into two helper entry points.
  - Install the policy through `lib/helper.sh` as now.
  - Document a local override (`/etc/polkit-1/rules.d/`) in `docs/DEFAULTS.md` (Power's condition).
- **Serves:** everyone (no silent root for other apps), Priya (she keeps an override). Cost: one password prompt on a rare graphics switch.
- **Verify:**
  - Re-run T8 (`systemd-run --user pkexec ...`): `power apply power-saver` exits 0 with no prompt, and `graphics status` exits 0.
  - `graphics set hybrid` asks for a password, and fails cleanly when cancelled.
  - In `ui-test.sh`, a profile switch through `powerprofilesctl`/D-Bus raises no authentication dialog (Mobile's regression check).
  - bats: `xmllint --noout` on the policy.

**M7. A fresh install opens video, music, web pages and Word files, and can scan** (scores H)
- **What changes:**
  1. Check first. In the VM, `gio open` a sample MP4, MP3, HTML and DOCX file and record which app launches, if any.
  2. For every type that fails, `modules/gnome/install.sh` (or `modules/apps/install.sh`) sets a user default with `xdg-mime default`:
     - Showtime for `video/*`.
     - The stock 26.04 audio player for `audio/*`, whatever the check finds.
     - The installed browser's desktop file for `text/html` and `x-scheme-handler/http(s)`.
     - LibreOffice Writer for docx, only if it is installed. If it isn't, nothing is set, and LibreOffice goes on the Should list's "Start here" list.
     - Each setting is idempotent, backs up `~/.config/mimeapps.list` first, supports `--dry-run`, and is logged.
  3. If `dpkg -s simple-scan` fails on a fresh install, add `simple-scan` to `MEDIA_PACKAGES` (`modules/tools/install.sh:159`).
- **Serves:** Rosa, Tomás, Daniel. Disk only; nothing stays running.
- **Verify:** a new `tests/vm/defaults-check.sh` (the T14 commands plus the `gio open` step) passes on a fresh `post` snapshot. bats covers the dry-run output.

### Should (next)

- **S1. Private-API patches degrade instead of aborting** (Maintainer, Quality)
  - `_lib/patches.js:13-14` returns false and logs once instead of throwing.
  - Each extension's `enable()` calls `restoreAll()` on failure.
  - The lock-screen blur patch (`blur/extension.js:436`) fails to "off".
  - Add a table of private symbols in `docs/PRIVATE-API.md`.
  - Verify: a scratch copy of the drawer renames each of its 4 patch targets in turn (test plan #19). `ext-test.sh drawer` shows the error logged, the originals restored after `disable()`, and other extensions still ACTIVE.
- **S2. Confirm before installing an unverified .deb** (Security)
  - `tools/store-gtk/src/main.rs:675,718`, `tools/store-core/src/github.rs:243-245`, `ghinstall.rs:170`.
  - With no published checksum, a second dialog shows the package name, version and whether it has maintainer scripts, before the root prompt. Cancel is the default button, and the wording is plain ("This can change your whole computer").
  - Verify: a unit test of the checksum branch, plus `store-test.sh` with an unchecksummed .deb fixture.
- **S3. Names and tooltips on every icon-only control** (Access, Newcomer, Quality)
  - An ESLint rule in `tests/lint-js.sh` fails on an icon-only `St.Button` with no `accessible_name`.
  - Name the drawer's top-bar glyphs ("Add a web app" on the +, the site name on each icon), the dock grid button ("Show apps") and the monitor star (its pin state).
  - Verify: the lint passes, and a hover screenshot in `ui-test.sh` shows the tooltips.
- **S4. Drawer sign-in pop-up and media permissions** (Security, Everyday, Access)
  - Replace `.title("Sign in")` (`drawer-host/src/main.rs:448`) with the live host and a lock icon.
  - Camera, microphone and screen share get a per-site prompt that names the site, is denied by default, and can be revoked from the right-click menu.
  - An active call is exempt from idle unload.
  - Verify: the local test page from test plan #9 (`window.open`, `getUserMedia`, `getDisplayMedia`) gives a screenshot of the host-titled pop-up, and nothing is granted without a prompt.
- **S5. Timer discipline** (Mobile, Quality)
  - A bats grep fails on any repeating `timeout_add` without a `// why:` comment.
  - Read all 11 call sites.
  - The drawer's 200 ms hover poll (`drawer/extension.js:288-311`) becomes motion and leave signals plus one single-shot timer.
  - Verify: the grep passes, `drawer-test.sh` hover checks pass, and a short `measure.sh` A/B with a drawer opened by hover shows no extra wakeups.
- **S6. "Start here" in the store** (Everyday)
  - `tools/welcome/data/recommended.toml` drops the DRAFT note and adds mail (Thunderbird), photos, LibreOffice, Discord and Steam, with nothing pre-ticked.
  - The Updates page gets one line: "Some Ubuntu apps update in App Center".
  - Verify: the Flathub ID test (`tools/welcome/src/lib.rs:440`) passes, and Everyday's search test (`store-test.sh` with thunderbird, steam, spotify, zoom, libreoffice and telegram) shows the intended app in the top three before the list ships.
- **S7. `ostrich doctor`** (Quality, Maintainer, Power)
  - In `tools/ostrich/src/main.rs`: list each extension's state and the shell errors in its journal, flag INACTIVE ones, and add `ostrich config disable <ext>` that works over SSH.
  - Verify: in the VM, a deliberately broken extension is named.
- **S8. Fix stale docs**
  - `docs/PARITY.md:37` becomes the real defaults: 30/40/60, brightness 0.7–1.0.
  - Do not touch `DESIGN.md:266`; that is owner question 7.
  - Verify: diff review.
- **S9. High contrast preset** (Access, Design)
  - One switch on the Blur page of Ostrich Settings: all blur surfaces off (the existing booleans) and 2 px focus rings. It works on AC too.
  - Verify: a `compare.sh` scene with the preset on passes `contrast.sh` at 4.5:1, and turning it off restores the owner's values exactly.
- **S10. Re-capture the tour buttons with the window focused** (Newcomer, Access)
  - If "Next" is under 4.5:1, make it a suggested-action button (`tools/welcome/src/main.rs`).
  - Verify: `contrast.sh` on a focused `settings/welcome.png`.
- **S11. `ostrich config` and the chezmoi dconf layer** (Power, Owner), after the owner answers question 7.
  - Reads the installed schemas at runtime: list, get, set, reset, diff, export and import.
  - `home/` gets `settings.dconf` and a `run_onchange_` loader that never sets a command key.
  - Add the schema-key parity test in bats: every key has a Settings widget or a "file-only" line in `docs/DEFAULTS.md`.
  - Verify: the round trip in experiment X3.

### Experiments

- **X1. Static wallpaper blur on battery** (Mobile, Low-end)
  - **Try:** a key `static-blur-on-battery` (default false), alongside the existing power-saver step-down.
  - **Measure:** on the Dell, booted from the external SSD and on battery in Balanced, 30 minutes idle plus an overview loop. Compare `powertop` package watts and gnome-shell CPU between live and static, three runs each, plus a `compare-glass` screenshot.
  - **Keep** (and offer it as the default on battery, if the owner agrees) if watts or shell CPU drop by more than the spread between runs and the screenshot still shows colour from the photo.
  - **Revert** if there is no difference larger than the noise.
- **X2. Weak-GPU automatic solid surfaces** (Low-end)
  - **Measure:** blur at defaults against all blur off, on `VM_CPUS=2 VM_MEM=4G` with software GL, three runs of `shell-bench.sh overview`.
  - **Keep** a detector only if the overview with blur is more than double the solid run. It must never fire on the Dell's iGPU, it must show its decision ("auto: software renderer"), and it must be overridable.
  - **Drop** if blur is within 20 % of solid.
- **X3. dconf round trip** (Power)
  - **Measure:** `dconf dump` our paths, change 10 keys, `dconf reset -f`, `dconf load`.
  - **Pass:** all 10 keys and a screenshot match, and every extension stays ACTIVE with no restart. **Fail:** any key is lost, or an extension needs a restart. If it fails, S11 waits.
- **X4. Keyboard completeness** (Power, Access)
  - **Measure:** Super+1..9, the tiling shortcuts, and a list of duplicate bindings (test plan #15c); then a Tab walk with full-size screenshots.
  - **Pass:** no duplicates, and every stop shows visible focus. **Fail:** any clash or a stop with no focus. Each failure becomes a Should item.
- **X5. Orca** (Access)
  - **Measure:** on real hardware, Orca reads the drawer +, the monitor star, the Today card and the sign-in pop-up title.
  - **Pass:** every one is announced with a name and role. **Fail:** any is silent, and then it moves up to Must.

### Not now

- **Shared design tokens** (Design).
  - What: one table of radius, padding, row height and alpha values. T18 proved the inconsistency: 9 radius values and 12 padding values.
  - Where: `modules/gnome/extensions/*/stylesheet.css`.
  - Serves: the owner and Daniel (polish).
  - Verify: the T18 grep shows at most 4 values per property, and `compare.sh` shows no regression on the surfaces the owner tuned.
  - Why it waits: a restyle risks the owner's tuned glass. Until then, items that touch CSS should reuse existing values, not add new ones.
- **Daily GitHub-app update timer** (Security).
  - What: a user systemd timer, AC-only, unmetered, `Persistent=true`, `RandomizedDelaySec`. It notifies and never installs, and has a Settings switch.
  - Where: `modules/tools/`, `tools/store-core`.
  - Serves: everyone who installs from GitHub.
  - Verify: `systemctl --user list-timers`, and no run on battery.
  - Why it waits: the store's update check when its tab opens covers this for now.
- **Folding Ostrich Settings pages to about 11** (Simplicity).
  - Where: `tools/welcome/src/main.rs`.
  - Serves: Rosa.
  - Verify: the key parity test still passes, and every key is still reachable.
  - Why it waits: no evidence, and it collides with principle 7.
- **"Getting started" page with "Show me" buttons** (Newcomer).
  - Where: `tools/welcome`.
  - Serves: Rosa.
  - Verify: a new user finds "change the wallpaper" and "add a web app" from the page.
  - Why it waits: it is opinion, with upkeep.
- **Search providers off by default, with a labelled switch** (Simplicity, Security).
  - Where: `modules/gnome/install.sh`.
  - Serves: Priya (privacy).
  - Verify: overview search sends no web query.
  - Why it waits: no measured gain.
- **Branded fallback tile for GitHub apps with no icon** (Design).
  - Where: `tools/store-core/src/ghinstall.rs:65`.
  - Serves: everyone who installs from GitHub.
  - Verify: an installed fixture shows the tile.
  - Why it waits: it builds on M2's template, so it comes after M2.
- **Matched-baseline resource report** (Low-end).
  - What: add the top-15 PSS table and the "ours" figure to `tests/vm/measure.sh` and `docs/BASELINE.md`, as a reported number, not a gate.
  - Verify: present in `baseline.sh report`.
  - Why it waits: M3 records the first number by hand; automating it can follow.

## Rejected

- **Top-process and GPU-holder rows in the Today card** (Owner R1): it adds a `/proc` read on every open, duplicates the monitor, makes the card fat, and the owner's own seat withdrew it.
- **User-command card in Today** (Power): an imported keyfile could make it run code every time the menu opens (Security). Power dropped it.
- **Quick-toggle row in Today** (Design R1): it duplicates Quick Settings. Design withdrew it.
- **Hiding App Center** (Simplicity R1): Ostrich Store can't install or update snaps (facts row 8).
- **Merging the small extensions** (Simplicity): never measured, half the named targets aren't ours, and it goes against principle 5.
- **Removing the dock grid button** (Simplicity R1): Rosa needs it. Withdrawn.
- **Treating "+63 % memory" as evidence** (several seats): T1 shows the rest of the gap is base-image difference. The measured fact is our 438 MB.
- **Weather consent prompt** (Mobile, Security): T3 shows no weather card on a fresh install, so nothing is fetched.
- **The "experimental feature" warnings as our bug** (Quality): T13 disproved it.
- **A hard memory gate in CI** (Low-end R1): it would fail on base-image differences. Low-end conceded.

## Owner vs most people

- **Glass vs contrast.**
  - Owner: glassy, 93 % of the brightness behind showing through (note 193727).
  - Daniel and most people: readable text.
  - Default: the owner's glass stays untouched. Only the measured failures change (M5), because body text already passes at 6.4:1 or better (T5).
  - Both win: a High contrast preset (S9) gives solid surfaces to anyone who needs them.
- **Dense vs large targets.**
  - Owner: "really fat, takes up a lot of room" (032706).
  - Access: 24 px targets.
  - Default: the owner's row density stays.
  - Both win: later target work enlarges only icon-only buttons (the star and footer buttons), measured with a `compare.sh` scene against the current popup height, and the High contrast preset is where larger layout lives.
- **Drawer sites ready vs memory.**
  - Owner: sites start hidden so they can notify (DEFAULTS.md:15).
  - Tomás and most people: memory. 520 MB at login is about 7 % of an 8 GB machine.
  - Default: only keep-alive sites load at login, which is what DESIGN.md:114 already says.
  - Both win: right-click any site, "keep loaded in the background", to have it ready and notifying.
- **Live blur on battery.**
  - Owner: live glass.
  - Mobile and Low-end: battery.
  - Default: unchanged; power saver still goes static, as now.
  - Both win: experiment X1 decides whether a "static blur on battery" switch is worth turning on by default.

## Questions for the owner

1. **Which drawer starters stay loaded at login?** DESIGN.md:114 says "only keep-alive services (messaging)". T1 found all four loaded, about 520 MB.
   - *Default if you don't answer:* Google Messages and Google Chat keep-alive; Claude and YouTube load when you first open them.
2. **Notification permission for drawer sites.** DESIGN.md:110 grants it to every site up front. Security wants it only for catalog sites or sites you switch on, and a prompt for addresses you add with +. This would change DESIGN.md.
   - *Default if you don't answer:* no change. Every site keeps the up-front grant as written.
3. **Promptless root actions.** Principle 6 says every privileged action asks for confirmation, and DESIGN.md:186 exempts only the touchscreen. M6 makes graphics changes ask for a password, but keeps `power apply` promptless so the automatic switch to power saver at 20 % never shows a password dialog on a low battery. May DESIGN.md list `power apply` as a second exception?
   - *Default if you don't answer:* yes. Power stays promptless, and DESIGN.md gets the extra line once you approve it.
4. **Is "Events hidden plus a redesigned This computer card" the "something else" you meant in note 032844?**
   - *Default if you don't answer:* yes. M1 ships as written, and Events comes back with "Show calendar events" in Ostrich Settings, Top bar page.
5. **Who uses the icon program: Claude, or you by hand?** Note 032921 reads either way.
   - *Default if you don't answer:* a template plus a script in `tools/icons/` that Claude drives. Inkscape stays an optional install from Ostrich Store for hand-editing, and the installer never adds it.
6. **Settings icon glyph.** Sliders (my choice, so it isn't confused with GNOME Settings' gear) or a gear (Design's first idea)?
   - *Default if you don't answer:* sliders.
7. **The dotfiles promise.** DESIGN.md:266 says chezmoi carries "mise, the drawer and palette configs", but `home/` has none of them (facts row 21). Build them (S11), or shorten the line?
   - *Default if you don't answer:* keep the promise and build it in S11, after experiment X3 passes.
8. **Widevine (Spotify, Netflix in the drawer).** It would be downloaded at install time, not committed, but it is closed-source third-party code.
   - *Default if you don't answer:* no. The drawer's honest "doesn't work yet" text stays, and DRM sites get an "Open in browser" button.
9. **Static blur on battery.** If experiment X1 shows a real saving on the Dell, may it become the default on battery, with a switch to keep live glass?
   - *Default if you don't answer:* no. Live glass stays on battery, and the switch exists but is off.

