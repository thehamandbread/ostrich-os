# Verdict: quick settings and the clock menu: fewer clicks, and what lives where

## Summary

The council agrees on the core fix. On a machine with three power profiles, GNOME's Power Mode tile needs three clicks to reach a given mode: open, arrow, item. Test 1 reproduced this, so the owner's count is right. The fix is a full-width Saver | Balanced | Performance row, shown only on those machines. Machines with two profiles keep GNOME's tile, which is already one click once quick settings is open.

Test 4 turned up a defect nobody had planned for. The white labels on lit tiles measure 3.32–4.19:1, which breaks DESIGN.md's own 4.5:1 rule for text on an accent. That gets fixed before anything new reuses the fill.

Focus and Do Not Disturb get switches in the clock menu, as the owner asked. Each switch shares one state with its quick-settings tile, and the tiles stay. Everything that hides a GNOME tile goes through one guarded helper. A single `quick-settings-style: ostrich|stock` key puts GNOME's quick settings back.

Bluetooth device shortcuts are worth building, but they move to Should. They wait for a mock BlueZ, because nothing can test them without one.

Two findings change the ground under the debate:
1. **Critique 20261101-224331 ("two sets of circles") was about the monitor popup, not quick settings.** Its `note.json` boxes `ost-vital-profile` and `ost-vital-button`: the monitor's power row sat above its footer buttons, on build 0.1.5. That row was removed on 2026-11-09, so the complaint is already answered. Restyling quick settings' top row is still reasonable as part of "looks much better", but on taste and family look, not on that note.
2. **"Make the whole Bluetooth tile open the list" still takes 3 clicks** (open quick settings, the tile, the device). It only makes a target bigger. Two clicks needs device rows that are visible as soon as a menu opens.

The owner chooses the layout from three options below. I recommend Option B.

## Rulings

1. **Power Mode: a row everywhere, a row only on three-profile machines, or a patched stock tile?**
   - Sides: all twelve seats converged on "three profiles only" after facts note 2 and test 1. Nobody still argues for a cycle: facts row 2 refuted it.
   - **Ruling:** build the segmented row only when power-profiles-daemon lists three profiles. Two-profile machines keep GNOME's tile untouched. If the daemon later drops to two profiles, the row removes itself and the stock tile comes back.
   - **Why:** test 1 proved 3 clicks on the stock tile with three profiles, and showed its body never reaches Power Saver. On two profiles nothing is gained, so nothing is touched there.
   - **"1 click from the top bar":** what this delivers is 1 click once quick settings is open, which means a top-right corner push plus 1 click, or 2 clicks by mouse. A true single click from the bar itself is not proposed (see Questions).

2. **The lit-tile fill.**
   - **Ruling:** every text on an "on" fill must reach 4.5:1. That covers GNOME's lit tiles, their arrow halves, our segments and our switches, in light, dark and power saver. It reverses the 2026-11-05 ruling 9 ("no fill or class changes").
   - **Why:** test 4 measured 3.83–4.05:1, and test 9 measured 3.32–4.19:1 in saver. DESIGN.md:151 already requires `accentStrong` or black text on an accent.
   - The fill itself is a matter of taste, so it differs between the options. "No Notifications" at 4.26:1 in saver is fixed in the same change.

3. **Focus and DND: both places on one state, or one place?**
   - Sides:
     - Both places: owner, design, access, everyday, lowend, newcomer; security accepts a mirror.
     - One place: maintainer and power (Focus moves, DND stays), simplicity (nothing moves), mobile, quality.
   - **Ruling:** both places. The clock menu gets two switches, DND bound to `org.gnome.desktop.notifications show-banners` and Focus to one Focus state key. The quick-settings tiles stay. GNOME's DND tile is never hidden, so `_doNotDisturb` stays untouched.
   - **Why:** each control has one gsettings source, so the copies can't drift. Everyday's argument holds against quality's drift worry, and the sync test pins it.
   - Keyboard and Orca users keep DND where it was. Access's red line holds.
   - There is no per-item "where does it live" matrix (maintainer, simplicity, everyday). One boolean, `clock-menu-quiet`, turns the clock copies off, the same shape as `show-events`.

4. **Bluetooth: where the devices live, and how many clicks.**
   - **Ruling:** build lazy "recent devices" rows. These are up to 3 paired devices, connect and disconnect only, built from a `GnomeBluetooth.Client` when the menu opens and freed when it closes. They appear only while an adapter exists and Bluetooth is on. GNOME's Bluetooth tile is never hidden by default.
   - This is **Should**. It is gated on `tests/vm/mock-bluez.py` and a ui-test case, as maintainer, quality, simplicity, everyday and mobile asked.
   - Where the rows live is the owner's choice, and it is the main difference between the options: as device tiles in quick settings (A, C), or as rows in the clock menu (B).
   - **Why:**
     - Only rows that are visible on open meet the 2-click target.
     - Lowend's lazy build avoids the resident BlueZ watcher that power's pinned tiles would need.
     - Hiding `_bluetooth` buys nothing once the stock tile can simply stay.
     - Test 2 shows that a menu opened by resting the pointer or by a key activates nothing on GNOME's own rows. Our rows must pass the same test before they ship.

5. **Media card: replace it or restyle it?**
   - **Ruling:** restyle GNOME's card in CSS only (Should), with transport buttons at least `target_comfort`.
   - **Why:** DECISIONS.md:145 keeps it. A replacement adds a second MPRIS client (lowend), and every seat that proposed replacing it withdrew. GNOME 50's class name for the card is unverified (facts row 8), so the build starts by finding it.

6. **Sound and mic.**
   - **Ruling:** they stay in quick settings, unchanged. No output picker moves to the clock menu.
   - **Why:** they are GNOME's `_volumeOutput` and `_volumeInput`, and moving them means re-parenting (maintainer). The owner's note never asked for it (owner seat, round 2). Facts row 4 says GNOME adds its own output chooser on real hardware.

7. **The top row of four round buttons.**
   - **Ruling:** Options A and B restyle it in CSS only: flat rounded squares at `radius_item`, same order, same size. Option C replaces it with a labelled footer, which needs a guarded reach into GNOME's private `_system`. Choosing C is the "council nod" the maintainer requires for a third private field.
   - **Rejected:** folding the buttons into the power menu (needs more private reach and loses one-click Lock), and dropping Screenshot (newcomer is right; simplicity withdrew).
   - **Why:** St CSS cannot add text, so visible labels need JS. That is my reading; test 14 did not run.

8. **Target sizes.**
   - **Ruling:** no 44 px or 48 px rule; every seat now labels those figures opinion (facts rows 62–63).
     - Power segments are as tall as a quick-settings tile (about 48 px at 1x, read from `t1-3profiles-qs-crop.png`) and a third of the row wide.
     - New rows and switches are at least `target_comfort`, and full column width.
     - Nothing new goes under `target_min`.
   - No new token this round.

9. **Ways back.**
   - **Ruling:** one `quick-settings-style` key (`ostrich` or `stock`). Disabling the extension restores every hidden tile. Power's `quick-settings-layout` and `quick-settings-actions` go to Not now.
   - **Why:** maintainer, security, simplicity, quality and owner converged on one key. A layout engine is more code and more test combinations for few users.

10. **Clock menu size (M5).**
    - **Ruling:** it stays 688 × 468 at 1x. Every new section scrolls inside the right column (DECISIONS.md:143).
    - The screen-height cap that `tweaks/stylesheet.css.in:8-9` already lists as a shortcut gets built if the 768-high test fails (Experiment X2).
    - **Why:** test 5 proved fixed bounds with 0 and 5 notifications. At 2x the menu is about 1374 × 960, which fits 1080 high; 768 was not tested.

11. **The orb's default.** The gschema ships `now-playing-pill` on, while DESIGN.md:57 and DECISIONS.md:145 say off until idle measurement E1 passes. Changing DESIGN.md is the owner's call, so this goes to Questions, with E1 as Experiment X1.

## Scorecard

Scores 1–5. The total is weighted: Reach ×3, Impact ×3, Cost ×2, Risk ×2, Effort ×1, Evidence ×2. The maximum is 65.

| # | Proposal | Seats | Reach | Impact | Cost | Risk | Effort | Evidence | Total |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Lit-state contrast fix (tiles, segments, switches, saver) | access, design, quality, newcomer, security, lowend, mobile, everyday | 5 | 3 | 5 | 4 | 4 | 5 | **56** |
| 2 | Test fixtures first: 3-profile fixture, menus in ext-test, no-activation on new rows, contrast in look-check | quality, maintainer, lowend, security, power | 3 | 3 | 5 | 5 | 4 | 5 | **52** |
| 3 | Clock menu on tokens (14→`radius_card`, 9→`radius_item`), scroll inside | design, access, quality | 4 | 2 | 5 | 5 | 5 | 4 | **51** |
| 4 | Power segmented row, three-profile machines only | all 12 | 3 | 4 | 5 | 3 | 3 | 5 | **50** |
| 5 | Focus and DND switches in the clock menu, one state, tiles stay, top-bar mark (merged) | owner, design, access, everyday, lowend, newcomer, security | 4 | 3 | 4 | 4 | 3 | 3 | **46** |
| 6 | `hideStockTile` helper + `quick-settings-style` + restore on disable | maintainer, quality, security, power, owner, simplicity | 3 | 3 | 5 | 4 | 4 | 3 | **46** |
| 7 | `hover-open-delay-ms` key (floor 500) | power, access, security, mobile | 3 | 2 | 5 | 5 | 5 | 3 | **46** |
| 8 | Privacy dots kept at 4.5:1, checked | security | 5 | 2 | 5 | 5 | 3 | 1 | **46** |
| 9 | Tour and Settings text naming the corner and the clock menu | newcomer | 3 | 2 | 5 | 5 | 5 | 2 | **44** |
| 10 | Focus moves, DND stays (one home each) | maintainer, power, quality, mobile | 3 | 2 | 5 | 4 | 4 | 3 | 43 |
| 11 | Top row: CSS flat restyle | maintainer, design, quality, power, simplicity, everyday, lowend | 4 | 2 | 5 | 3 | 5 | 2 | 43 |
| 12 | Bluetooth recent devices, lazy, 2 clicks | owner, everyday, power, lowend, mobile, design, newcomer, simplicity | 4 | 4 | 4 | 2 | 2 | 2 | 42 |
| 13 | GNOME media card: CSS restyle | owner, design, everyday, lowend, maintainer, simplicity, access | 4 | 2 | 5 | 3 | 4 | 2 | 42 |
| 14 | Hot corner beside a right-hand monitor, plus a corner test | quality, power | 2 | 2 | 5 | 4 | 4 | 4 | 42 |
| 15 | Labelled footer (Option C) | newcomer, access, owner, design (C) | 4 | 3 | 5 | 2 | 2 | 2 | 41 |
| 16 | Remove the "This computer" card | simplicity (withdrawn to owner) | 2 | 1 | 5 | 5 | 5 | 2 | 38 |
| 17 | Keybinding add/remove asymmetry fix | quality | 1 | 1 | 5 | 5 | 5 | 3 | 37 |
| 18 | Hide GNOME's DND tile, DND only in the clock menu | simplicity (withdrawn) | 3 | 2 | 5 | 2 | 3 | 2 | 36 |
| 19 | `hoveropen` close check slower in saver | mobile | 2 | 1 | 4 | 4 | 4 | 3 | 35 |
| 20 | Bluetooth tile replaced, whole tile opens list | simplicity, everyday, newcomer | 4 | 2 | 4 | 2 | 2 | 1 | 34 |
| 21 | Screenshot to the Print key only | access (conceded), simplicity (withdrawn) | 1 | 1 | 5 | 5 | 5 | 1 | 33 |
| 22 | Fold the four buttons into the power menu | owner (alt), simplicity | 3 | 2 | 5 | 1 | 2 | 1 | 31 |
| 23 | Per-item layout matrix (`quick-settings-layout`) | power, owner (r1) | 2 | 2 | 4 | 2 | 2 | 2 | 30 |
| 24 | Replace GNOME's media card | design, owner (both withdrew) | 3 | 2 | 3 | 2 | 2 | 1 | 29 |
| 25 | Sound, mic or output picker into the clock menu | design, power (r1) | 2 | 2 | 4 | 1 | 2 | 1 | 26 |

Row 12 scores 2 on evidence and goes to Should, because nothing can test it yet: there is no adapter and no mock. Row 8 goes to Experiments for the same reason: there is no mic in the VM.

## The plan

The Must items are written for Option B, my recommendation. Where Option A or C changes an item, it says so.

### Must (this round)

**M1. Fixtures and gates first** (quality, maintainer, lowend, security)
- **What:**
  - `tests/vm/ppd-three.sh`: a VM-only systemd drop-in, `Environment=POWER_PROFILE_DAEMON_FAKE_DRIVER=1`, then a power-profiles-daemon restart. This is the clerk's test 1 setup made permanent; no `mock-ppd.py` is needed.
  - `tests/vm/ext-test.sh`: open and close both menus in each of the 20 cycles. `RSS_LIMIT_MB=15` stays. The baseline from test 3 is +12 MB for the first 20 cycles, then +0.
  - `tests/vm/topbar-test.sh`: test 2's no-activation scene. Open by resting the pointer and by key, with the pointer parked where a row will appear, then sweep, then click outside. Read `show-banners`, the Focus key and `powerprofilesctl get`. Extend it to the power segments and the Quiet switches.
  - `tests/look-check.sh --vm`: `contrast.sh` boxes on every on-state label, in light, dark and saver, over `mendhak-Red_Acer.jpg`.
- **Serves:** everyone, through the gates.
- **Verified by:** each passes on `try-me-0.2.0`, except contrast, which must fail today and pass after M4.

**M2. One guarded hide helper and the way back** (maintainer, quality, security, power, owner)
- **What:**
  - `hideStockTile(quickSettings, field, owner)` in `_lib/patches.js`. It sets the field's `quickSettingsItems` invisible and returns a restore function, which `disable()` calls. An `undefined` field means GNOME renamed it: it warns once and leaves stock. A `null` field means absent by configuration: it stays quiet (facts note 5).
  - Used for `_powerProfiles` only this round.
  - New tweaks key `quick-settings-style` (`'ostrich'` or `'stock'`, default `'ostrich'`).
- **Where:** `_lib/patches.js`, `tweaks/extension.js`, the tweaks gschema, `tests/js/patches.test.js` (fake `statusArea`: present, missing and null fields), `tests/vm/dconf-test.sh` (tile list before and after disable, and stock → ostrich → stock).
- **Serves:** the owner, Priya, anyone after a GNOME update.
- **Verified by:** the unit test; stock tiles visible after every disable in `ext-test.sh`; zero "no longer has" lines on a machine with no adapter.

**M3. The power row** (all seats)
- **What:** new `tweaks/powerrow.js`, a two-column `QuickSettingsItem` added with `addExternalIndicator(indicator, 2)`.
  - It holds three equal segments, Power Saver, Balanced and Performance (GNOME's own words), each with icon and text.
  - It reads `Profiles` and `ActiveProfile` from power-profiles-daemon over D-Bus, using property-change signals and no timer.
  - It is built only when there are three or more profiles, and then hides `_powerProfiles` through M2. If the profile count changes, it removes itself and restores stock.
  - The active segment uses the option's on-state fill plus bold text. Its accessible name is "Power mode: Balanced, selected". Arrow keys move between segments, and Enter or Space selects.
  - The monitor extension still applies the hardware knobs on the profile change (DESIGN.md "Power modes").
- **Serves:** the owner, Kai and Priya on three-mode laptops. Tomás and Rosa on two-mode machines see no change.
- **Verified by:**
  - With the M1 fixture: each mode takes 1 click after opening, screenshot plus `powerprofilesctl get`.
  - On the stock two-profile VM: the row is absent and the stock tile shows.
  - M1's no-activation, RSS and contrast gates pass.
  - Text scale 2.0: no clipped labels.
  - The journal is clean.

**M4. On-state contrast** (access, design, quality, newcomer, security, lowend, mobile, everyday)
- **What:** in `tweaks/stylesheet.css.in`, override GNOME's checked quick-toggle fill and text, including the arrow half, and use the same rule for our segments and switches. The fill is the chosen option's. Also make "No Notifications" use the full text colour on saver's solid black.
  - GNOME 50's exact class names get confirmed against `gnome-shell-sass` 50 before writing.
  - Fixed colours go through palette tokens, so `token-lint.sh` stays green.
- **Serves:** Daniel, Rosa, everyone in power saver.
- **Verified by:** M1's contrast step shows every on-state label at 4.5:1 or better in light, dark and saver. Run it with the slate, orange, blue and yellow accents (the worst cases for white text) and with the owner's scheme.

**M5. The clock menu's Quiet section, on tokens** (owner, design, access, everyday, lowend, newcomer; security's mark)
- **What:** in `tweaks/today.js`, below the date in the right column, add two full-width switch rows, "Do Not Disturb" and "Focus", each with On or Off in text and at least `target_comfort` tall.
  - DND binds to `show-banners`, inverted.
  - Focus binds to a new `focus-on` key in the focus schema. Only the focus extension's `_set()` acts on it, and `enable()` brings it back in line with `saved-show-banners`. This gives one source of state and lets Priya use `ostrich config set focus focus-on true`.
  - The widgets are built when the menu opens and freed when it closes.
  - A new tweaks key, `clock-menu-quiet` (boolean, default true), hides the section.
  - The Focus tile gets its On/Off subtitle (2026-11-05 ruling 9, never built).
  - Check that GNOME's own DND mark shows in the top bar. Facts note 4 says `MessagesIndicator` follows `show-banners`. Build a Focus mark only if Focus leaves none visible.
  - Token pass in the same stylesheet: `.ost-today-card` 14px → `[[radius_card]]`; `.ost-today-body` and `.ost-today-link` 9px → `[[radius_item]]`.
- **Under Option A:** only the token pass and the Focus subtitle.
- **Serves:** the owner (the "shade" he asked for), Rosa and Daniel (tiles stay where they look).
- **Verified by:**
  - Sync test: toggle from the tile, from the switch and from `gsettings`, and read all three each time.
  - The no-activation test on the new rows.
  - Tab reaches both switches, and Escape returns focus.
  - The test 5 bounds stay identical with 0, 1 and 5 notifications at 1x; nothing is clipped at 2x.
  - `ext-test.sh` RSS stays within limits.

**M6. The top row, per the chosen option**
- **What:**
  - A and B: CSS in `tweaks/stylesheet.css.in` turns GNOME's four system buttons into flat rounded squares at `[[radius_item]]`, with today's size, order and actions, and a neutral fill.
  - C: see Option C.
- **Serves:** the owner (looks), Rosa and Daniel (C).
- **Verified by:** light, dark and 2x screenshots; `look-check.sh` and `token-lint.sh` green; Lock and Power still one click; Power keeps GNOME's confirmation.

**M7. Words, Settings and the tour** (newcomer; DESIGN.md principle 7)
- **What:**
  - Ostrich Settings, Top bar page: rows for `quick-settings-style` and `clock-menu-quiet`.
  - Power page: one line saying the row appears on machines with three modes.
  - Tour text on existing pages names the top-right corner and the clock menu's Quiet switches. The tour stays at 13 pages.
  - The Settings search index includes the new rows.
- **Where:** `tools/welcome/src/main.rs` and its page definitions.
- **Serves:** Rosa, Priya.
- **Verified by:** searching Settings for "Do Not Disturb" and "quick settings" finds the rows; screenshots of the pages.

### Should (next)

- **S1. Bluetooth recent devices** (owner, everyday, power, lowend, mobile, design, newcomer, simplicity).
  - First `tests/vm/mock-bluez.py`: two paired devices, one that fails to connect.
  - Then `tweaks/btdevices.js`: up to 3 most-recently-connected paired devices, from a `GnomeBluetooth.Client` built on open and freed on close. Connect or disconnect on a press that begins inside the row.
  - Each row shows its state in text: "Connected", "Connecting…", or "Couldn't connect. Is it on and in range?".
  - Nothing shows without an adapter or with Bluetooth off. There is no scan or pairing; the stock tile's "Bluetooth Settings" covers that.
  - Placement per the option. No hide of `_bluetooth`.
  - **Verified by:** ui-test connects in 2 clicks (B: a rest plus 1 click); the failure shows in text; the no-activation test; RSS; no watcher while the menu is closed.
- **S2. GNOME media card restyle** in CSS: buttons at least `target_comfort`, titles wrap, `radius_card`. The drawer's media session gets checked with `mock-mpris.py`.
- **S3. `hover-open-delay-ms`** (floor 500, default 500) in the tweaks gschema, read by `_lib/hoveropen.js:13`.
- **S4. Hot corner beside a right-hand monitor** (`tweaks/corner.js:33-36`), plus a `_place()` unit test with fake monitors and a `rel-pointer.py` corner test.
- **S5. Keybinding asymmetry fix** at `tweaks/extension.js:151,195,200`, with a journal check.
- **S6. The rest of the token pass:** `dock/stylesheet.css.in:56,77,81`, `blur/stylesheet.css.in:42`, `tiling/stylesheet.css.in:4,9`, and the orb's literal `32px`.

### Experiments

- **X1. The orb's idle cost (E1).**
  - Measure: `shell-bench.sh idle 60 3` with `now-playing-pill` on and off, nothing playing, then with `mock-mpris.py` playing and paused.
  - Keep it on by default if the idle median differs by 0.3 points or less and nothing runs while nothing plays. Otherwise ship it off. The docs follow the owner's answer (Questions).
- **X2. The clock menu at 2x on a 1366 × 768 screen.**
  - Measure: the card's bounds with 5 notifications and the Quiet section.
  - If the card ends below the screen, cap its height in `today.js` to the monitor's work area and scroll inside; otherwise keep the em size.
- **X3. Real hardware** (the external SSD on the Dell).
  - Measure: clicks to each power mode with the row (pass is 1 after opening). Once S1 lands, clicks to connect earbuds (pass is 2, or a rest plus 1 in B).
  - Revert the row if any mode needs more than 1 click or the tile and row both show.
- **X4. Privacy dots** at 4.5:1 or better in light, dark and saver, with a PipeWire capture stream (a mock or real hardware). If one fails, it gets a solid backing that is exempt from glass and folds.

### Not now

- **`quick-settings-layout` and `quick-settings-actions`** (power): a per-item layout engine. It would live in the tweaks gschema and a new `tweaks/quicksettings.js`, serve Priya, and be verified by stock round trips for every combination. It comes back if users ask for moves the two keys can't do.
- **A labelled footer under A or B** (newcomer, access): `tweaks/quickfooter.js`, a private `_system` reach. It serves Rosa and Daniel and would be verified with 2x screenshots. It is Option C's own item.
- **A whole-tile opener for GNOME's own tiles** (design r1): a patch to `QuickMenuToggle` behind `_lib/patches.js`. It would serve Daniel, but it gains no clicks (Ruling 4).
- **Slowing the hover-open close check in saver** (mobile): `_lib/hoveropen.js:80` with `PowerAwareTimer`. Test 10 showed no lasting cost; it can be revisited with hardware wakeup numbers.

## Rejected

- **"The stock tile is a blind cycle that overshoots."** Facts row 2 and test 1 show it is wrong; it is a toggle plus a submenu.
- **"Whole Bluetooth tile opens the list = 2 clicks."** Counted wrong: it is still open, tile, device (3).
- **"GNOME's Bluetooth list ignores Alias" and "GNOME 44 is connect-only"** as reasons. Facts rows 10 and 59: GNOME 50 uses alias.
- **Hiding GNOME's DND tile** (`_doNotDisturb`) so DND lives only in the clock menu. It adds a third private field and leaves keyboard users with no DND if the new widget fails (access). Simplicity withdrew it.
- **Re-parenting GNOME's volume and mic sliders** or any GNOME widget into the clock menu (maintainer's red line, unopposed by the end).
- **Replacing GNOME's media card with our own** for now. It reverses DECISIONS.md:145 and adds a second MPRIS client; both proposers withdrew.
- **Pinned Bluetooth tiles with a resident BlueZ watcher** (power r2). The lazy rows in S1 give the same 2 clicks with nothing running while the menu is closed (lowend).
- **Folding the four buttons into the power menu**, and **Screenshot only on the Print key**: more private reach, and Lock stops being one click. Removing Screenshot is a feature cut with no gain (newcomer, design, maintainer).
- **A 44 or 48 px rule**: opinion in every seat's own closing (facts rows 62–63). Ruling 8 sets the sizes.
- **A cycling output-device chip** (design r1): it hides the options, as access argued, and sound stays put (Ruling 6).

## Owner vs most people

- **Bluetooth in the clock menu.** The owner asked for it (note 20261109-173903, "maybe"). Most people look for Bluetooth in quick settings first; that is newcomer's and everyday's reading of Rosa, and it is opinion. Mobile, everyday and security also dislike radio actions in a menu that opens when the pointer rests on it.
  - Both win in Option B: the device rows sit in the clock menu, but GNOME's Bluetooth tile stays in quick settings with its full list, so Rosa still finds it there. Rows need a press that begins inside them (test 2 extended).
  - If the owner picks A or C, the rows sit in quick settings instead.
- **Focus and DND in two places.** The owner wants them by the clock. Rosa and Daniel look in quick settings. The default is both, on one state, and `clock-menu-quiet` turns the clock copies off.
- **Hover-open and the hot corner** stay on by default, as the owner decided. Access and security get click and key opening everywhere (already true), the no-activation gate, and the S3 delay key.
- **The orb.** The owner wants it, and DESIGN.md says off until E1. X1 measures it, and the owner decides (Questions).
- **The "This computer" card** stays. It came from the owner's critiques, and simplicity and newcomer would cut it; only the owner removes it.

## Options for the owner

All three share the Must items M1–M4 and M7 and these common specifications:

- **Power row:** on three-profile machines only, a full-width Saver | Balanced | Performance row sits where the Power Mode tile was. On two-profile machines GNOME's tile is untouched.
- **GNOME tiles hidden:** only Power Mode, and only on three-profile machines, through `hideStockTile`, with stock back on any failure or on `quick-settings-style = stock`.
- **Sound and mic:** GNOME's own sliders, unchanged.
- **Contrast target:** every text on an on-state fill is 4.5:1 or better, measured by `contrast.sh` over the busy photo in light, dark and saver, with GNOME's accents and the chosen scheme. Off-state labels stay where they are (6.9–11.9:1 today).
- **Glass:** the same `glass_menu` and `light_glass_menu` as today, solid black in saver.
- **Corners:** `radius_panel` for quick settings, `radius_menu` for the clock menu, `radius_card` for cards, `radius_item` for rows and buttons, `radius_pill` for the orb.

### Option A, "Tidy in place"

**Quick settings, top to bottom:**
1. Top row: Screenshot, Settings … Lock, Power. Four flat rounded squares (`radius_item`), today's size and positions, icon only, a neutral fill.
2. Output volume slider (GNOME's).
3. Mic slider (GNOME's behaviour).
4. Wired or Wi-Fi | Bluetooth (stock, arrows stay).
5. On three-profile machines, the power row; otherwise the Power Mode tile in its usual place.
6. Dark Style | Do Not Disturb.
7. Saved workspaces | Focus (subtitle "On" or "Off").
8. Speakers and Touchscreen where detected.
9. Later (S1): up to 3 Bluetooth device tiles under the Bluetooth row, two per row, while Bluetooth is on.

**Clock menu:**
- Left: GNOME's notification list (the media card on top while something plays, restyled in S2), a compact "No Notifications", Clear.
- Right: date, the "This computer" card, "Add World Clocks…". Nothing new.

**On-state fill:** the palette's `accentStrong` (the accent darkened just enough, DESIGN.md:151) under white text. Today no extension reads `accentStrong`, so the build must confirm it reaches the shell stylesheet when the accent changes.

- **Backed by:** maintainer, simplicity, quality, mobile, security, power (its v1 stance).
- **Cost:**
  - About 100 lines for the row, 25 for the helper, plus CSS.
  - One private field (`_powerProfiles`), on three-mode machines only.
  - GNOME 51 risk: CSS class names (a visual break that look-check catches) and that one field (it falls back to stock).
- **What it doesn't do:** the owner's "shade" request, which is not met.

### Option B, "The owner's split" (recommended)

**Quick settings:** exactly as Option A, items 1–8. No Bluetooth device tiles in quick settings.

**Clock menu, left column:** as Option A (notifications with GNOME's media card on top while playing).

**Clock menu, right column, top to bottom:**
1. The date.
2. "Do Not Disturb", a switch row with On or Off in text, bound to `show-banners`.
3. "Focus", a switch row with On or Off, bound to `focus-on`. Both rows are full width, at least `target_comfort`, `radius_item`, and the on-state fill marks the switch.
4. Later (S1): "Bluetooth", up to 3 recent paired devices as rows ("Earbuds · Connected"), press to connect or disconnect, shown only while Bluetooth is on.
5. The "This computer" card (`radius_card`).
6. "Add World Clocks…".

The right column scrolls inside 688 × 468.

**On-state fill:** `accentStrong` under white text, as in Option A.

- **Backed by:** owner, design (its "Option B"), everyday, access and newcomer (Focus and DND in both places), lowend (static switches, lazy rows). Mobile, everyday, security, simplicity and maintainer object to the Bluetooth rows being here rather than in quick settings.
- **Cost:**
  - Option A's cost plus about 120 lines in `today.js`, one key in each of the tweaks and focus schemas, and the sync and no-activation tests.
  - S1 later adds about 150 lines plus the mock.
  - No new private field. GNOME 51 risk is the same as A: our own widgets sit in our own column.
- **Clicks:** earbuds take a rest plus 1 click, or 2 clicks; a power mode takes 1 click after opening.

### Option C, "Labelled panel"

**Quick settings, top to bottom:**
1. Output volume slider.
2. Mic slider.
3. Wired or Wi-Fi | Bluetooth (stock).
4. Power row on three-profile machines, otherwise the Power Mode tile.
5. Dark Style | Do Not Disturb.
6. Saved workspaces | Focus (On or Off).
7. Speakers and Touchscreen where detected.
8. Later (S1): up to 3 Bluetooth device tiles.
9. Footer: four equal labelled buttons, "Screenshot", "Settings", "Lock", "Power Off", each icon plus word, `radius_item`, at least `target_comfort`, in one row across the panel. At 2x text a label may wrap to two lines.

The round top row is gone. GNOME's system buttons are moved into the footer through a guarded `_system` reach. If it fails, the stock row comes back.

**Clock menu:** as Option B without the Bluetooth section: date, the Do Not Disturb and Focus switches, "This computer", "Add World Clocks…".

**On-state fill:** neutral and accent-free. In dark style, near-white `{{text}}` with dark `{{light_text}}` text; in light style, `{{light_text}}` with white text. This is like libadwaita's selected toggles (my opinion). It passes for any accent or scheme, at about 15:1 by arithmetic, still to be measured.

- **Backed by:** newcomer (a labelled row of four), access (labels), owner (the footer was the owner seat's pick), design (its "Option C", ranked last).
- **Cost:**
  - Option B's clock-menu cost plus about 80 lines for the footer.
  - A second private field (`_system`), which is maintainer's red line. Choosing C is the nod it requires, and it needs its own fallback test.
  - The accent no longer colours lit tiles.
  - The highest GNOME 51 risk of the three.

## Questions for the owner

1. **Which option, A, B or C?** I recommend B.
2. **The orb's default.**
   - The code ships `now-playing-pill` on. DESIGN.md:57 and DECISIONS.md:145 say off until E1 passes.
   - Do you want it on, with DESIGN.md updated once X1 passes, or off by default?
3. **Critique 20261101-224331 ("two sets of circles")** was your monitor popup's power row, which you had removed on 2026-11-09.
   - Can it be closed as done?
   - Does quick settings' own round top row bother you at all? No note of yours says so.
4. **The decided "GNOME's Power Mode tile switches modes"** becomes "our row switches modes" on three-mode machines like your Dell. Is that what you want?
5. **"1 click from the top bar"** for power mode: the plan gives a corner push plus 1 click, or 2 clicks by mouse. Is that enough, or do you want a power-mode control in the top bar itself? That would be a new item for a later agenda.
6. **Hide GNOME's Bluetooth tile** once the device rows exist? The default is no: it stays as the full list and the way to pair.
7. **The "This computer" card:** keep it (the default) or drop it?

Not checked by the judge:
- GNOME 50's exact CSS class names for checked tiles, the system buttons and the media card.
- That `accentStrong` reaches shell stylesheets live.
- That `addExternalIndicator(…, 2)` gives a two-column row in GNOME 50.

Each is the first step of its build item, and a wrong one fails that item's own test rather than passing silently.

## The owner's choices (2026-11-10)

- **Layout:** Option B, with changes. Quick settings keeps the stock Ubuntu layout, with the battery level and every top-row button where they are (no restyle of the top row). The clock menu gets the Do Not Disturb and Focus switches, and their tiles stay.
- **Bluetooth recent devices:** in quick settings, as tiles below GNOME's Bluetooth tile, never in the clock menu (Should, after `mock-bluez.py`). GNOME's Bluetooth tile stays.
- **Media:** GNOME's card stays at the top of the shade and is made to look better (Must). If a restyle can't get there, it is redesigned as our own card (Should, owner's yes again).
- **The orb:** on by default. Its idle cost (E1) is measured in this build; the docs follow the result.
- **Power mode:** 1 click once quick settings is open is enough for now.
- **Note 20261101-224331 ("two sets of circles"):** closed. It was the monitor popup's power row, removed on 2026-11-09.
- **"This computer" card:** stays.

Debate files (not in the repo): `~/.local/share/ubuntu-ostrich/vm/council/2026-11-09-quick-settings-and-the-clock-menu/` (evidence pack built from try-me-0.2.0, rounds 0–3, facts, test plan, tests).
