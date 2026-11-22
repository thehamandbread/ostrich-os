# What every feature is supposed to do

The checklist Ostrich OS is tested against. Each row says what a feature **should** do,
written from the intent docs (`DESIGN.md`, `DEFAULTS.md`, `PARITY.md`, the council verdicts in
`council/`, `DECISIONS.md`) and the owner's notes, **not from the code**, so a test can catch code
that does the wrong thing. Where the docs don't say, the row says **ask** instead of guessing.

**How checked** names the test that proves the row: a VM suite (`tests/vm/NAME.sh`), `bats`,
`js` (`tests/js-test.sh`), `cargo` (`build-tools.sh --check`), **manual** (a person has to look or
listen; listed in the checklist at the end) or **new** (no test yet: one gets written).

**Status:** `untested`, `pass` (with the run's date), `FAIL` (with the note or issue), `hw` (only
real hardware can tell: the Dell). Every row starts `untested`; Phase B fills them in.

Notes are the owner's VM critiques (`tests/vm/critique.sh show ID`), by their time stamp.

## 1. Install, update, undo

| ID | Should do | How checked | Status |
|---|---|---|---|
| INS-1 | `install.sh` on a fresh Ubuntu 26.04 installs everything with no questions (except the sudo password once, and Keep/Clean if other extensions exist). | e2e | untested |
| INS-2 | Running it twice changes nothing the second time; `--dry-run` lists changes and makes none. | Docker smoke, e2e | untested |
| INS-3 | Before overwriting one of the few files it changes (dotfile additions, `gtk.css`, the extensions folder), copies that file under `~/.local/state/ostrich-os/backups/`. Your own files are never copied or touched. | bats (restore), e2e | untested |
| INS-4 | Logs what each module changed to `~/.local/state/ostrich-os/install.log`. | e2e | untested |
| INS-5 | Stops before installing when the tools build in `BUILD_DIR` is stale or partial (`.tools-stamp`). | bats | untested |
| INS-6 | Keep (default): only the extensions Ostrich replaces are switched off; Clean: every other one too, settings reset. Nothing deleted either way. | e2e (keep/clean round trips) | untested |
| INS-7 | Carries over as much as it can from what it replaces: Space Bar names; Just Perfection animation speed and start-in-overview; Tiling Assistant keys, gap and popup; Dash to Dock hiding, icon size, background colour and opacity; Vitals' pinned readings and panel position; Blur my Shell's strength and brightness per surface. | e2e from `pre`, bats | pass (bats, 2026-11-01) |
| INS-8 | Leaves alone: light/dark, accent, wallpaper, workspace count, speaker tuning (until chosen in the tour). | e2e | untested |
| INS-9 | Notification banners end up on; idle-delay the user had is kept. | e2e | untested |
| INS-10 | Third-party downloads are pinned and checksum-verified; the release tools and extensions match `SHA256SUMS`. | bats, e2e | untested |
| UPD-1 | `ostrich update` gets the latest and re-applies; safe to run any time; works after a one-line install and after a checkout install. | e2e | untested |
| UPD-2 | Hardware modules re-detect on every run (a drive moved to another PC picks up that PC's hardware). | new (bats with fake sysfs) | untested |
| UNI-1 | First install takes a restore point: `dconf dump /`, the extensions folder, replaced files, the package list. | e2e --uninstall | untested |
| UNI-2 | `ostrich uninstall` puts every setting back as it was at install time, removes what was added, keeps Store apps, and stops running Ostrich apps first. | e2e --uninstall, state.sh | untested |
| UNI-3 | `--keep-new-settings` undoes only Ostrich's own settings (and a scheme still on). | dconf-test | untested |
| UNI-4 | User-made things (drawer sites, saved workspaces, a settings export, own schemes) are copied into the kept restore point; the last line says where. | e2e --uninstall | untested |
| UNI-5 | `--remove-packages` lists the packages and needs a typed `remove`; without it nothing is removed. | bats | untested |
| UNI-6 | Classic (no scheme) and uninstall keep the user's own `gtk.css`. | bats | untested |

## 2. Top bar and desktop extensions

### Monitor (replaces Vitals)

| ID | Should do | How checked | Status |
|---|---|---|---|
| MON-1 | Top bar shows CPU, memory, temperature (the average of all sensors, also the Temperature section's summary) and GPU state; values pinned with the star show in the order pinned. | ui-test | untested |
| MON-2 | Updates every 2 s on AC, 5 s on battery; in power saver it stops reading, and the top bar's readings fold away (fade and squeeze to the left) to a power-saver icon and, on battery, the time left (owner, 2026-11-18), which unfolds back when saver ends (owner, 2026-11-09); none while locked or blanked; a shut popup reads only what's pinned. | ext-test, power-test | built; VM check pending |
| MON-3 | Popup sections (processor, memory, temperature, fans, voltage, system, network, storage, battery, graphics) with values on the right; hide zero values; refresh, open System Monitor, settings. | ui-test | untested |
| MON-4 | Never wakes the NVIDIA GPU: reads it only when `runtime_status` is `active`; shows which apps woke it, with quit and keep-off. | hw | hw |
| MON-5 | Battery time left and draw in watts. | hw | hw |
| MON-6 | Warns once before memory runs out (85 %, clears at 75 %) with a pop-out alert (ALERT) from the monitor, naming the app if it holds a tenth of memory, with End app and Open System Monitor. | js, new (VM with a memory hog) | pass (alert-test, 2026-11-01) |
| MON-7 | Holds the power-mode switch; a mode change applies the helper's hardware knobs (no password). | power-test, polkit-test | untested |
| MON-8 | Text on the popup reads 4.5:1 or better. | contrast | untested |
| MON-9 | The popup opens with the values you pinned to the top bar at the top (in pin order, each with its star to unpin), then the sections, every one closed each time it opens (owner, 2026-11-18); several can be open side by side. | tests/vm/monitor-look-test.sh | PASS |

### Pop-out alerts (all Ostrich system alerts)

| ID | Should do | How checked | Status |
|---|---|---|---|
| ALERT-1 | An Ostrich system alert grows out of the top-bar item it belongs to and expands into a glass card: title, one plain line on what's happening, the app's icon and name, buttons. App notifications (mail, chat) stay normal banners. | new | pass (alert-test, 2026-11-01) |
| ALERT-2 | Used for: memory nearly full (End APP, Open System Monitor), low battery / power saver on (Keep balanced), NVIDIA GPU woken (Quit APP, Keep it off NVIDIA). End app asks once first. | new | memory: pass (alert-test); battery, NVIDIA: hw |
| ALERT-3 | Follows the motion rules (Reduced Motion: a fade), stays while hovered, closes with Esc or ✕, is read by Orca. | new, a11y-test | built; Esc/Orca pending |

### Dock (replaces Dash to Dock / Ubuntu Dock)

| ID | Should do | How checked | Status |
|---|---|---|---|
| DOCK-1 | Floating at the bottom, sized to its icons, 40 px icons, 8 px gap, rounded, frosted. Stays in the overview, where GNOME's own dash is hidden (owner, 2026-11-18). | ui-test, compare | untested |
| DOCK-2 | Hides only when a window is in the way (intellihide); touching the bottom edge brings it back; can be always shown. | ui-test | untested |
| DOCK-3 | A dot per window (up to 4, accent on the focused app); click focuses, or minimizes the app in front (or next window); scroll cycles windows; middle-click new window. | ui-test | untested |
| DOCK-4 | Hover shows live previews; click switches, middle-click closes. | ui-test | untested |
| DOCK-5 | Unread badges and progress from apps that send them. | new | untested |
| DOCK-6 | Hides from fullscreen apps; no timers while hidden. | ext-test | untested |
| DOCK-7 | Never vanishes for good (no state where it can't be brought back). | ui-test | untested |
| DOCK-8 | Fluid motion: the hover preview grows out of its icon and glides between icons; the dock slides in and out; icons lift on hover; a launch bounces once. | motion-test, manual | built; motion-test pending; needs your eye |
| AUD-1 | An app playing sound gets a speaker badge on its dock icon; clicking it pauses that app (its media player). Follows the players' own signals (MPRIS), no timers. | new | pass (nowplaying-test, 2026-11-02; by MPRIS: GNOME's mixer can't tell playing from open) |

### Blur (replaces Blur my Shell)

| ID | Should do | How checked | Status |
|---|---|---|---|
| BLUR-1 | Frosted glass behind the top bar, dock, menus and pop-ups, overview and app grid, app folders, lock screen; each can be solid. | blur-test | pass (blur-test, 2026-11-01) |
| BLUR-2 | The blur covers the whole surface up to its rounded border (note 224817). | new (blur-test edge check) | pass in blur-test; the note's shot not reproduced |
| BLUR-3 | Re-blurs only when what's behind changes; panel repaints (clock, monitor) never trigger a re-blur. | blur-test, shell-bench | untested |
| BLUR-4 | Power saver: the top bar and dock keep a blur of the wallpaper, computed once; menus, the overview, app folders and pop-ups turn solid black. | power-test, blur-test | pass (blur-test, incl. quick settings, 2026-11-02) |
| BLUR-5 | No flicker of the top bar or menus while the pointer moves over app windows (note 224647). | new | fixed: the bar blurs only the wallpaper (blur-test, 2026-11-02) |
| BLUR-6 | GNOME's High contrast turns the glass solid and readable. | contrast | untested |
| BLUR-7 | Logs no warnings in the shell journal (none today: `ost-blur-backdrop` allocation/stage warnings). | new (journal gate) | FAIL |

### Workspaces (replaces Space Bar)

| ID | Should do | How checked | Status |
|---|---|---|---|
| WS-1 | Bold pills at the top left named after their apps (smart names), or the user's name. | ui-test | untested |
| WS-2 | Click switches; click on the current one opens the overview; scroll switches, one workspace per scroll movement, wheel or touchpad (no wrap by default; owner, 2026-11-09); drag to reorder (names move); drop a window from the overview onto one. | ui-test | untested |
| WS-3 | Right-click: rename, add, move left/right, remove (its windows move next door). Super+Alt+N / R / Page Up/Down. | ui-test | untested |

### Tweaks

| ID | Should do | How checked | Status |
|---|---|---|---|
| TW-1 | Super opens and closes the overview, as stock GNOME (a quick double press goes to the app grid). Starts on the desktop. | ui-test | untested |
| TW-2 | Animation speed setting works and carries over from Just Perfection. | motion-test | untested |
| TW-3 | Accent picked from the wallpaper and re-picked when it changes, unless the user chose one. | new | untested |
| TW-4 | Yaru folder icons match light/dark (and the scheme's folder colour). | new | untested |
| TW-5 | Hides the top-bar items switched off in Settings → Top bar. | ui-test | untested |
| TW-6 | Today panel (clock menu): fits at text scale 1 and 2; "show calendar events" off hides the events card at once (note 224757). | ui-test | pass (ui-test, 2026-11-01) |
| TW-7 | Speaker tuning tile (Off / Correction / Custom); Touchscreen tile only when a touchscreen exists. | ui-test, hw | untested |
| TW-8 | Logs no warnings (today: removes a `now-playing-play-pause` keybinding it never added). | new (journal gate) | FAIL |
| TW-9 | Pushing the pointer into the top-right corner toggles quick settings, exactly like GNOME's top-left hot corner (same pressure, ripple, works in the overview, not over a fullscreen window on that monitor; with a monitor to the right of the top-bar one, the corner is on the outer right edge of the right-most monitor). | new | untested |
| TW-10 | The clock and the now-playing orb open on a click only (hover-to-open removed, owner 2026-11-18); with nothing playing the orb stays hidden, also after the overview. | new | untested |
| TW-11 | On a machine with three power modes (power-profiles-daemon lists Power Saver, Balanced and Performance), quick settings shows one full-width Saver \| Balanced \| Performance row where GNOME's Power Mode tile sat; one click picks a mode, Tab and the arrow keys reach it. GNOME's tile is hidden only while the row shows and comes back with two modes, on any failure, on disable, or with `quick-settings-style` = `stock` (council 2026-11-09, M2/M3). | powerrow-test | tested |
| TW-12 | Do Not Disturb and Focus switches under the date in the clock menu, each with On or Off in text, on the same state as their quick-settings tiles (show-banners inverted; the focus extension's `focus-on`); the tiles stay. `clock-menu-quiet` hides them; the Focus switch is left out when the focus extension is not running or is older (council 2026-11-09, M5). | quiet-test | tested |
| TW-13 | Lit quick-settings tiles use the accent darkened to 94 % and medium-weight subtitles, so their text reaches 4.5:1 in light, dark and power saver; "No Notifications" gets the full text colour in saver (council 2026-11-09, M4). | qs-contrast-test | built; VM check pending |
| TW-14 | While quick settings is open, up to three paired Bluetooth devices show as tiles right below GNOME's Bluetooth tile (connected first, then the most recently connected): one press connects or disconnects, and the tile says Connecting…, Connected, Not connected or "Couldn't connect" (the full hint "Is it on and in range?" is its accessible description). Nothing shows without an adapter that is on or without a paired device; no scanning or pairing; GNOME's tile stays. A Bluetooth client exists only while the menu is open. Follows `quick-settings-style` (council 2026-11-09, owner's choice). | new | tests/vm/bluetooth-test.sh |

### Now playing (in tweaks)

| ID | Should do | How checked | Status |
|---|---|---|---|
| NP-1 | A pill beside the clock that pops out of it when something starts playing and goes back a few seconds after it stops (MPRIS signals); click for play/pause/next. | nowplaying-test | pass (nowplaying-test, 2026-11-02) |
| NP-2 | Sound from any app shows, including a drawer site after the drawer is folded up (notes 224940, 225032). | new | pill: pass; a drawer site needs its media session (VM: hw) |
| NP-3 | The play/pause shortcut works when set; unset by default. | nowplaying-test | pass (nowplaying-test, 2026-11-02) |
| NP-4 | Pill default: on only if its idle cost passed (council E1). **ask**: on or off by default? Off until the owner answers. | ask | decided: on, shown only while playing (owner, 2026-11-02) |

### Tiling (replaces Tiling Assistant)

| ID | Should do | How checked | Status |
|---|---|---|---|
| TIL-1 | Super+←/→ halves, then Super+↑/↓ quarters; Super+keypad 7/9/1/3; drag to an edge or corner with a preview. | ui-test | untested |
| TIL-2 | After a tile, a popup offers windows (all workspaces) to fill the rest; tiled windows raise together; resizing one moves the shared edge. | ui-test | untested |
| TIL-3 | GNOME's edge tiling and clashing shortcuts are off while enabled and back when disabled. | ext-test | untested |

### Tray, focus, holder-monitor, search-new-window

| ID | Should do | How checked | Status |
|---|---|---|---|
| TRAY-1 | StatusNotifier icons in the top bar, always just left of quick settings (right of the drawer's icons); menus fetched only when opened; left click activates, middle-click and scroll passed on. | ext-test (sni-test-item) | untested |
| FOC-1 | Super+Alt+F or the quick-settings tile: DND on, drawer muted, dock, tray, monitor, workspace bar, drawer icons hidden; optional allow-list of apps (others minimised and hidden from grid and search). | env-test | untested |
| FOC-3 | The Focus tile says On or Off; the state is the `focus-on` setting, so the clock-menu switch and `ostrich config set focus focus-on true` set it too (council 2026-11-09). | quiet-test | tested |
| FOC-2 | Turning it off puts back the exact previous state. | env-test | untested |
| HM-1 | With two displays, windows on the non-primary one stay out of Alt+Tab; does nothing with one display. | ext-test (VM_OUTPUTS=2) | untested |
| SNW-1 | Enter on a running app in overview search opens a new window. | ui-test | untested |

### Every extension

| ID | Should do | How checked | Status |
|---|---|---|---|
| EXT-1 | All 11 enable, show as ACTIVE, and survive 20 enable/disable cycles with no JS errors. | ext-test | untested |
| EXT-2 | No leaked signals or timers after disable; memory stays within +10 MB per extension over 40 cycles. | ext-test | untested |
| EXT-3 | No warnings or errors from our code in the gnome-shell journal during any suite. | new (journal gate) | FAIL |
| EXT-4 | Animations follow `enable-animations` and Reduced Motion (a fade); power saver keeps them. They only move, scale and fade (nothing re-rendered), and the blur is held still while something moves. They play when on (notes 224415, 194127, 193919). | motion-test, manual | cause found: the VM had no GPU; `vm.sh view` now has one; needs your eye |
| EXT-5 | Every icon-only control has an accessible name and tooltip. | a11y-test | untested |

## 3. Workspaces you save (were "Environments") and Focus

The owner, 2026-11-01 (note 225435): Focus and saved workspaces are two different things. Focus
changes the whole desktop. A saved workspace is one workspace that resumes where you left off.
Environments are renamed **Workspaces**.

| ID | Should do | How checked | Status |
|---|---|---|---|
| SW-1 | Save a workspace: its apps and window places, under a name. | env-test | pass (env-test, 2026-11-01) |
| SW-2 | Opening it makes a new workspace that is automatically **named after it**, and starts its apps in their places. | env-test | pass (env-test, 2026-11-01) |
| SW-3 | Closing it closes its apps and removes its workspace. | env-test | pass (env-test, 2026-11-01) |
| SW-4 | It may also turn on focus with its own apps, a power mode, DND, and its own drawer sites (in memory only; closing brings the normal sites back). | env-test | untested |
| SW-5 | Called "Workspaces" everywhere: Settings, the quick-settings menu, `ostrich` (`env` kept as an alias), docs. Old saved data still opens. | env-test, bats | built (env-test uses `ostrich workspace`) |

## 4. Ostrich Drawer

| ID | Should do | How checked | Status |
|---|---|---|---|
| DRW-1 | An icon per pinned site in the top bar (up to 4), the rest in a ⌄ menu; favicon, unread badge 1–9/9+, dimmed while unloaded, a dot while loaded. | drawer-test | untested |
| DRW-2 | Click drops the site under its icon; click again, Esc or click outside folds it; hover 300 ms opens, leaving for 500 ms folds (unless clicked or typed in). Super+Alt+D toggles. | drawer-test | untested |
| DRW-3 | One size for every site (50 % × 60 %); grips resize and the size holds for all; switching sites never moves or resizes the window. | drawer-test | built |
| DRW-4 | Right-click: load/unload, reload, keep loaded, mute notifications, pin/unpin, remove. | drawer-test | untested |
| DRW-5 | + adds any site by address, or from the recommended list, and says so when it can't; DRM sites can't be added and say why (with "open the app / in browser"). | drawer-test | untested |
| DRW-6 | Logins are kept across restarts (cookies on disk) and separate per site; Google sign-in pop-ups work. | drawer-test --sites, manual | untested |
| DRW-7 | Notifications look like the real app (its name and icon), clicking opens the site, none in DND or focus. | drawer-test | untested |
| DRW-8 | Only keep-alive sites load at login; others unload after N minutes hidden; background tabs pause in power saver; WebKit low-memory cache. | drawer-test | untested |
| DRW-9 | Out of Alt+Tab, the dock and the overview; closing only hides it. | drawer-test | untested |
| DRW-10 | A tab and its top-bar icon show a speaker while the site plays sound, also while the drawer is folded up (notes 225058, 224940). | new | built; VM pending |
| DRW-11 | Opening and folding is animated (slide), per EXT-4 (note 194127). | motion-test, manual | FAIL (194127) |
| DRW-12 | No "internal error" (portal) dialog when a site loads. | drawer-test | untested |

## 5. Ostrich Settings and the first-login tour (`ostrich settings`, `ostrich setup`)

| ID | Should do | How checked | Status |
|---|---|---|---|
| SET-1 | One page per area: Welcome, Theme, Top bar, Dock, Windows, Blur, Notifications, Drawer, Focus/Workspaces, Graphics (hybrid only), Power, Speakers, Touchscreen (only if present), Apps, Finish. Hardware pages hidden when they don't apply. | ui-test | untested |
| SET-2 | Each control changes its setting at once; every setting is either on a page or listed in DEFAULTS "Only in ostrich config". | bats (lib), dconf-test | untested |
| SET-3 | The tour opens at the first login until finished, then removes its autostart; its first page lists what Ostrich added, each with a switch. | e2e | untested |
| SET-4 | One window only: opening Settings again, or a quick-settings button, brings the open window to the right page (note 225220). | new | built; VM pending |
| SET-5 | Page changes cross-fade, following animations on/off (council Should). | manual | untested |
| SET-6 | Search, and a sidebar that scrolls (notes 225306, 225328). | ask (design council) | untested |
| SET-7 | An Accessibility row opens GNOME's accessibility panel. | a11y-test | untested |
| SET-8 | `ostrich settings --step NAME` opens that page. | ui-test | untested |
| SET-9 | Text reads 4.5:1 or better at text scale 1 and 2; works with Tab and Orca. | contrast, a11y-test, hw (Orca) | untested |

## 6. Theme and colour schemes (palette)

| ID | Should do | How checked | Status |
|---|---|---|---|
| THM-1 | Accent colours from the wallpaper (plus GNOME's 9 and presets); applying one writes GTK 3/4 css, Ghostty theme and the extensions' palette, and sets the nearest built-in accent. | cargo, new | untested |
| THM-2 | Text on the accent reads 4.5:1 or better. | cargo | untested |
| THM-3 | Schemes (Classic, Slate Glass, Ubuntu Ember, Night Glass, Graphite, Forest, High contrast, your own) switch glass, text, accent, folders and wallpaper without a logout. | dconf-test, compare | untested |
| THM-4 | An incomplete scheme or a bad colour is refused; text under 4.5:1 is warned about; the editor checks contrast as you change it. | cargo | untested |
| THM-5 | Classic puts back the accent, folders, wallpaper and accent files from before the first scheme. | dconf-test | untested |
| THM-6 | Folder colour follows the accent by default; Ostrich Settings → Theme can pick any Yaru folder colour instead (note 224535). | new (dconf-test, VM icon check) | built (unit tests); VM pending |
| THM-7 | App icons follow the accent when it changes (council Should). | ask | untested |

## 7. Ostrich Store (`ostrich store`, `--gui`)

| ID | Should do | How checked | Status |
|---|---|---|---|
| STO-1 | Searches Flathub and apt together in under 50 ms; origin badges. | store-test, cargo | untested |
| STO-2 | Install, remove, update through flatpak; apt through pkexec. | store-test | untested |
| STO-3 | A GitHub link: Flathub if it matches, else release assets (.flatpak, AppImage, .deb with a typed second confirm, tarball), checksums verified, otherwise "not an installable app repo". Unverified-source warning before every install. | store-test, cargo | untested |
| STO-4 | GitHub installs get a launcher and icon, are recorded, update and remove. | store-test | untested |
| STO-5 | "Start here": LibreOffice, Thunderbird, VLC, Steam, Discord, Simple Scan. | store-test | untested |
| STO-6 | Failures in plain words. | store-test | untested |

## 8. Power, graphics, touchscreen, speakers

| ID | Should do | How checked | Status |
|---|---|---|---|
| PWR-1 | Power saver: boost off, power limit 60 % (not under 15 W), PCIe/USB/Wi-Fi/disk power saving, NVIDIA asleep, animations off, screen dims after 2 min, drawer background tabs paused, monitor 10 s, wallpaper-only blur. Balanced puts every value back. | power-test, hw | untested |
| PWR-2 | Below 20 % battery switches to saver; back on AC. Re-applied at boot. | power-test, hw | untested |
| PWR-3 | Power and touchscreen actions ask no password; a graphics switch asks once. | polkit-test | untested |
| GFX-1 | Integrated / Hybrid / Discrete on NVIDIA hybrid laptops only; Hybrid set once; switching says log out. | hw | hw |
| TCH-1 | Touchscreen tile turns only the touchscreen off/on, kept across reboot and resume. | hw | hw |
| SPK-1 | Presets previewed with real music; A/B tune-by-ear (12 comparisons, instant switch); closing mid-test puts the old tuning back. | manual, hw | untested |
| SPK-2 | Each sound setting can be tested with a play button (note 225653). | ask (design council) | untested |
| SPK-3 | Filter only on the built-in speakers; no resident process; under 0.5 % of a core. | hw | hw |

## 9. `ostrich` command, image, USB drive

| ID | Should do | How checked | Status |
|---|---|---|---|
| CLI-1 | `ostrich help` lists store, theme, speakers, drawer, settings, setup, config, env, update, uninstall, version. | cargo | untested |
| CLI-2 | `ostrich config get/set/export/import` covers every setting; an import can't run code. | dconf-test | untested |
| CLI-3 | Safe without a terminal (no hang when started from a launcher). | bats | untested |
| IMG-1 | The installer image is Ubuntu's own installer; every page the person's choice; first login finishes setup from the image. | image-test | pass (2026-10-31) |
| IMG-2 | `--portable`: the USB drive boots on any PC and adds no boot entry there, also after shim/grub updates. | image-test --portable | pass (2026-10-31) |
| IMG-3 | `image/to-usb.sh` refuses anything but a whole, unmounted USB disk. | bats (image) | pass (2026-10-31) |

## 10. Budgets (DESIGN principle 4)

| ID | Should do | How checked | Status |
|---|---|---|---|
| BUD-1 | Idle gnome-shell CPU, wakeups/s and RSS with Ostrich no worse than the `pre` replica. | measure, baseline | untested |
| BUD-2 | Battery watts no worse than stock; power saver beats stock saver. | hw | hw |

## 11. The rename to Ostrich OS (0.6.0)

Proof is `tests/vm/rename-test.sh` (0.5.0 installed as a user would, state set, upgrade through the
installer, log out and in, one reboot). **That script has not been written or run yet**: the rows
below say what each part has so far.

| ID | Should do | How checked | Status |
|---|---|---|---|
| REN-1 | Upgrading from 0.5.0 keeps a signed-in drawer site signed in (cookies, `-wal`/`-shm` moved with the database), in the same run, with the 0.5.0 drawer running. | rename-test (new); bats: stop, move, hold, skip, sidecars | untested in a VM; logic pass in bats (2026-11-22) |
| REN-2 | A drawer site's notification settings (e.g. off) still apply under the new app id. | rename-test (new); bats: three child cases | untested in a VM; logic pass in bats (2026-11-22) |
| REN-3 | The extensions load under their new UUIDs (ACTIVE, no JS errors, 20 enable/disable cycles); one the user disabled stays disabled. | ext-test (lab overlay); bats | pass (2026-11-22: ext-test on a lab overlay of try-me, all 11, 2 x 20 cycles, RSS growth 0 to 11 MB then at most 10 MB, under the 15 MB limit; disabled-stays-disabled in bats) |
| REN-4 | The dock keeps the drawer icon (`favorite-apps` and `hidden-app-prefixes` follow the id). | rename-test (new); bats | untested in a VM; logic pass in bats (2026-11-22) |
| REN-5 | Old root files (helper, polkit policy, units, udev, modprobe, AppArmor) go at the next boot through `ostrich-os-cleanup-old.service`, which then removes itself; it never touches a path the new install owns. | rename-test (new); bats with a fake root | untested in a VM; logic pass in bats (2026-11-22) |
| REN-6 | No launcher or autostart file names an old slug; every generated `.desktop` id passes the portal's dash rule. | rename-test (new); bats, `tests/appid-lint.sh` | untested in a VM; lint and bats pass (2026-11-22) |

## Manual checklist (a person has to look or listen)

- EXT-4 / DRW-11: animations look smooth on a real GPU (the VM renders in software).
- SPK-1: the A/B test sounds right, no glitch (note 20261023-192734).
- DRW-6: sign in to a Google site once; still signed in after a reboot.
- SET-9: Orca reads every page; everything works with Tab.
- The look of every page against the design guide (Phase D).
