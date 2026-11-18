# Verdict: the Ostrich look, on top of GNOME's design rules

## Summary
The council keeps the Ostrich look as it is: GNOME 50's tokens, the glass, one accent action per view, and amber as a fixed brand colour on the app icons. This round goes into fixing what the tests proved broken, not into a new style.

T2 found three contrast failures. Two are ours: the checked power segment at 4.36:1, and two light-style monitor values at 4.13:1 and 4.25:1. T4 found no focus ring on either power segment. T9 found no tooltips. T3 found the clock menu cut off at 200 % text. T1 showed the monitor still changes width as its content changes. T5 showed an open Processor section is about 500 px tall at only 4 cores.

The owner asked for a monitor resize option. The answer is one setting that controls how many rows an open section shows before it scrolls, offered in Settings as Compact or Tall. There is no drag handle, and the "Open System Monitor" window stays as the "more" view. The look rules get a lint that fails in CI, so the drift the tests found can't come back quietly.

Settings search, the sound page, tile subtitles and the monitor's default content go to Should. The glass edge and the "Power Saver" label are experiments. Icons are the owner's choice from three options, built as previews this round.

Nothing in this verdict changes DESIGN.md or CLAUDE.md.

## Rulings

1. **Resize the monitor menu: a drag handle, Compact/Comfortable/Tall, a row-cap key, or the window alone?**
   - The positions:
     - Owner: Compact plus Tall in Settings.
     - Design: Compact plus Comfortable, with a preview.
     - Maintainer: one row-cap key.
     - Simplicity: the window, plus at most one extra size.
     - Newcomer and access: no drag, and plain names.
   - **Ruling:** one gsettings key, `section-rows` (an integer, default 6). Ostrich Settings offers it as two named choices, **Compact (6 rows)** and **Tall (12 rows)**; Priya can set any number from dotfiles. There is no drag handle and no second layout.
   - **Why:** it is a real size choice, which the owner asked for (note 20261105-141902). It is still one layout and one test, which is the maintainer's limit. And it passes WCAG 2.5.7 and 2.1.1 (facts #11).
   - Design's "Comfortable" changes spacing, which makes a second layout to maintain, so it is out.

2. **A row cap with a scroll, or simplicity's "Cores" fold?**
   - **Ruling:** the cap. An open section shows at most `section-rows` rows in a scroll area with a fade at the edge. The height is in em, so it grows with text. The grey block behind open sections goes.
   - **Why:** T5 proved a limit is needed (about 500 px tall at 4 cores, against a 360 px budget). The fold puts a collapsible list inside a collapsible list, which the HIG rules out ("never nested"), and the owner asked for the cap.
   - The fold is the fallback only if build test B1 shows the scroll area can't keep the focused row in view from the keyboard.

3. **Monitor width: a minimum width, a fixed width, or "follows content"?**
   - **Ruling:** one fixed width in em, not a minimum. Long values are cut with "…" instead of widening the menu. The network reading gets a fixed-width slot (tabular figures and a short unit such as "985 K/s").
   - **Why:** T1 disproved "one width" today. Content still adds 32 px (network) and 55 px (Processor open), and the popup slides sideways, which is the owner's complaint (note 20261105-141833). A minimum width wouldn't stop that.
   - **Pass line:** Balanced, Saver, a busy network and Processor open are all within 4 px of each other with the same x position. At 2× text the menu grows and nothing is clipped. That is the owner's own test line.

4. **The power-mode row in the monitor: keep or drop?**
   - **Ruling:** keep it.
   - **Why:** the owner asked for all modes beside the readings (note 20261102-014411). 384fc74 already hides modes the machine lacks (facts #16). With the fixed width, saver no longer stretches anything (T1). Simplicity withdrew the drop to a question, and access and design accept the row once the segment is fixed.

5. **The "Paused" wording in saver.**
   - **Ruling:** keep the last values on show, and change the note to say they are a last reading, e.g. "Paused in power saver · last reading". The note already wraps (`line_wrap`), so the fixed width holds. Values are not dimmed (`stylesheet.css:2-3` records that dimmed text failed 4.5:1).
   - **Why:** T6 disproved "live numbers". The values are frozen, but frozen numbers next to the bar's dashes look live (newcomer, access, simplicity).

6. **Focus-ring style: 3 px AAA, or 2 px like the shell?**
   - **Ruling:** 2 px, inset, in the foreground colour, never the accent. Access conceded 3 px.
   - **Why:** T4 showed the accent-coloured ring on the segments is invisible. The footer buttons already show the shell's ring, so only the segments change.

7. **Text on the checked power segment.**
   - **Ruling:** it must reach 4.5:1 with GNOME's built-in accents, not only today's wallpaper accent. The builder takes the cheapest way that passes:
     - (a) a neutral raised fill for the active segment, the way libadwaita's toggle groups show it (my opinion, check against the libadwaita 1.9 docs before building); or
     - (b) the palette's `accentStrong`/`accentFg`, which `tools/palette` already writes to `palette.json` for the extensions (`tools/palette/src/output.rs:151-156`; no extension reads them yet).
   - **Why:** DESIGN.md already requires 4.5:1 for text on an accent fill ("accentStrong"). The segment broke that rule.

8. **The tooltip mechanism, and its clash with drawer hover.**
   - Facts #20 and T9: there is no tooltip anywhere in our code. The maintainer's claim that `tooltip_text` works in St is unverified *(opinion)*.
   - **Ruling:** one small shared label helper in `_lib`, shown on hover and on keyboard focus, built the way GNOME's dash labels its icons, with its text taken from the existing accessible name. It has two users (monitor and drawer), so `_lib` is the right home under `components.md:17-18`.
   - Drawer icons open their site on hover (a 500 ms rest), so a hover label would flicker into a panel. Drawer icons therefore show the label on keyboard focus always, and on hover only when hover-to-open is off. When hover-to-open is on, the opened drawer names the site.
   - The first build checks that the drawer's tab row shows the site's name. If it doesn't, the name goes in the drawer's tab row.

9. **Tile subtitles (design, newcomer, owner, access) against "don't add" (simplicity).**
   - **Ruling:** add them (Should). Focus gets "On"/"Off" and Workspaces gets "N open".
   - **Why:** T7 shows Workspaces never shows a checked state. Its state would otherwise depend on colour alone, and GNOME's own tiles carry subtitles (the Power Mode subtitle in T2). Simplicity's point that the fill is fine is right (T7), so no fill or class changes.

10. **The Workspaces tile.** It stays (owner note 20261102-014340). Whether it should light up while workspaces are in use goes to the owner (T7, B5).

11. **Settings search against merging pages.**
    - **Ruling:** search first, from an index generated from the page definitions, with a test that every page and row is in it (maintainer). Merging 13 pages into 8 is a question for the owner.
    - **Why:** T12 disproved the scrolling case for the merge, and the merge undoes the owner's "a page per part" (note 20261023-193217).

12. **The glass edge.**
    - **Ruling:** an experiment, not a default.
    - **The line:** the owner's 93 %, not design's 90 %, because the owner's red line names their own number (note 20261023-193727). The edge isn't counted as an accessibility border: high contrast already gets the shell's border (T2).
    - Whether it is the look Ostrich wants is taste, and the owner decides from the preview.

13. **Alert card colours.**
    - **Ruling:** the fixed dark card stays, as a documented exception next to the CSS.
    - **Why:** T2 measured every line at 4.90:1 or better. The theme-colour variant was never built, and the maintainer withdrew it. The cut-off confirm label is a separate bug (Must).

14. **Power saver and motion** (facts note 1, access).
    - Not reopened. DECISIONS.md (2026-11-01, 2026-11-02) records that power saver keeps animations and Spring. No module sets `enable-animations` (I grepped `modules/` and found none).
    - The header comment at `_lib/motion.js:3` ("power saver turns it off") is out of date and gets corrected.

15. **The clock menu at 200 % text against the owner's fixed size.**
    - **Ruling:** keep the owner's fixed shape, defined in em instead of px. At 1× it is the same size; at 2× it grows with the text and nothing is cut off.
    - **Why:** T3 proved "November …" and "Add World Clo…" are cut off.
    - **How:** the three widths in `tweaks/stylesheet.css:6-8` were set in px because GNOME's 29em list pushed the column out. Converting all three (menu, list, column) to em together keeps their proportions.

16. **Icons.** The owner chooses (agenda item 5); see Options.
    - Correction for every seat: the current glyphs already tell the apps apart by shape (bag, sliders, drawer, question mark, grid; `tools/icons/README.md`). "A distinct silhouette per app" doesn't separate option A from option C.
    - What does separate them is the light tint, and the app icon being the same drawing as its top-bar icon.

## Scorecard
Scores are 1–5. Weights: Reach ×3, Impact ×3, Cost ×2, Risk ×2, Effort ×1, Evidence ×2. The maximum is 65.

| Proposal | Seats | Reach | Impact | Cost | Risk | Effort | Evidence | Total |
|---|---|---|---|---|---|---|---|---|
| Monitor contrast and focus fixes (checked segment, light values, ring) | access, design, newcomer, owner, simplicity, maintainer | 5 | 4 | 5 | 5 | 5 | 5 | **62** |
| Names for icon-only controls (hover and focus labels, pin name fix) | newcomer, access, design, owner, simplicity, maintainer | 5 | 4 | 5 | 4 | 4 | 5 | **59** |
| Monitor fixed em width + "last reading" cue | owner, design, simplicity, newcomer, maintainer | 4 | 4 | 5 | 4 | 4 | 4 | **54** |
| Alert confirm label fits | newcomer, owner, design, simplicity, maintainer | 4 | 3 | 5 | 5 | 5 | 4 | **54** |
| Em sizing: clock menu, monitor icons and targets | access, maintainer, design, owner | 3 | 4 | 5 | 4 | 4 | 5 | **53** |
| Look rules fail in CI + `dim-label` → `dimmed` | maintainer, simplicity, design, access, newcomer, owner | 2 | 3 | 5 | 5 | 4 | 5 | **49** |
| Tour page 1 says where things are | newcomer | 2 | 4 | 5 | 4 | 3 | 4 | **47** |
| Row cap with scroll + one size key (Compact/Tall) | owner, maintainer, design, newcomer, access | 3 | 4 | 4 | 3 | 3 | 4 | **46** |
| Tile subtitles + Settings button opens the right page | owner, design, newcomer, access | 4 | 2 | 5 | 4 | 4 | 3 | **46** |
| Settings search (generated index) | all six | 4 | 3 | 5 | 3 | 2 | 3 | **45** |
| Sound page: one action per row | all six | 3 | 3 | 5 | 4 | 3 | 3 | **45** |
| Icon option previews (A/B/C) | design, owner, access, maintainer | 2 | 3 | 5 | 5 | 3 | 2 | **44** |
| Monitor default: four rows, pinned first, footer on the row grid, "Up 12 min" | design, owner, newcomer | 4 | 3 | 5 | 3 | 3 | 2 | **44** |
| "Cores" fold instead of a cap | simplicity | 3 | 3 | 5 | 3 | 4 | 2 | 42 (fallback only) |
| "Power Saver" as the segment label | newcomer | 2 | 2 | 5 | 5 | 5 | 2 | 41 (experiment) |
| Drop the monitor's power row | simplicity | 2 | 2 | 5 | 4 | 5 | 2 | 39 (rejected) |
| Glass edge token | design | 3 | 2 | 4 | 3 | 4 | 1 | 35 (experiment) |
| Compact/Comfortable as two layouts | design | 2 | 3 | 4 | 2 | 2 | 2 | 33 (rejected) |
| Merge Settings 13 → 8 pages | simplicity | 2 | 2 | 5 | 2 | 2 | 1 | 30 (owner question) |

The row cap scores below some Should items, but it is Must: T5 proved the open popup outgrows the screen, and it is the owner's direct request. Its risk score reflects only the untested keyboard scroll, which B1 settles.

## The plan

### Must (this round)

**1. Monitor: a readable active mode and a visible focus ring**
- **What:**
  - Fix the checked segment's text to 4.5:1 or better (ruling 7).
  - Draw the `:focus` ring as a 2 px inset ring in the foreground colour on every segment.
  - Make the light-style values 4.5:1 or better: set them in the full text colour (`light_text`) instead of whatever is dimming them today.
- **Where:** `modules/gnome/extensions/monitor/stylesheet.css:26-30`. Where the colour differs by style, use per-style rules (`stylesheet-light.css`/`-dark.css`, or a `.css.in` token).
- **Serves:** Daniel, Rosa, the owner. Nobody loses.
- **Verify:**
  - Rerun T2 (`tests/vm/contrast.sh`) in dark, light and high contrast with the default accent plus GNOME's yellow and teal accents. Every line must be at least 4.5:1.
  - Rerun T4 in dark and light. Every Tab stop must show a ring, sampled at 3:1 or more against its surround.

**2. Monitor: one width, and an honest pause**
- **What:**
  - Replace `.ost-vital-row { min-width: 260px }` with one fixed width in em, sized by the build to the widest normal content at 1× (about 17 em is the starting guess).
  - Cut long values with "…" instead of widening, and give the network reading a fixed-width slot.
  - Change the saver note to a "last reading" wording.
- **Where:** `monitor/stylesheet.css:14`; `monitor/extension.js:186-194` and the network formatter.
- **Serves:** the owner (note 141833), Tomás, Rosa.
- **Verify:** rerun T1 in Balanced, Saver, with a busy network and with Processor open. Pass if all are within 4 px and the x position doesn't change. At text scale 2.0 the menu grows and nothing is clipped.

**3. Monitor: capped open sections and one size setting**
- **What:**
  - An open section scrolls inside a `St.ScrollView` with `-st-vfade-offset`. Its height is `section-rows` × the row height, in em. No grey inner block.
  - New key `section-rows` (integer, default 6).
  - The Ostrich Settings Top bar page gets a "Monitor menu size" row: Compact (6) or Tall (12). The Settings app and the wizard share pages, so this also covers DESIGN principle 7.
  - The footer's middle button is named "Open System Monitor": that is the "more" view.
- **Where:** `monitor/extension.js`; `monitor/schemas/org.gnome.shell.extensions.ubuntu-ostrich.monitor.gschema.xml`; `tools/welcome/src/main.rs` (Top bar page); `tests/vm/dconf-test.sh` (the key survives dump, reset and load).
- **Serves:** the owner (note 141902), Priya (many threads, and the key fits her dotfiles), Tomás, Daniel.
- **Verify:** B1 at `VM_CPUS=16`, in both Compact and Tall:
  - Compact: the popup with Processor open is 360 px tall or less at 1×.
  - Tab and arrow keys reach every core row, and the focused row scrolls into view.
  - At 2× text nothing is clipped.
  - If the keyboard check fails, build simplicity's "Cores" fold instead.

**4. Every icon-only control has a name you can see**
- **What:**
  - Add a `_lib` label helper: hover and keyboard focus, with text from the existing accessible name.
  - Use it on the monitor's three footer buttons (Refresh's label: "Refresh: reads once while paused") and on the drawer's top-bar icons, following the hover rule in ruling 8.
  - Drop ", pinned" from the pin row's accessible name, because the CHECKED state already announces it (facts #21).
- **Where:** new `modules/gnome/extensions/_lib/label.js`; `monitor/extension.js:81-114,226,547`; `drawer/bar.js:111`.
- **Serves:** Rosa, Daniel, the owner, Priya.
- **Verify:**
  - Rerun T9: a label appears on hover over each footer button, and on Tab focus for the footer buttons and the drawer icons.
  - `tests/vm/ext-test.sh monitor drawer`: 20 enable/disable cycles, no journal errors and no leaked label actors.

**5. Sizes that scale with text**
- **What:**
  - Monitor icons, star and footer targets move to em tokens (`icon_s`, `target_comfort` in `tools/icons/tokens.toml`).
  - The clock menu's three px widths become em (ruling 15), the same size at 1×.
- **Where:** `monitor/stylesheet.css:6,12,16,19,20`; `tweaks/stylesheet.css:6-8`; `tools/icons/tokens.toml`.
- **Serves:** Daniel, Priya on 4K. At 1× nobody loses: the owner's fixed clock-menu size is unchanged.
- **Verify:** rerun T3 at 2.0. No "…" in the clock menu, and the monitor's icons visibly scale with the text. At 1.0, compare against today's shots: the clock menu should be within ±4 px of 680 × 460.

**6. The alert's confirm label fits**
- **What:** the confirm button says only "End NAME" or "Quit NAME". The warning ("Unsaved work is lost") moves into the card's body line, which wraps.
- **Where:** `monitor/extension.js:373,691`; `_lib/alert.js`.
- **Serves:** Rosa, the owner.
- **Verify:** `tests/vm/alert-test.sh` with a long app name. The confirm shot has no "…", and contrast stays at 4.5:1 or more.

**7. Look rules that fail in CI, then the sweep**
- **What:**
  - `token-lint.sh` fails on literal sizes and colours in plain `stylesheet.css` too, with written exceptions allowed (the alert card's colours, ruling 13).
  - Add a `dim-label` check over `*.rs` files.
  - Add a check that every button class has a `:focus` rule (access).
  - Run it in CI.
  - Add `tests/look-check.sh`, which chains token-lint, the journal gate and `contrast.sh`. It runs locally only, because runners have no VM.
  - Then fix what it finds:
    - the 10 `dim-label` uses → `dimmed` (facts #7);
    - the `dock`, `tiling` and `workspaces` lines from T10;
    - the stale `_lib/motion.js:3` comment.
- **Where:** `.claude/skills/ostrich-design/scripts/token-lint.sh`; `.github/workflows/ci.yml`; `tests/look-check.sh`; `tools/welcome/src/main.rs:214,1084,1101,1146,2380`; `tools/store-gtk/src/main.rs:409,461,512,909`; `tools/drawer-host/src/main.rs:429`; `dock`, `tiling` and `workspaces` `stylesheet.css.in`.
- **Serves:** every persona indirectly, Priya directly, and every future change.
- **Verify:**
  - The lint exits non-zero on today's tree and lists the T10 lines, the monitor's plain-CSS literals and the 10 `dim-label` uses. It exits 0 after the clean-up.
  - CI goes red on a planted `dim-label`.
  - `contrast.sh` measures the `dimmed` Settings text at 4.5:1 or more in dark and light.

**8. Icon option previews (build only; nothing ships until the owner picks)**
- **What:** export options A, B and C (below) into separate folders and screenshot each on the dock in light and dark.
- **Where:**
  - `tools/icons/template.svg`.
  - A new `tools/icons/template-flat.svg` (B).
  - A small change to `export.sh`: allow a `TEMPLATE=` variable and an `@NAME@` placeholder for per-app palette keys.
  - `ICONS_OUT=$XDG_CACHE_HOME/ubuntu-ostrich/icon-options/{a,b,c} tools/icons/export.sh --preview …`.
- **Serves:** the owner's choice (agenda item 5).
- **Verify:**
  - B4: each option's edge or body measures 3:1 or more against a light and a dark dock.
  - The five apps are told apart at 16 px.
  - `export.sh --check` still passes on the committed (unchanged) icons.

### Should (next)
- **Quick-settings tiles:**
  - Focus subtitle "On"/"Off"; Workspaces subtitle "N open". No new classes or fills.
  - The Ostrich Settings button focuses the right page of an already-open window (note 20261101-225220).
  - Where: `focus/extension.js:65-91`, the `workspaces` extension, `tools/welcome` (`--step`).
  - Serves: Rosa, Daniel, the owner.
  - Verify with B3: tile heights match GNOME's, and labels are at 4.5:1 or more in light, dark and saver.
- **Monitor default content:**
  - Pinned values first.
  - Four sections open by default (Processor, Memory, Network, Battery or Storage); everything else stays folded, never deleted (`docs/PARITY.md:86-90`).
  - Footer on the row grid.
  - The collapsed System header reads "Up 12 min" (newcomer, opinion).
  - Where: `monitor/extension.js`, `monitor/vitals.js:129`, `stylesheet.css`.
  - Verify: T1 widths still hold, and every PARITY row is still reachable.
- **Settings search:**
  - A `GtkSearchEntry` in the sidebar, opened with Ctrl+F, over an index generated from the page definitions, with `AdwStatusPage` for no results.
  - Where: `tools/welcome/src/main.rs`.
  - Verify: a `cargo test` that every page and row title is in the index; a VM shot of a search finding "speaker".
- **Sound page, one action per row:**
  - A play button as the row's prefix, a check on the active row, "Off" as an ordinary row, a one-line intro without "PipeWire", and room for "Solo piano: Bach: Gol…".
  - Every play button is named with its preset.
  - Where: `tools/welcome/src/main.rs`.
  - Verify: a `settings/speakers.png` retake; `a11y-test.sh` for the names.
- **Tour page 1, "where things are":**
  - Names the dock's bottom edge, the app grid, the clock and the quick-settings corner (T8).
  - Where: `tools/welcome/src/main.rs`.
  - Verify: a tour screenshot; newcomer walk-through.
- **Settings page scrolling:** the page scrolls and the sidebar keeps the selected row in view (note 20261101-225328).
  - Where: `tools/welcome/src/main.rs`.
  - Verify: T12 at 2.0 with a short window (800 px tall).

### Experiments
- **Glass edge** (design):
  - What: one `glass_edge` token, a thin, shadowless inner edge on every glass surface.
  - Measurement: B2, the compare-glass method over the same photo and in the same style, with and without the edge.
  - Keep it if kept brightness is at least 93 % and the owner likes it in the preview. Revert if it is below 93 %, or if the owner says no (taste decides here, and that is the owner's).
- **"Power Saver" as the segment label** (newcomer):
  - What: set the visible label to match the accessible name.
  - Measurement: T1's width test inside the new fixed width.
  - Keep it if the label fits without "…" at 1×. Otherwise revert to "Saver", which already gets a label from Must 4.
- **Workspaces lit while in use** (B5), only if the owner says yes to the question below. Measure with T7 shots in light, dark and saver, and keep it only if the label stays at 4.5:1 or more on the accent fill.

### Not now
- **Drop the monitor's power row.**
  - Where: `monitor/extension.js:43-47,872-886`. Serves: Rosa, Tomás.
  - Verify if ever done: T1 widths, and the mode is still reachable from GNOME's tile.
  - Only on the owner's word.
- **Merge Settings 13 → 8 pages.**
  - Where: `tools/welcome/src/main.rs`. Serves: Rosa.
  - Verify: every dconf key still has a row (dconf-test).
  - Only on the owner's word, after search exists.
- **Opaque glass in high contrast / reduced transparency** (access withdrew it).
  - Where: `blur/extension.js`, the stylesheets. Serves: Daniel.
  - Verify: an edge contrast measurement first. Revisit only if a 3:1 edge measurement fails.
- **Alert card on theme colours (B6).**
  - Where: `monitor/stylesheet.css:35-61`. Serves: the owner, for consistency.
  - Verify: `alert-test.sh` over the busy photo, every line at 4.5:1 or more.
  - The fixed card already passes.
- **A star on section headers to show pins.**
  - Where: `monitor/extension.js`. Serves: Daniel, the owner.
  - Verify: within the fixed width (T1).
  - Waits for the Should default-content pass.
- **GNOME's Power Mode subtitle at 3.36:1 in saver.**
  - What: an upstream report to gnome-shell with `evidence/tests/T2-saver-quick.png`. Not ours to patch. Serves: Daniel.
  - Verify: a link to the upstream issue.
- **The missing Night Light tile** (simplicity, not checked).
  - Where: `compare-dark/side-3-menu.png` against a stock VM. Serves: everyone.
  - Verify: check whether it is a VM artefact before doing anything.

## Rejected
- **Drag-to-resize handle on the monitor menu.** All six seats were against it. GNOME's popup has no resize (facts #10), and pointer-only dragging needs an alternative (WCAG 2.5.7). The size setting answers the owner's request.
- **Compact / Comfortable / Tall as separate layouts.** Each layout is another set of upkeep and another test. One row-count key gives the owner a real size with one layout.
- **The "Cores" fold as the first choice.** It is a nested expander, which the HIG rules out. It is kept only as the fallback if B1 fails.
- **"Tiles become real QuickToggle / QuickMenuToggle."** The premise was wrong: they already are (facts #22), and T7 shows the fill already matches.
- **Icon accent following the wallpaper accent.** App icons are exported files and can't follow an accent that is re-picked from each wallpaper (design withdrew it, `docs/DEFAULTS.md:35`).
- **Fold or drop the Workspaces tile.** The owner asked for it (note 20261102-014340).
- **Hide the critique extension in releases.** It is moot: T11 showed the installer never ships it.
- **Cutting Vitals features (star pin, voltage, fans).** The maintainer withdrew it, and `docs/PARITY.md:86-90` keeps them.
- **Claims the tests disproved, which carry no weight:**
  - one width today (T1);
  - live numbers in saver (T6);
  - footer buttons without a ring (T4);
  - targets under 24 px at 2× (T3);
  - a visible launcher on the first screen (T8);
  - sidebar overflow at 200 % (T12);
  - the token-lint line list (T10);
  - text over glass at 4.5:1 everywhere (T2).

## Owner vs most people
- **Resize.** The owner wants a resize option; GNOME menus and most people expect a fixed menu. Default: Compact (6 rows) for everyone. Setting: Tall (12) in Settings, or any number through the key. Both win, and nobody gets a drag handle.
- **The clock menu's fixed size against large text.** The owner wanted it never smaller or bigger (note 20261024-194146). Daniel needs it to grow (T3). Default: the owner's size at 1×. Because it is set in em, it grows only when the user enlarges text.
- **Power modes in two places.** Kept for the owner. Most people use GNOME's tile and lose nothing, because the monitor row now hides absent modes and gets readable text and a ring.
- **A hidden dock against a visible launcher for Rosa (T8).** The hidden dock stays as the owner's default. The tour names the bottom edge (Should). A permanent launcher is a question, not a ruling.
- **Glass against legibility.** All the contrast fixes change text colours, never the glass tint, so the owner's 93 % brightness is untouched.
- **Icons.** The owner chose the glass square (note 20261024-032921). The HIG template is what most GNOME users see. Hence three options, with the owner's earlier choice listed first.

## Options for the owner
**Icons (agenda item 5).**

All three are built from `tools/icons/` data with `export.sh`, with no hand art per icon. The five apps are Store, Settings, Drawer, Help and the Show Apps grid.

The 16 px `-symbolic` icons in `tools/icons/symbolic/` stay as they are in every option. The top bar, menus and status pages use them, and GNOME recolours them. The dock shows the app icon.

Schemes recolour any option through `PALETTE=schemes/NAME.toml`. Contrast figures marked "estimate" are my arithmetic, not measurements; B4 measures them.

### A. Glass Square, tuned (today's identity)
- **Template:** `template.svg` unchanged except the rim's `stroke-opacity`, which goes from 0.2 to 0.3 (`template.svg:17`):
  - 128 grid, 8 px margin, rx 28;
  - gradient from `shell_top #4a5468` to `shell_bottom #1f2430`;
  - shine at 0.22 fading to 0;
  - top highlight `#ffffff` at 0.45.
- **Colours:** glyph `#f4f6fa`; accent `#f2a541` (amber) on one part of each glyph; edge and highlight `#ffffff`.
- **One icon for both styles:**
  - On a white dock the dark body carries the edge (estimate well above 3:1).
  - On a black dock the rim carries it: 0.3 gives about 3.9:1, while today's 0.2 gives about 2.8:1, which fails (estimate).
- **Glyphs:** today's `glyphs/*.svg`. They already differ in shape.
- **Backed by:** owner (earlier choice), maintainer (a data change only).
- **Cost:** one number. It is the furthest of the three from GNOME's app-icon template.

### B. GNOME template, flat with a front edge
- **New `template-flat.svg`:**
  - A body `rect x=8 y=8 w=112 h=104 rx=22` filled `{{body_@NAME@}}`.
  - Under it, the same rect offset down 8 px, filled `{{front_@NAME@}}`, so a darker edge shows along the bottom.
  - No shine, rim or highlight.
- **Per-app hues** (new keys in `palette.toml`; the front edge is 20 % darker):

  | App | Body | Front |
  |---|---|---|
  | Store | sage `#5e7d59` | `#4b6447` |
  | Settings | slate `#4f6079` | `#3f4d61` |
  | Drawer | blue `#3a6fb0` | `#2e598d` |
  | Show Apps | teal `#2e7d76` | `#25645e` |
  | Help | sand `#9a7536` | `#7b5e2b` |

- **Glyphs:** today's glyph shapes, with every `{{glyph}}` and `{{accent}}` part drawn `#ffffff`. There is no amber; the hue is the identity. A white glyph on each body is estimated at 4.2–6.4:1.
- **On both docks:** each body is estimated at about 4:1 or better against black and about 5:1 or better against white.
- **Backed by:** the HIG template. Access backed it only as far as its 3:1 and silhouette criteria go, and preferred C in its closing.
- **Cost:**
  - It gives up the glass look the owner chose.
  - It needs a new template and five hue pairs.
  - It needs a ~10-line change to `export.sh` so one template can use a different colour per app.

### C. Glass family, one drawing per app, light and dark tints
- **Template:** A's (rim at 0.3), with the top highlight line (`template.svg:18`) drawn in amber `#f2a541` instead of white. That thin amber line is the brand mark.
- **Glyphs:** the 16 px symbolic path scaled into the glyph box (`<g transform="translate(32 32) scale(4)">`) and filled `{{glyph}}`. The app icon and its top-bar icon become one drawing. The glyph is one colour; amber appears only on the highlight line.
- **Two tints:**
  - Dark tint (dark style): A's colours.
  - Light tint (light style): `shell_top #e8ecf3`, `shell_bottom #bcc6d6`, glyph `#1f2430`, edge `#1f2430` at 0.3.
  - Swapping by style reuses the way the tweaks extension already switches Yaru's folder icons between light and dark.
- **Backed by:** design (first pick), access.
- **Cost:**
  - Two templates' worth of colours to keep in step.
  - An icon swap whenever the style changes.
  - Each symbolic glyph must be checked at 128 px, since some were drawn for 16 px.

**Preview for all three:** Must 8 exports each to `icon-options/{a,b,c}` and screenshots the dock in light and dark style at 16, 48 and 128 px. The owner chooses from the images.

## Questions for the owner
1. **Icons:** A, B or C, after the previews (Must 8)?
2. **The Workspaces tile:** should it light up with the accent while workspaces are in use, or stay a menu tile that says "N open"?
3. **"Redesign this" (note 20261105-142055):** beyond subtitles, the Settings link and keeping GNOME's tiles first, did you mean something specific: order, a tile to remove, the top row of round buttons (note 20261101-224331)?
4. **The monitor's power row:** the verdict keeps it. Do you want it kept, or would GNOME's Power Mode tile be enough?
5. **Settings pages:** after search ships, do you want 13 pages merged into about 8? That would undo your "a page per part".
6. **First screen:** do you want a small visible launcher for newcomers (T8), or does the hidden dock plus a tour page do?
7. **Outside this agenda:** the evidence pack shows boot time +151 % (7.2 s → 18.0 s) and used memory +24 % against your original setup, and no seat addressed it. DESIGN principle 4 says a component over its budget isn't done. Should this be a separate task (profile the boot in the VM and find what adds the memory) before the next release?

---

Files I checked myself beyond the debate:
- The palette writes `accentStrong`/`accentFg` to `palette.json`, but no extension reads them (`tools/palette/src/output.rs:151-156`).
- DECISIONS.md settles power saver and Spring (`docs/DECISIONS.md:211-229`); `_lib/motion.js:3` is a stale comment.
- The clock menu's px sizes are deliberate (`modules/gnome/extensions/tweaks/stylesheet.css:2-8`).
- The confirm strings (`modules/gnome/extensions/monitor/extension.js:373,691`).
- `tools/icons/{template.svg,palette.toml,export.sh,README.md}`.

Not checked:
- Whether St offers a tooltip property (ruling 8 says to build a label helper).
- Whether the drawer's tab row shows site names.
- libadwaita's toggle-group styling (ruling 7a).
- The round 1 openings from newcomer, access, simplicity and maintainer, and every exploration file: I relied on their rounds 2 and 3, which restate them.
- Every icon contrast figure is my arithmetic, not a measurement; B4 measures them.

## Correction (2026-11-05, while building M1)
T2 reported two light-style monitor values at 4.13:1 and 4.25:1. That was `contrast.sh` underestimating short strings ("7%" has too few ink pixels for its percentile method; the same row moved from 4.13 to 3.53 when the text was made darker). Measured by the darkest ink against the glass, every light-style value reads 6.1 to 6.7:1 (the original T2 shot too: 6.3 to 6.6:1), the same as the labels. There is no light-value failure and no change was made for it. The checked-segment (4.36:1) and the missing focus ring are unaffected; the shell's own ring also measured 2.84:1 in light and 3.18:1 in dark, which is why M1 draws its own.
