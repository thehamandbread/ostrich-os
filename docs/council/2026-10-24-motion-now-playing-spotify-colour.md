# Verdict: motion, now playing, Spotify in the drawer, and an Ubuntu Ostrich colour scheme

## Summary

The tests changed this debate more than the arguments did. T3 found that the drawer already registers empty "Stopped" media players at login. GNOME's clock menu shows each one as an "ostrich-drawer / Google Messages for web" card with a play button that does nothing. Every seat now agrees this is the first thing to fix. T5 showed that the clock menu's right column spills out of its fixed 688 × 468 panel, at normal text size and at 200 %. T6 found two lines of text below the 4.5:1 contrast floor. The tests also turned up an `xdg-desktop-portal` crash dialog that appears at every try-me login.

These go first, because they are defects people see today. Next come the owner's three asks, each with a guard:
- **Motion:** one shared helper. It follows `enable-animations`, power saver and reduced motion. T1 proved that the off path ends in the right state.
- **Now playing:** the pill, built this round. It is hidden when nothing plays. It turns on by default only if it passes an idle-cost measurement.
- **Spotify:** the honest "open the app / open in browser" route an earlier council promised and nobody built. Widevine runs only as an experiment, and only if you say yes.

The drawer also gets a navigation policy and a narrower notification grant, because T13 and T14 proved those holes. The colour scheme is your choice. Three complete options are below, all built on one token file. Each option fixes the two T6 failures and keeps the glass brightness fix.

## Rulings

1. **Pill next to the clock, or GNOME's card?** The owner wants the pill built now (note 194002). Maintainer, design, everyday, mobile, lowend and newcomer want GNOME's card first and the pill only after measurement.
   **Ruling: both, this round, in that order.** GNOME's card already exists and costs nothing (T4: shell CPU 0.117–0.158 % and 2.4–4.4 wakeups/s with or without a player). The pill gets built after the phantom-player fix (M1). It turns on by default only when it passes the measurement line in E1.
   *Why:* the owner's request is explicit and the goal says we don't lose it. "Unmeasured" becomes a dated test, not a standing veto.

2. **Where does the pill expand?** The owner said "inside the clock menu". Design, access and simplicity say nothing more goes into the clock menu until it contains its children.
   **Ruling: the pill opens its own small glass drop-down under itself.** It does not open inside the clock menu.
   *Why:* T5 shows the clock menu already overflows. A separate drop-down still "sits next to the time and expands when opened" (note 194002), and it can't make the overflow worse.

3. **Three-way switch (pill / card / off) or one boolean?** Owner, mobile, access, lowend, newcomer and everyday want three ways. Maintainer and simplicity want one boolean.
   **Ruling: one boolean, "Show now playing next to the clock".** Off leaves GNOME's card, so you still get "pill or card".
   *Why:* nobody brought evidence that anyone needs GNOME's own card hidden, and every code path needs its own tests (quality).

4. **Motion scope and durations.**
   - Positions: the owner wanted 120/170/240 on every surface. Simplicity wanted the drawer only. Lowend and design wanted a 200 ms cap. Power wanted 120/170/250 with a key per tier.
   - **Ruling, durations:** one helper with 120 / 170 / 200 ms (quick / standard / slow). Only position and opacity animate. The existing `animation-speed` scales everything, so the owner's 1.2 gives the 240 ms he asked for.
   - **Ruling, scope:** our own surfaces this round (drawer, dock, dock previews, tiling preview). Menus and workspace switching already animate in GNOME and already follow `animation-speed`, so they need no new code.
   - *Why:* nobody measured anything above 200 ms on a weak CPU. The owner's speed control lets him have more without forcing it on Tomás.
   - No per-tier keys, because quality and maintainer want one setting with one test surface.

5. **The interrupted-slide race.** T2 disproved it on the keyboard path (0 of 40 runs). Facts row 3 confirms it from source.
   **Ruling:** the helper carries the cheap `isFinished` / stale-slide guard, and `motion-test.sh` covers the click and outside-click paths. We don't call it a fix for a visible bug.

6. **Fixed clock menu (note 194146), or let it grow with large text (access)?**
   **Ruling: it stays 688 × 468.** When the text scale is above 1.25, or the content doesn't fit, the right column scrolls inside the box.
   *Why:* T5 shows the right column fully off the panel at scale 2, which Daniel can't use. Scrolling keeps your shape and makes everything reachable.

7. **Spotify in the drawer.**
   **Ruling:** DRM sites get a plain message with "Get the Spotify app" and "Open in browser" this round. Widevine is an experiment, only with your yes.
   *Why:* facts row 10 found no 2025–26 evidence that WebKitGTK can load Widevine, and row 11 found no CDM on 26.04. The promised button was never built (facts row 16).

8. **Notification permission for drawer sites.** DESIGN.md:110 grants it up front for each service's site. T14 shows that `req.allow()` answers any page in a drawer view.
   **Ruling:** restrict the grant to the service's own site now. That's what DESIGN.md already says, so it's a bug fix. Security's ask to default "+" sites to off would change DESIGN.md, so it's question 3 below.

9. **Glass tint: none (owner's wariness) or a palette tint (design)?**
   **Ruling:** a hue-shifted tint is allowed only as a colour fill, never as extra blur. Each surface's tint opacity may rise by at most 0.02 over today's values, and a brightness test decides (E3).
   *Why:* the 93 % brightness fix (note 193727) is your benchmark. A fill adds no GPU passes (lowend).

10. **Calendar grid back by default (newcomer)?**
    **Ruling: no.** Notes 193812 and 032844 removed it, and it's one switch away. Newcomer's Mei and Hana aren't listed personas (facts notes), so they don't count toward reach.

11. **Boot time.** T17 disproved "the +99 % is ours". The extra time is in `snapd.seeded.service`, +4.8 s over pre. It is no longer an argument against any feature here. Why seeding is slower is experiment E6.

## Scorecard

Rubric weights from PROTOCOL.md: Reach ×3, Impact ×3, Cost ×2, Risk/upkeep ×2, Effort ×1, Evidence ×2. Each score is 1–5, and higher is better (cheaper, safer, less effort). The maximum total is 65.

| Proposal | Seats (merged) | Reach | Impact | Cost | Risk | Effort | Evidence | Total |
|---|---|---|---|---|---|---|---|---|
| Clock menu contains its children (scroll above 1.25, guard helper, plain labels, ui-test at scale 1 and 2) | access, maintainer, simplicity, quality, owner, design, newcomer | 5 | 4 | 5 | 4 | 3 | 5 | **58** |
| Stop the phantom MPRIS players | newcomer, everyday, access, design, security, quality, maintainer, mobile, lowend, power, simplicity, owner | 5 | 3 | 5 | 4 | 4 | 5 | **56** |
| Contrast fixes from T6 (numerals 3.73, "No Notifications" 4.47) | access, design, security, everyone | 5 | 2 | 5 | 5 | 5 | 5 | **56** (folded into M6) |
| First login clean (portal crash, dev extension off) | newcomer, everyday, quality, access, design, power, lowend, mobile, security, maintainer, simplicity | 5 | 4 | 5 | 3 | 2 | 5 | **55** |
| One token set and the owner's chosen scheme | design, owner, power, simplicity, maintainer, lowend, access | 5 | 3 | 5 | 3 | 2 | 4 | **50** |
| Drawer navigation policy, scoped notifications, `chmod 700` | security, power, quality, newcomer, mobile | 4 | 3 | 5 | 3 | 3 | 5 | **50** |
| Accessible names, drawer-icon tooltips, `a11y-test.sh` | access, newcomer | 3 | 3 | 5 | 5 | 3 | 4 | 49 |
| Drawer honest states (DRM buttons, failed-load) | newcomer, everyday, owner, quality, security, simplicity, lowend | 4 | 3 | 5 | 4 | 4 | 3 | 49 (merged with the line above into M5: 48) |
| Drawer memory: placeholder-first start, MB per keep-alive site | lowend, mobile, power, quality, owner | 3 | 3 | 5 | 4 | 3 | 4 | 47 |
| Default video and music player plus handlers | everyday, newcomer, owner | 4 | 3 | 3 | 4 | 4 | 3 | 45 |
| Ship `critique@` off in user builds | simplicity, maintainer, quality | 3 | 1 | 5 | 5 | 5 | 4 | 45 (folded into M4) |
| Motion helper plus `motion-test.sh` | owner, design, access, lowend, mobile, power, quality, maintainer, simplicity | 4 | 3 | 4 | 3 | 3 | 3 | **44** |
| GNOME card restyle (CSS only) | maintainer, design, power, simplicity | 3 | 2 | 5 | 3 | 4 | 4 | 43 |
| Spotify (verified snap) and a music app in the Store's Media group | everyday, owner, security | 3 | 2 | 4 | 4 | 5 | 3 | 42 |
| Calendar grid back by default | newcomer | 2 | 2 | 5 | 5 | 5 | 2 | 41 (rejected: owner notes) |
| First-party icon family (Files, Help, app grid) | design, everyday | 3 | 2 | 5 | 3 | 3 | 3 | 40 |
| 24 px minimum targets on the monitor popup | access | 2 | 2 | 5 | 4 | 4 | 3 | 40 |
| CI job against a real GNOME Shell | maintainer | 3 | 2 | 5 | 4 | 1 | 3 | 40 |
| Settings and Store page cross-fade (GTK) | design, owner | 3 | 1 | 4 | 4 | 4 | 3 | 38 |
| Icons follow a user's accent change | design, owner | 2 | 2 | 5 | 3 | 3 | 3 | 37 |
| Hover/tiling poll step-down on battery | mobile, power, lowend | 2 | 2 | 4 | 4 | 4 | 2 | 36 |
| **Now-playing pill** | owner, power, access (with conditions), security (with conditions) | 2 | 3 | 4 | 2 | 2 | 2 | **33** |
| Vendor or depend on extension 10373 | (reference only) | 2 | 3 | 4 | 1 | 4 | 1 | 31 |
| Per-tier duration keys | power | 1 | 1 | 5 | 3 | 4 | 2 | 30 |
| Retire App Center from the app grid | simplicity | 2 | 1 | 5 | 2 | 3 | 2 | 30 |
| Merge Settings pages (Blur into Theme, Windows into Tiling) | simplicity | 2 | 1 | 5 | 3 | 2 | 1 | 29 |
| `scheme = plain` / "no tint" switch | power, design | 1 | 1 | 5 | 3 | 3 | 1 | 27 |
| Widevine CDM in the drawer | owner, security, power (opt-in) | 1 | 4 | 2 | 1 | 1 | 1 | 24 |
| Chromium/Electron view for DRM sites | owner, lowend (raised) | 1 | 3 | 1 | 1 | 1 | 1 | 19 |

The pill and the motion helper score below some Should items. They are in Must anyway because the owner asked for them by name (notes 194002, 193919, 194127, 194246), and the goal is "without losing what its owner asked for". I'm saying that plainly: the score didn't put them there.

## The plan

### Must (this round)

Build in this order. M1 and M2 come before M7.

**M1. Stop the phantom media players.**
- **What:**
  - Drawer views of sites that don't play media (messaging, AI, mail) get WebKit's MediaSession/MPRIS turned off in their own per-view `WebKitSettings`.
  - Media sites (YouTube, YouTube Music) keep it, marked with a `media = true` flag in the catalogue.
  - If Ubuntu's WebKitGTK 2.52.6 has no per-view switch, the pill (M7) and a CSS/patch on GNOME's card filter out any player whose `Identity` is `ostrich-drawer` and which is `Stopped` with empty metadata.
  - Move the mock player from the debate folder into `tests/vm/mock-mpris.py`.
- **Where:** `tools/drawer-host/src/main.rs` (view creation, around 328–345), `tools/drawer-host/data/recommended.toml`, `tests/vm/drawer-test.sh`, `tests/vm/mock-mpris.py`.
- **Serves:** Rosa (no player she never started), Daniel (no unexplained players for Orca), everyone. Kai loses nothing: T3(b) showed the drawer names never reflected real playback anyway.
- **Verified by:**
  - A new `drawer-test.sh` case: after login with the default config, `busctl --user list | grep mpris` shows no `ubuntu-ostrich.drawer` name.
  - A clock-menu screenshot shows no "ostrich-drawer" card.
  - Informational, since the VM has network: with YouTube playing in the drawer, record whether a name with a real title appears.

**M2. The clock menu contains its children.**
- **What:**
  - The right column becomes a scroll view whenever its content doesn't fit, which is always the case above text scale 1.25. The panel stays 688 × 468.
  - One `_lib/patches.js` helper returns null and logs once for `_calendar`, `_eventsItem`, `_leftBox/_centerBox/_rightBox` and `_bannerBin`.
  - Plain labels: "Open the monitor" becomes "System monitor", and "On for 1 min" becomes "Running for 1 minute".
- **Where:** `modules/gnome/extensions/tweaks/today.js` (104–190), `tweaks/stylesheet.css`, `_lib/patches.js`, `focus/extension.js:200`, `tweaks/extension.js:104`, `blur/extension.js:301`, `tests/vm/ui-test.sh`.
- **Serves:** Daniel (T5: the right column fully off-panel at scale 2), Rosa (plain words), the owner (the fixed shape is kept, note 194146), the maintainer (GNOME 51 breakage degrades instead of crashing).
- **Verified by:**
  - A `ui-test.sh` scene at text scale 1.0 and 2.0 with the mock player running. It checks that no pixel of the menu's content lies outside the panel border. Use the T5 pixel method until B3's allocation hook exists.
  - The menu measures 688 × 468.
  - `ext-test.sh tweaks`: 20 enable/disable cycles, no JS errors.

**M3. One motion helper, with its test as the gate.**
- **What:**
  - `_lib/motion.js` with three durations: quick 120, standard 170, slow 200 ms. Everything eases out and animates only translation and opacity, never blur radius or layout.
  - Everything goes through the shell's `ease()`, so `enable-animations`, power saver (`monitor/battery.js:34-37`) and `animation-speed` apply. Facts rows 1–2 and T1 confirm this works.
  - It reads `org.gnome.desktop.a11y.interface reduced-motion` itself (facts row 7). Under `reduce`, slides become quick opacity fades. Remove this at the Shell 51 port, when `St` gains reduced-motion support.
  - It guards each callback with `isFinished` and a stale-slide token.
  - The drawer gets a slide plus fade: open at standard, close at quick. The dock shows at standard and hides at slow, so the 220 ms hide drops to 200. Dock previews and the tiling preview use quick.
  - Permission and security prompts never animate.
- **Where:** new `modules/gnome/extensions/_lib/motion.js`; `drawer/extension.js:37-41,486-551`, `dock/extension.js:32-33,395,413`, `dock/previews.js:70`, `tiling/extension.js:28,340,348`; new `tests/vm/motion-test.sh`.
- **Serves:** the owner (notes 193919, 194127, 194246), Daniel (off means off, reduce means fade), Tomás (zero in power saver), the maintainer (one file in place of scattered constants).
- **Loses:** Tomás, if the cost on a weak GPU turns out real. E2 decides that.
- **Verified by:**
  - `motion-test.sh`, using T1's recipe, under three conditions: animations off, on, and `reduced-motion=reduce`. Each runs 20 keyboard cycles plus click and outside-click open-close-open sequences, and reads `shown` and `win.minimized`. It passes with all end states correct and 0 JS errors before and after.
  - `ext-test.sh` for drawer, dock and tiling.

**M4. A clean first login.**
- **What:**
  - (a) Find what makes the drawer trigger the `xdg-desktop-portal` 1.21.1 crash on WebKit's realtime-thread request (index note 20261024-193511; tests.md: in every try-me boot, and it steals focus and folds the drawer). Stop the drawer making that request if WebKitGTK allows it without weakening the web-process sandbox. Check Launchpad for a fixed portal version, and file a report with the crash file if there isn't one.
  - (b) Ship `critique@ubuntu-ostrich-dev` disabled in user builds, enabled only in dev or VM runs.
- **Where:** `tools/drawer-host/src/main.rs` (web context setup), `modules/gnome/install.sh` (the enabled-extensions list), `docs/DECISIONS.md` (record the outcome).
- **Serves:** Rosa (an "internal error" dialog at login reads as a broken OS), Daniel (Orca announces it), every drawer test (it spoiled T8).
- **Verified by:**
  - Three boots of a fresh try-me with drawer use: no `/var/crash/_usr_libexec_xdg-desktop-portal*` file and no apport dialog.
  - `gnome-extensions list --enabled` has no `critique@`.
- **Keep-or-escalate line:** if the only workaround is to disable the WebKit sandbox or suppress apport system-wide, do neither. It becomes a known issue and question 8.

**M5. The drawer is honest and safe.**
- **What:**
  - (a) DRM entries (Spotify, Netflix, Disney+, Prime Video) show a plain message instead of only "not yet supported". Spotify gets "Spotify can't play in this panel. [Get the Spotify app] [Open in browser]".
    - "Get the app" launches Spotify if it is installed. Otherwise it opens `snap://spotify`, the verified snap, in App Center. The unofficial Flathub `com.spotify.Client` is offered second and labelled unofficial.
    - The other three DRM sites get "Open in browser".
  - (b) A failed-load state for any site: "This page didn't load. [Try again] [Open in browser]". The text is real, so a screen reader announces it.
  - (c) A `decide_policy` handler: a top-level navigation away from the service's site and its known sign-in hosts opens in the default browser and leaves the drawer where it was. Sign-in pop-ups keep working as now (`main.rs:469-504`).
  - (d) `req.allow()` answers only the service's own origin. DESIGN.md:110 is unchanged.
  - (e) The drawer's data directory is `chmod 700`.
  - (f) Each top-bar drawer icon gets a tooltip and accessible name: "Chat (opens in a panel)".
- **Where:** `tools/drawer-host/src/main.rs:328-345,395-399,469-504,813-826`, `tools/drawer-host/src/config.rs:126-155,196-202`, `tools/drawer-host/data/recommended.toml:149-175`, `tools/welcome/src/main.rs:994,1070-1071`, `modules/gnome/extensions/drawer/bar.js`.
- **Serves:** Rosa (no dead ends), the owner (note 194359 gets a real answer, not a quiet close), Kai (Spotify one click away), Daniel (announced states), everyone (T13 and T14 closed).
- **Loses:** a little OAuth risk if the allow-list is too tight, so each curated site is tested.
- **Verified by:** new `drawer-test.sh` cases:
  - T13's page now opens example.org in the browser, and the drawer stays on `localhost:8099`.
  - A foreign-origin frame's `Notification.permission` is `denied`.
  - The network is cut from the host with the QEMU monitor's `set_link` on the guest NIC, which settles T11. Within 30 s the failed-load text and both buttons show.
  - `drawer-test.sh --sites` still signs into Messages, Chat and Claude.
  - `stat` shows the data directory at 700.

**M6. One token set, your chosen scheme, and the two T6 fixes.**
- **What:**
  - `tools/icons/palette.toml` becomes the single source, with sections `[icon]`, `[accent]`, `[dark]`, `[light]` and `[wallpaper]` (token list under "Options for the owner").
  - `modules/gnome/extensions/build.sh` fills `stylesheet.css.in` templates and writes `_lib/tokens.js`. This replaces the hand-written colours in the stylesheets, `blur/extension.js:43,332` (the bar's tint and the solid fallback) and `dock/extension.js:195-206`; nothing is kept beside them.
  - The palette tool's `accent_fg` uses a 4.5:1 threshold (`tools/palette/src/output.rs:41-57`, now 3.0) and writes `accentStrong` to `palette.json`.
  - Solid (no-blur) surfaces use each scheme's neutral `solid` token, not the accent.
  - The installer sets `accent-color`, `icon-theme` and the wallpaper on a fresh install. The wizard's Theme step offers the scheme with a preview (principle 7).
  - `accent-follows-wallpaper` stays as it is. It only takes over when the accent came from a wallpaper, so the scheme's accent holds until the user changes things.
  - Both T6 fixes are part of the scheme and are specified per option below.
- **Where:** the files above, plus `workspaces/stylesheet.css:14-18`, `blur/stylesheet.css`, `tweaks/stylesheet.css`, `tools/icons/export.sh`, `tools/icons/template.svg` (it already takes tokens), `modules/gnome/install.sh`, `tools/welcome`, `tools/store-gtk`.
- **Serves:** the owner (note 032921, "make an art scheme"), Daniel (contrast), Tomás (a real opaque fallback), the maintainer (one colour change means one file edit plus a rebuild).
- **Verified by:**
  - `tests/vm/contrast.sh` on the top bar, clock menu, quick settings and monitor popup, over the option's own wallpaper in light and dark and over the busy photo. Every text line must be ≥ 4.5:1, including the inactive numerals and "No Notifications".
  - E3's brightness line.
  - `tools/icons/export.sh --check`, `bats tests/`, `tests/vm/dconf-test.sh`.

**M7. The now-playing pill.**
- **What:** a module in `tweaks`: `tweaks/nowplaying.js`, no 14th extension.
  - **Watching:** it watches `org.mpris.MediaPlayer2.*` through `ListNames`, `NameOwnerChanged` and each player's `PropertiesChanged`. No timers while idle or locked.
  - **When it shows:** next to the clock, only while a player is Playing or Paused and has a non-empty title. It ignores the drawer's empty players. It does not depend on `DesktopEntry` (facts row 19). It never fetches `mpris:artUrl` over the network; only `file://` art is shown (principle 5).
  - **Compact view:** app icon, a truncated title and a play/pause button.
  - **Drop-down:** a click opens its own glass drop-down with title, artist, local art, and previous / play-pause / next. The buttons are named and at least 24 px (WCAG 2.2 AA target size), 32 preferred. A 1 s progress tick runs only while the drop-down is open and the player is playing, on `PowerAwareTimer`.
  - **Settings:** schema key `now-playing-pill` (boolean, default false until E1 passes), plus an unset keybinding key. It is reachable from `ostrich config` and `settings.dconf`, has a row on the Top bar page of Ostrich Settings, and a wizard Top bar step.
- **Where:** `modules/gnome/extensions/tweaks/nowplaying.js` (new), the tweaks schema, `tweaks/stylesheet.css`, `home/run_onchange_after_ostrich-settings.sh.tmpl`, `tools/welcome`, `tests/vm/ui-test.sh`.
- **Serves:** the owner (note 194002), Kai and anyone who plays music, Priya (the key). Rosa and Tomás see nothing until something plays.
- **Loses:** some top-bar width at 200 % text, and one more surface to test.
- **Verified by:**
  - Mock-player scenes: none, paused, playing, quits mid-track, two players, a 200-character title, no art, and a locked screen. Screenshots in light and dark at scale 1 and 2; nothing pushed off the bar.
  - `ext-test.sh tweaks`.
  - An AT-SPI dump showing named buttons.
  - E1 decides the default.

### Should (next)

- **GNOME card restyle:** `ost-` CSS on GNOME's media card in the clock menu (glass, radius, type).
  - Where: `tweaks/stylesheet.css`.
  - Serves: everyone who plays media with the pill off.
  - Verified by: a mock-player screenshot in light and dark that stays inside the panel.
- **Accessible names everywhere:**
  - Each monitor row becomes a toggle named "Temperature, 62 degrees, pinned to top bar" (`monitor/extension.js:78-105`).
  - Dock and workspace buttons get names.
  - A new `tests/vm/a11y-test.sh` lists any unnamed button.
  - Serves: Daniel. Verified by: the script reports 0 unnamed.
- **Drawer memory:**
  - Start with the "Unloaded to save memory / Load" placeholder (`tools/drawer-host/src/main.rs:297-309,1077-1080`).
  - Show the MB cost next to each keep-alive switch in Ostrich Settings > Drawer, and warn above two kept-alive sites on 8 GB or less.
  - Serves: Tomás, Rosa. Verified by: `free -m` and `ps` at login versus T12's 1.5 GB RSS, aiming for at least 200 MB less (lowend's lab).
- **A default player:**
  - First check a fresh Ubuntu 26.04 install (T10 ran on try-me, which is your migrated machine). If there's no video or audio handler, install your pick (question 5) and set it as the default for `video/*` and `audio/*` (`modules/tools/install.sh:201-232`).
  - Add `tests/vm/everyday-test.sh` (web link, video, audio, a player on MPRIS).
  - Serves: Rosa, Kai.
- **Store's Media group:** add Spotify (verified snap first) and a music app (`tools/welcome/data/recommended.toml`, Store catalogue).
  - Serves: Kai, the owner. Verified by: `store-test.sh` finds and opens both.
- **Battery polls:** the drawer hover check goes to 400 ms on battery through `PowerAwareTimer` (`drawer/extension.js:43,296`), and the tiling drag poll to 100 ms on battery (`tiling/extension.js:27,307`).
  - Serves: Tomás, the owner on battery. Verified by: a wakeup count during hover-open with no portal dialog (re-run T8 after M4).
- **Settings and Store page transitions:** a short cross-fade with `AdwAnimation`/`GtkStack`, which already honours `gtk-enable-animations` (facts row 9).
  - Where: `tools/welcome`, `tools/store-gtk`. Serves: the owner, Rosa.
- **First-party icon family:** glass-square glyphs for Help and the app-grid button. Files keeps a folder shape (design 2).
  - Where: `tools/icons/glyphs/`. Verified by: a 3:1 glyph contrast check and a deuteranopia/protanopia check at 48 and 32 px (design's untested request).
- **Icons follow the accent:** when the accent changes, the palette tool re-runs `export.sh --accent` into `~/.local/share/icons/hicolor/`.
  - Serves: users who pick another accent. Verified by: changing the accent in the VM, the dock icons' accent part follows.
- **Target sizes:** at least 24 px for `.ost-vital-button` (`monitor/stylesheet.css:14-23`), keeping the compact rows.
  - Serves: Daniel. Verified by: measured in a screenshot.

### Experiments

- **E1. Pill on by default.**
  - Measure: `SETTLE=30 WINDOW=120 measure.sh`, twice each with the pill enabled and the mock player Paused, then Playing, with the menu closed.
  - **Keep on:** shell CPU ≤ 0.16 % and shell wakeups ≤ 4.4/s in all runs (T4's no-player spread), with no top-bar backdrop re-blur on a play/pause toggle. DESIGN.md principle 4 also needs the Dell battery run within the noise of pill-off.
  - **Otherwise:** it stays off by default and remains a switch.
- **E2. Motion cost and visibility.**
  - Measure: a `drawer` workload in `shell-bench.sh` (open and close every 1.5 s, B4) on the VM pinned to one CPU.
  - **Keep:** the median is no higher than the overview workload's median on the same VM.
  - **Revert:** the drawer goes to duration 0 on software rendering only.
  - Visibility gets judged on the Dell at `animation-speed` 1.0 by you. If it's still "barely visible", the answer is your speed setting, not a longer default.
- **E3. Glass tint brightness.**
  - Measure: `tests/vm/compare.sh --dark` over the busy photo, with the chosen scheme against the b1cbbc8 build. Mean brightness behind the bar, the dock and a menu.
  - **Keep:** within 5 points on all three.
  - **Revert to today's neutral tint:** more than 10 points.
  - **Between 5 and 10:** you look at the side-by-side and decide.
- **E4. Widevine in the drawer** (only if you say yes, question 2).
  - Setup: an opt-in consent screen naming the source and licence; a pinned, checksummed, per-user download (no root, never committed); removal with one command.
  - **Keep:** Spotify plays inside the WebKitGTK 2.52 drawer under the sandbox, and it still plays after one WebKitGTK update, checked by a `tests/vm/` case.
  - **Revert:** if it fails either, or the download can't be pinned. Then M5's buttons stay the answer.
- **E5. Reduced motion as a fade.** On the Dell, with `reduced-motion=reduce`, record the drawer opening on video.
  - **Keep:** no translation is visible, only the fade.
  - **Revert:** if any slide shows, `reduce` becomes duration 0.
- **E6. Slower snap seeding.**
  - Measure: `systemd-analyze critical-chain` on a fresh install with and without our snap installs.
  - **Act (move or defer our snap installs) only if:** ours add more than 2 s to `snapd.seeded.service`.

### Not now

- **Per-tier duration keys** (`motion-short-ms` and the others).
  - Where: the tweaks schema, `ostrich config`. Serves: Priya. Verified by: `dconf-test.sh`.
  - Reason: one `animation-speed` covers it, and quality wants one test surface.
- **`scheme = ostrich|plain` and a "no tint" switch.**
  - Where: the tweaks schema, `palette.toml`. Serves: Priya. Verified by: `compare.sh` with each value.
  - Reason: revisit after E3. If the tint passes, nobody needs it gone.
- **Retiring App Center from the app grid.**
  - Where: `modules/gnome/install.sh`. Serves: Rosa (one store). Verified by: snaps still refresh, and snapd-desktop-integration notices still work.
  - Reason: facts row 23 says updates don't depend on it, but its notices are unchecked.
- **Merging Settings pages** (Blur into Theme, Windows into Tiling).
  - Where: `tools/welcome`. Serves: Rosa. Verified by: a keyboard-order walk (access's condition).
- **A CI job against a real GNOME Shell.**
  - Where: `.github/workflows/ci.yml`. Serves: the maintainer, so a GNOME 51 change doesn't break us silently. Verified by: the job fails on a deliberately broken `_calendar` reference.
  - Reason: feasibility on a GitHub runner is unknown.
- **A lock-screen media metadata setting.**
  - Where: tweaks. Serves: Daniel, security. Verified by: the lock screen with the mock player.
  - Reason: GNOME 49's controls have no clean off switch (facts row 22).
- **A per-site navigation/notification policy UI.**
  - Where: Ostrich Settings > Drawer. Serves: Priya. Verified by: a `drawer-test.sh` toggle.
  - Reason: M5's defaults first.

## Rejected

- **Chromium/Electron view for DRM sites.** A second heavy engine on top of T12's 1.5 GB, and nothing backs it but one forum thread.
- **Vendoring or depending on "Media Controls" (extension 10373).** Its licence is unknown and its lyrics probably use the network (facts row 21). It stays a design reference only.
- **Calendar grid back by default.** It reverses owner notes 193812 and 032844, and it's already a switch.
- **Animating blur radius or layout.** It costs a re-blur every frame (mobile, lowend). No seat defended it.
- **A per-site hard memory cap.** It would be a lock. A warning is enough (power conceded).
- **Claims withdrawn or disproved, which carried no weight:**
  - The race as a visible bug (T2).
  - The ghost shape moving or flickering (T5).
  - Boot doubling caused by us (T17).
  - The "0.8 default" (facts row 4).
  - "The Store already finds Spotify" (facts row 44, a test fixture).
  - The "blank DRM panel" (facts row 14, it was YouTube).
  - "No media extension supports GNOME 50" (facts row 21).
  - "The card goes in the right column" (facts row 18).

## Owner vs most people

- **Pill vs card.** You asked for the pill. Most seats would ship GNOME's card alone.
  - **Default:** the card, until E1 passes; then the pill is on.
  - **Setting:** "Show now playing next to the clock" in Ostrich Settings > Top bar.
  - On your machine you can turn it on the day it's built.
- **Motion amount.** You want brisk motion everywhere. Tomás and Daniel need cheap motion, or none.
  - **Default:** 120/170/200 ms on our surfaces, zero in power saver, a fade under reduced motion.
  - **Setting:** your `animation-speed` (your migrated 0.8 survives upgrades; quality adds a `dconf-test.sh` line).
- **Fixed clock menu vs large text.** Your shape holds at normal sizes, and only the right column scrolls at large text. Nobody sees a different box.
- **Compact rows vs target size.** The rows stay compact (note 032706). Only the buttons grow to 24 px.
- **Spotify in the drawer.** You asked for it. Most people are better served by the real app now.
  - **Default:** the app or browser buttons.
  - **Your route:** the opt-in experiment E4.
- **Colour.** The only colour words on record are "clean" and "glassy", plus "make an art scheme". Which option fits best is taste, and opinion decides it. That's why you choose. All three keep the 9 GNOME accents, "follow wallpaper", slate and dark selectable, and none lowers the glass brightness beyond E3's line.

## Options for the owner

All three use the same token structure in `tools/icons/palette.toml`. In every option:
- Text on glass is never dimmed. Hierarchy comes from size and weight, as `monitor/stylesheet.css` already does.
- Accent colours that carry white text use `accent_strong`, which passes 4.5:1. GNOME's own accent shades all fail with small white text: slate 3.9, orange 3.4, blue 3.8 (my arithmetic, WCAG formula). So the plain `accent` is used only for fills without text: the dock's focused-window dot, progress bars, focus rings, toggles and tiling previews.
- The top bar is dark glass with white text in both light and dark mode, as today.
- App icons are one set in both modes, because hicolor has no light/dark split.
- Contrast figures for icon colours are my arithmetic. `contrast.sh` and the M6 gate confirm them on screen.

**How every option fixes the two T6 failures:**
1. **Inactive workspace numerals (3.73:1 on the default wallpaper).** `.ost-ws-empty` goes from `rgba(255,255,255,0.5)` to `rgba(255,255,255,0.80)` at regular weight. Occupied workspaces stay full white and bold, so "empty" is shown by weight and shade, not by failing contrast. My arithmetic over the measured bar background (about #464646): 0.5 gives about 3.7, and 0.80 gives about 6.7.
2. **"No Notifications" (4.47:1 on the dark menu over the photo).** GNOME's placeholder label (`.message-list-placeholder` in GNOME 50's theme; confirm the class in the VM) gets the scheme's full `text` colour inside `.ost-blur-menu`, instead of the theme's dimmed colour. The menu tint also rises by 0.02 in the scheme's hue, which adds margin for "Saturday" (4.72). Both are gated by `contrast.sh` over three backgrounds, and E3 holds the brightness.

### Option A: "Slate Glass" (calm, low saturation; closest to your current setup)

| Token | Dark | Light |
|---|---|---|
| `accent` (GNOME `accent-color`) | `slate` #6f8396 | same |
| `accent_strong` (fills with white text) | #546575, 6.0:1 with white | same |
| `accent_text` (links and selected text on glass) | #a9bccc | #546575 |
| `icon-theme` | `Yaru-sage-dark` | `Yaru-sage` (Ubuntu's own pairing for slate, as on your machine, `docs/INVENTORY.md:138`) |
| Icons: `shell_top` / `shell_bottom` | #4a5468 / #1f2430 (unchanged) | same |
| Icons: `edge` / `highlight` / `glyph` | #ffffff (at 0.2) / #ffffff / #f4f6fa (unchanged) | same |
| Icons: `accent_icon` (replaces amber #f2a541) | #a9bccc: about 3.9:1 on `shell_top`, 8:1 on `shell_bottom` | same |
| Text on glass | #f4f6fa | #1f2430 |
| Top bar glass / solid | rgba(20,24,32,0.14) / #1c2028 | same (dark bar) |
| Dock glass / solid | rgba(20,24,32,0.18) / #1c2028 | rgba(246,248,250,0.18) / #f3f5f7 |
| Menus glass, border / solid | rgba(24,28,36,0.12), rgba(255,255,255,0.09) / #1c2028 | rgba(246,248,250,0.62), rgba(255,255,255,0.55) / #f3f5f7 |
| Banners / folders glass | rgba(24,28,36,0.16) / rgba(28,32,40,0.24) | rgba(246,248,250,0.66) / rgba(246,248,250,0.40) |
| Workspace pill: active / occupied / empty | white fill, black numeral (or `accent_strong` with white if you keep the accent style) / #ffffff bold / rgba(255,255,255,0.80) regular | same (on the dark bar) |
| Focus ring | `accent` at 80 % (2 px) | `accent_strong` (2 px) |

- **Store:** libadwaita `--accent-bg-color` #546575 for the selected tab, header and primary button; `--accent-color` #a9bccc in dark and #546575 in light.
- **Wallpaper:** generated locally from these tokens by a small script (`tools/wallpaper/make.sh`, our own code). It draws a slate-to-ink gradient with two soft blooms (#6f8396 and a muted warm #8a7a6a), plus a pale slate-mist light variant, at the screen's native size. Output goes to `~/.local/share/backgrounds/ubuntu-ostrich/`. Nothing is downloaded or committed.
- **Backed by:** you (calm, keeps slate and dark), simplicity (smallest change), security (no download), mobile (dark-leaning, low saturation), lowend (tiny file).
- **Costs:** the least character. The blooms give the glass colour but little detail to refract. A small mismatch remains: Yaru has no slate folder, so folders are sage, grey-green beside blue-grey.

### Option B: "Ubuntu Ember" (warm; keeps the Ostrich's warm identity and matches Yaru exactly)

| Token | Dark | Light |
|---|---|---|
| `accent` | `orange` #ed5b00 | same |
| `accent_strong` | #b84700, 5.3:1 with white | same |
| `accent_text` | #ff9a4d | #b84700 |
| `icon-theme` | `Yaru-dark` | `Yaru` (Ubuntu's default, orange folders: no mismatch at all) |
| Icons: `shell_top` / `shell_bottom` | #4f4a46 / #24211f (warm charcoal) | same |
| Icons: `edge` / `highlight` / `glyph` | #ffffff (0.2) / #ffffff / #f7f3ef | same |
| Icons: `accent_icon` (replaces #f2a541) | #ff9a4d: about 4.2:1 on `shell_top`, 7.6:1 on `shell_bottom` | same |
| Text on glass | #f7f3ef | #2a2420 |
| Top bar glass / solid | rgba(24,20,18,0.14) / #221e1b | same |
| Dock glass / solid | rgba(24,20,18,0.18) / #221e1b | rgba(252,249,246,0.18) / #faf7f4 |
| Menus glass, border / solid | rgba(32,26,22,0.12), rgba(255,255,255,0.09) / #221e1b | rgba(252,249,246,0.62), rgba(255,255,255,0.55) / #faf7f4 |
| Banners / folders | rgba(32,26,22,0.16) / rgba(36,30,26,0.24) | rgba(252,249,246,0.66) / rgba(252,249,246,0.40) |
| Workspace pill: active / occupied / empty | `accent_strong` #b84700 fill with white numeral / #ffffff bold / rgba(255,255,255,0.80) regular | same |
| Focus ring | `accent` at 80 % | `accent_strong` |

- **Store:** `--accent-bg-color` #b84700; `--accent-color` #ff9a4d in dark and #b84700 in light.
- **Wallpaper:** Ubuntu's own `mendhak-Red_Acer.jpg` (warm leaves), already in `/usr/share/backgrounds` on 26.04, used for both modes. No download, nothing committed. If a fresh install lacks it, the installer adds the Ubuntu archive package that ships it (signed by the archive, versioned by the release). If that fails, Ubuntu's default stays.
- **Backed by:** design (one accent end to end, Yaru matches exactly, a photo for the glass), maintainer (no icon-theme mismatch, nothing to download), everyday and newcomer (looks like the Ubuntu people know, *opinion*).
- **Costs:**
  - It is the loudest of the three. Orange is a step away from "clean, glassy" (*opinion*).
  - Slate stops being the default, though it stays selectable.
  - A busy warm photo leaves the least contrast margin, so the M6 gate matters most here.

### Option C: "Night Glass" (cool blue over a photo with depth)

| Token | Dark | Light |
|---|---|---|
| `accent` | `blue` #3584e4 | same |
| `accent_strong` | #1c62b9, 6.0:1 with white | same |
| `accent_text` | #78aef0 | #1c62b9 |
| `icon-theme` | `Yaru-blue-dark` | `Yaru-blue` |
| Icons: `shell_top` / `shell_bottom` | #3d4a63 / #151b2a (ink blue) | same |
| Icons: `edge` / `highlight` / `glyph` | #ffffff (0.2) / #ffffff / #f3f6fb | same |
| Icons: `accent_icon` | #78aef0: about 3.9:1 on `shell_top`, 7.5:1 on `shell_bottom` | same |
| Text on glass | #f3f6fb | #172033 |
| Top bar glass / solid | rgba(10,14,24,0.14) / #141a26 | same |
| Dock glass / solid | rgba(10,14,24,0.18) / #141a26 | rgba(245,248,253,0.18) / #f5f8fd |
| Menus glass, border / solid | rgba(14,20,34,0.12), rgba(255,255,255,0.09) / #141a26 | rgba(245,248,253,0.62), rgba(255,255,255,0.55) / #f5f8fd |
| Banners / folders | rgba(14,20,34,0.16) / rgba(18,24,38,0.24) | rgba(245,248,253,0.66) / rgba(245,248,253,0.40) |
| Workspace pill: active / occupied / empty | `accent_strong` #1c62b9 with white numeral / #ffffff bold / rgba(255,255,255,0.80) regular | same |
| Focus ring | `accent` at 80 % | `accent_strong` |

- **Store:** `--accent-bg-color` #1c62b9; `--accent-color` #78aef0 in dark and #1c62b9 in light.
- **Wallpaper:** two Ubuntu-shipped images already on 26.04: `mizuno-as-Big_Dipper.jpg` (night sky) for dark and `mendhak-Bluebells_Suspended_In_Time.jpg` for light. The fallback is the same as Option B: the signed archive package, then Ubuntu's default. Nothing committed.
- **Backed by:** newcomer and everyday (blue is the default accent on GNOME, Windows and macOS, so the least surprise; *opinion, no source given*), access (a familiar focus colour, *opinion*), design (depth for the glass).
- **Costs:** the furthest from your slate, and the most generic, so the least "ours" (*opinion*). Two wallpaper files instead of one.

**What changes when one colour changes:** in every option you edit one file (`tools/icons/palette.toml`) and rebuild: `build.sh` for the stylesheets and `_lib/tokens.js`, `export.sh` for the icons. The accent-derived colours (`accentStrong`, `accentFg`) are recomputed by the palette tool when a user picks another accent.

**Memory and battery:** all three are colour fills with no extra blur passes. The wallpapers are no larger than Ubuntu's own 3840 × 2160 default. Option A's is the smallest. M6 checks the used-memory delta with `measure.sh`; the line is no more than 40 MB above the default wallpaper.

If you want to see them first, M6 builds all three as previews and runs `tests/vm/compare.sh --dark` and the light variant over each option's wallpaper. Then you pick, as you did with the blur.

## Questions for the owner

1. **Which colour option: A (Slate Glass), B (Ubuntu Ember) or C (Night Glass)?** Or should all three be built as VM previews first? Setting `icon-theme` and the wallpaper on a fresh install is new for the installer (DESIGN.md's palette section sets only `accent-color`), so your pick also approves that addition.
2. **Widevine experiment E4: yes or no?** No means M5's app and browser buttons are the whole answer to note 194359 for now.
3. **Notifications for sites added with "+".** Should they start off, with a per-site switch? That changes DESIGN.md:110, which grants every chosen site permission up front. M5 already narrows the grant to each service's own site, which DESIGN.md allows.
4. **A Spotify icon in the drawer bar.** Should the bar be allowed an icon that launches the Spotify app rather than a web panel? That changes the drawer model in DESIGN.md:99 and 106.
5. **A default player on a fresh install.** If the fresh-install check finds no video or audio player: install one, and which (a GNOME app as a deb, or VLC)? It adds disk and packages.
6. **The pill's default rule.** Do you accept E1's line, including the Dell battery run that DESIGN.md principle 4 requires? The pill also needs a line in DESIGN.md's tweaks row and a wizard step; approving this verdict approves those.
7. **The clock menu at large text.** Do you accept the right column scrolling inside your fixed 688 × 468 box when text is above 1.25? It stretches note 194146 for large text only.
8. **The portal crash.** If M4 finds it can't be avoided without weakening WebKit's sandbox or hiding Ubuntu's crash reports, do you accept it as a known Ubuntu issue (reported upstream) until Ubuntu fixes it?

Files: debate folder `~/.local/share/ubuntu-ostrich/vm/council/2026-10-24-motion-now-playing-spotify-colour` (tests in `tests.md`, screenshots in `evidence/tests/`). Repo: `/home/liamkennedy/Claude Projects/Cleanest ubuntu setup` (`tools/icons/palette.toml`, `tools/icons/template.svg`, `modules/gnome/extensions/blur/stylesheet.css`, `modules/gnome/extensions/workspaces/stylesheet.css`, `tools/palette/src/output.rs`).
