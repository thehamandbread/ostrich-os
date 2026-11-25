# Decisions

## 2026-10-19 — Licensing

- Repository: MIT.
- Exception: modules/gnome/extensions/ (user-authored GNOME Shell extensions) is GPL-2.0-or-later, with its own LICENSE file, because extensions run in and call GNOME Shell (GPL-2.0-or-later).
- Third-party assets (wallpapers, fonts, icon/GTK themes) are never committed; the installer downloads them from upstream at install time, pinned to versions.

## 2026-10-20 — Overall design (see DESIGN.md)

- Rewrite everything: every third-party GNOME extension is replaced by our own (monitor, dock, drawer, focus, workspaces, tweaks, tiling, tray, blur). The user-authored holder-monitor and new-window-on-search are kept and ported; nvidia-power is folded into monitor.
- Standalone tools are written in Rust (`tools/` cargo workspace). Extensions are GJS.
- Store: terminal TUI first, then a GTK4 front end on the same core. It can install an app from a pasted GitHub URL (Flathub match, then release assets; no build from source in v1).
- Snap: Flatpak and apt come first. Removing snapd is offered as a choice.
- Web-app drawer drops down from the top. Its notifications are attributed to each service's own `.desktop` entry, so they show as the real app, and they respect DND and focus mode.
- Focus mode: DND on, drawer muted, dock/tray/monitor/workspaces/drawer hidden; only the focused window and a clock remain.
- Blur: live by default, can be turned off, and must use measurably less power than blur-my-shell (downsampled, damage-driven, static on power saver).
- Monitor: compact panel readouts plus a detail popup; never wakes the dGPU.
- Setup UI: `install.sh` installs without prompts, then a GTK4 welcome wizard runs on the next login. whiptail is only a no-GUI fallback. This supersedes the whiptail default in CLAUDE.md.
- Graphics modes Integrated / Hybrid (default) / Discrete. Power modes are layered on power-profiles-daemon with real CPU, platform, GPU, display and desktop changes.
- Hardware calibration is optional in the wizard and can be re-run any time from the monitor popup. Limits are never set above vendor maximums.

## 2026-10-20 — Name, notifications, speaker tuning

- Project name: Ostrich Ubuntu. The slug `ostrich-ubuntu` is used for config/state directories and GNOME extension UUIDs (`<name>@ostrich-ubuntu`).
- Notification banners are on by default (`show-banners=true`). Banners being off on the original machine was not intentional. Only DND and focus mode suppress banners.
- Speaker tuning is added as a new component: PipeWire filter-chain only (no EasyEffects, no resident process), applied to built-in speakers only. `audio-tune` provides EQ and presets, per-model laptop speaker correction, mic calibration, and an A/B listening test.

## 2026-10-20 — Touchscreen toggle, wizard coverage

- A quick-settings tile turns the touchscreen on or off, shown only when a touchscreen is detected. It works by unbinding the device from its HID driver through the privileged helper (renamed from `power-helper` to `system-helper`), and the choice persists across reboots.
- Rule: every user-facing feature gets a welcome-wizard step. A feature isn't done until it has one.

## 2026-10-20 — Testing location

- The developer's live machine is never modified by this project. It is only applied there if the user explicitly opts in after both VM and SSD validation.
- All testing, including the pre/post baselines, runs in a scripted QEMU/KVM VM (`tests/vm/`). The "pre" state is a replica of the original setup.
- Hardware-only features are tested on an external USB SSD installed from inside the VM, so the internal disk is never touched.

## 2026-10-20 — Drawer scope

- The drawer hosts any web page the user adds, not a fixed list. Its position is configurable (top-centre default, or the top-left or top-right corner).
- Tabs can be loaded and unloaded by hand to save memory, as well as by the automatic idle rule.
- DRM sites (Spotify web player, Netflix) aren't supported yet because WebKitGTK has no Widevine. Spotify support is a later task.

## 2026-10-20 — Blur coverage

- Live blur covers the top bar, dock, shell/overview, app folders, drop-downs and pop-ups, and the lock screen. Each one can be set to Blur or Solid. (The spike measured the top bar only, to compare like for like.)

## 2026-10-20 — Main build choices (made while building; open to change)

- **Drawer:** a click on another window hides it (setting `hide-on-focus-loss`, on by default). The app autostarts hidden at login, so messaging services can notify. Focus mode mutes and minimises it and restores both afterwards.
- **Tiling:** while enabled it switches off GNOME's edge tiling and the Super+arrow shortcuts that clash, and restores the exact previous values when disabled. Window gap defaults to 0, like Tiling Assistant; the installer copies the user's Tiling Assistant settings once.
- **Lock screen blur:** the blur extension stays loaded on the lock screen only to style its background, and removes every live backdrop while locked, so window content can't show through the top bar.
- **App-folder blur:** a background blur that runs only while a folder is open (its cost is limited to that time).
- **NVIDIA:** the installer doesn't install the NVIDIA driver; it suggests `sudo ubuntu-drivers install` when the driver isn't loaded. Hybrid is set once on the first run; later runs keep the user's choice.
- **Power modes:** the monitor extension applies the system helper's knobs on every power-mode change (from any menu) through pkexec; a boot unit re-applies them at startup. No resident daemon.
- **Tools distribution:** release tarball pinned to `VERSION`, checked against its SHA256SUMS; a checkout with a local build uses that instead.
- **Recommended apps:** the wizard's list is a draft (`tools/welcome/data/recommended.toml`); nothing is pre-selected. Still the user's call.
- **Speaker A/B test:** clips are pink noise rendered with the same biquads PipeWire runs, played with `pw-play` straight to the speakers, so switching A/B is instant and PipeWire doesn't restart mid-test.

## 2026-10-20 — Renamed to Ostrich Ubuntu; one `ostrich` command; installer image

- **Name:** the project is now **Ostrich Ubuntu** (formerly "The Cleanest Ubuntu Setup"): a clean, sturdy desktop anyone can use. The slug is `ostrich-ubuntu` (directories, extension UUIDs `<name>@ostrich-ubuntu`, schemas, app ids, system files); the GitHub repo is `thehamandbread/ostrich-ubuntu`, still private. The installer switches off extensions under the old `@cleanest-ubuntu-setup` UUIDs.
- **One command:** `ostrich store | theme | speakers | drawer | setup | update | help | version`. Only `ostrich` is on the PATH; the programs behind it live in `~/.local/libexec/ostrich-ubuntu/`. The root-only system helper is never a user command.
- **The one-line install uses wget:** a fresh Ubuntu 26.04 desktop has `wget` but neither `curl` nor `git`, so the documented command is `wget -qO- …/install.sh | bash`, and `install.sh` installs git and curl first (one password prompt). When piped in, it reads keys from the terminal, not from the pipe. Found by testing the literal command in the VM against a local stand-in for GitHub (`tests/vm/e2e.sh --pipe`).
- **Installer image:** `image/build-iso.sh` adds the repo and a release to Ubuntu's own ISO, plus an `autoinstall.yaml` whose `interactive-sections: ['*']` leaves every installer page, including the disk choice, to the person. At the first login a terminal runs the same installer from the image and asks for the password once (the installer needs sudo, which a silent service can't ask for).
- **Recommended apps:** the drafted list is kept as is.

## 2026-10-21 — Renamed again: Ubuntu Ostrich

- The project is now **Ubuntu Ostrich**, all the way down: slug `ubuntu-ostrich` (directories, extension UUIDs `<name>@ubuntu-ostrich`, schemas, app ids, system files, the image file name) and the repo `thehamandbread/ubuntu-ostrich` (still private; GitHub redirects the old names).
- Unchanged: the `ostrich` command and the `ostrich-*` programs behind it.
- The installer switches off our extensions under both earlier UUID suffixes (`@cleanest-ubuntu-setup`, `@ostrich-ubuntu`).
- **Open: shutting down during start-up.** In the VM, powering off within a few seconds of logging in, while a full install is still starting (11 extensions plus the drawer's web pages, on a software-rendered VM), sometimes keeps GNOME Shell from exiting. systemd then kills it after 5 s and GNOME switches every extension off as if one had crashed. Measured: plain Ubuntu 0/8, full install off ~6 s after a cold login ~25-60%, off 30 s after login 0/10. The shell was stuck in GNOME's own shutdown step (main.js, waiting for its screen-time history write), but switching screen-time history off didn't help (6/10), and neither did giving the shell 30 s to exit (it stayed stuck); the exact blocker is still unknown. The installer switches replaced extensions off before enabling ours; the e2e test waits 45 s before re-login. To check on real hardware: log in, shut down at once, log in again, and see whether the extensions are still on (if not: `gsettings set org.gnome.shell disable-user-extensions false`).

## 2026-10-22 — Undo, Keep/Clean, battery, focus allow-lists and environments

- **Restore point and `ostrich uninstall`:** the first install saves all user settings (`dconf dump /`), the extensions folder, the files it replaces and the package list; the helpers record every file created. `ostrich uninstall` reverses everything, including system files and the graphics mode; apps installed through the store stay. A full disk image wasn't possible on the developer's machine (95 % full), and isn't needed for what the installer changes.
- **Keep or Clean:** asked only when other user extensions exist. Keep (default) switches off only what Ubuntu Ostrich replaces; Clean switches off every other user extension and resets its settings (`dconf reset` of the paths its schemas declare, never wider). Nothing is deleted.
- **Battery:** power saver adds a lower CPU power limit (60 % of default, never below 15 W, never above the default), USB autosuspend (never input or audio devices), Wi-Fi power save, SATA link power saving, NVIDIA runtime PM, NMI watchdog off and slower dirty-page writeback; originals are kept in /run and restored in the other modes. On the desktop: animations off and a 2-minute dim, put back afterwards (saved, so a crash can't leave them changed). The drawer pauses non-keep-alive tabs. Low battery (≤ 20 %, configurable) switches to power saver and plugging in returns to the previous mode; unplugging alone changes nothing. Performance is full speed on battery too. Not done: 60 Hz in power saver (needs real hardware to test safely).
- **Focus with an allow-list:** uses GNOME's own app filter (the parental-controls `shouldShowApp` that the app grid and search already consult), so the grid and search hide non-allowed apps without patching their code; non-allowed windows are minimised and kept minimised.
- **Environments:** saved per workspace, opened on a fresh workspace; windows are matched to their apps and put back in their saved places as they appear (for at most 60 s). Extras: focus with the environment's own allow-list, a power mode, Do Not Disturb. Driven from the Focus menu and `ostrich env` (D-Bus org.ubuntuostrich.Environments).
- **Ostrich Drawer:** the web-app drawer is now called Ostrich Drawer (internal ids unchanged). Each pinned site gets its own top-bar icon (favicon, unread badge, loaded dot) rather than one drawer icon; at most 4 by default, the rest in a ⌄ menu. A click or a 300 ms hover drops the site down under its icon; a drawer opened by hovering folds up 500 ms after the pointer leaves it and the bar, but never once the user has clicked or typed in it. Sizes are per site: chat sites narrow (420 px × 75 %), others wide (the old 50 % × 60 % settings), and a resize is remembered for that site. Recommended sites: messaging, AI, mail & calendar, media & notes, each checked in WebKitGTK in the VM; DRM sites listed as unsupported. The extension follows the app through a read-only `state` action (D-Bus Changed signals); the only timers are the hover delay and, while a hover-opened drawer is shown, a 200 ms pointer check.
- **Drawer sites per environment:** an environment can save its own top-bar sites and kept-loaded ones; opening it switches the bar, closing it switches back. The set is held in memory by the drawer, so a restart or crash always returns to the normal sites. Logins stay shared across environments.
- **Uninstall stops our running apps first** (the drawer with its web pages, Ostrich Settings, the store), matching only programs under `~/.local/libexec/ubuntu-ostrich/`. Left running after their files were gone, they made the shutdown hang (above) likelier right after an uninstall: one round trip in the VM came back with GNOME's extensions switched off; with the apps stopped, two in a row came back exact.

## 2026-10-23 — Polish pass: parity with the originals

- **The bar:** every rewrite matches the look of the extension it replaces and every feature the user used, then the most-used features, then something better (docs/PARITY.md, checked side by side with `tests/vm/compare.sh`). The user's own dock, blur and Space Bar settings aren't copied over; the defaults are modelled on them instead.
- **Blur, found by measuring:** the backdrops cloned the whole window group, and GNOME 50 doesn't draw such a clone into Shell.BlurEffect's buffer, so every surface was only see-through. Each backdrop now mirrors what's behind it with real actors (the wallpaper through GNOME's BackgroundManager, as the lock screen does, and a clone of each window), blurred over a margin around the surface so its edges mix real content. `tests/vm/blur-test.sh` puts a checkerboard behind the bar and checks its contrast is gone. BACKGROUND-mode blur also works but can't keep the dock's and menus' rounded corners.
- **Dock:** the theme's grey square behind every icon is removed (only hover and press fill). Dots per window, click to minimize or cycle, scroll, window previews, Unity launcher badges and progress. Icon refreshes come from two shell-wide signals: per-icon signals on the apps kept 25 MB alive over 20 enable/disable cycles.
- **Workspace bar:** Space Bar's features (reorder by drag, drop windows, menu, show-empty, current-only, shortcuts) plus app icons per workspace. Shortcuts are Super+Alt+N/R/Page Up/Page Down; Super+Shift+Page Up/Down is GNOME's own move-window.
- **Ostrich Drawer:** no bar in the drawer (the top-bar icons switch sites and hold the menus, so switching never resizes); closing only hides it (hide on close, the app held); it's left out of the overview (GNOME's overview filter only checks skip_taskbar, which a Wayland app can't set); Esc and Ctrl+W fold it up with the animation.
- **Speaker tuning:** real music instead of noise: four public-domain recordings (Bach piano, a Bizet aria, Grieg's orchestra, a LibriVox reading) from Wikimedia Commons, pinned by SHA-256. Previews render in the wizard with the same biquads PipeWire runs; the A/B pair plays in sync and switches instantly.
- **Wizard:** rows are plain text (libadwaita parses row titles as markup, and a bare `&` blanked "Mail & calendar"); the first page's check marks are real switches; choices show which is on and say what happened.

## 2026-10-23 — Critiques, round 1

- **Ostrich Settings:** the setup tour became a settings app: a sidebar of every page (What's included, Theme, Top bar, Dock, Workspaces, Blur, Notifications, Drawer, Focus, Graphics, Power, Speakers, Touchscreen, Apps). The first login still runs it as the tour, with Back / Next / Skip the tour; after that it opens straight to the sidebar. `ostrich settings` opens it (`ostrich setup` stays), `--tour` runs the tour again, `--step NAME` opens one page.
- **Monitor popup, rebuilt on Vitals' layout:** a section per kind of reading with an icon and its headline value; open one for a row per value, each with a star that pins it to the top bar. Pins are row ids in `panel-items`, in order, replacing the four fixed show-* switches (the default pins are what those showed). With the popup shut, a tick reads only what the pins need; free space is read once a minute. The processor, memory, temperature, fan, voltage and system icons are drawn for this (the themes have none); the rest are the theme's.
- **The dock's memory growth was the blur's:** switched off and on, the dock grew gnome-shell by about 1 MB a time, and only with the blur running. Bisected in the VM (GNOME's bare Dash: flat; our dock without the blur: flat): each dock appearance gets a new backdrop, and its rounded mask compiled its own shader per instance, kept until GJS collected it. The mask's shader is now the class's (compiled once) and a backdrop drops its effects before its actors. After: 7 MB then 3 MB over two rounds of 20 cycles (was 20 then 26). ext-test now judges memory on the second of two rounds, since the first settles caches.
- **Glass without a shadow:** St draws a box-shadow under the whole surface, so through translucent glass it darkened what shows through (ours kept 70% of the brightness behind a menu, Blur my Shell 93%, measured over the same photo). Menus and banners keep a thin light edge instead.

## 2026-10-24 — The design council

- **A council decides what's next, the owner approves.** Twelve advocates argue in three rounds (opening, rebuttal after a fact check, closing after disputed claims are tested in the VM; what the VM can't settle can only enter the plan as an experiment), then a judge rules against a written rubric (reach, impact, battery and resource cost, upkeep, effort, evidence) and writes a tiered plan (`docs/council/PROTOCOL.md`, `/council`). Seats speak for people (a newcomer, everyday use, power users, accessibility, laptops, low-end hardware, the owner) and for the craft (design, simplicity, quality, security, upkeep), using six personas (`docs/council/PERSONAS.md`); the user's own values (battery, looks, aesthetic, control, ease of use, streamlineness, polish) each live in one or more seats. A researcher checks facts between rounds. Advocates run on Sonnet, the judge on Opus; every seat is read-only. Panels (`design`, `system`) seat six for narrow questions.
- **Arguments come from evidence.** `tests/vm/evidence.sh` builds a pack from the test VM: idle cost of the original setup vs ours, gnome-shell CPU under load, side-by-side screenshots in light, dark and over a photo, every Settings page, the store, the journal's warnings and the owner's critique notes, listed in `index.md`. A claim without evidence counts as opinion.


## 2026-10-24 — The council's first verdict (round 2 and the whole OS)

Full text: `docs/council/2026-10-24-round-2-and-whole-os.md`. The owner asked for the plan to be built without questions, so each open question takes the judge's default (listed there).
- **Today panel:** GNOME's Events card is hidden (a `show-events` switch brings it back); our "This computer" card becomes the panel's main item. No process list and no new data source: it reads only cached properties.
- **Icons:** one scheme for our apps (rounded glass square, one glyph each: bag for the Store, sliders for Settings so it isn't mistaken for GNOME's gear, a drop-down panel for the Drawer), made from a template and palette by a headless script in `tools/icons/`. Inkscape stays optional.
- **Drawer at login:** only keep-alive sites load (DESIGN.md already said so; all four starters were loading, about 520 MB). Others load on first open. The + says what went wrong and accepts only http(s).
- **Root helper:** split by action. Changing the graphics mode asks for a password; power apply and the touchscreen stay promptless so the 20 % switch to power saver never prompts on a low battery.
- **App Center stays** in the app grid (the store can't update snaps); Ostrich Store has the dock and Flatpak links.
- **Blur on battery** stays live by default; static blur on battery is an experiment for the Dell, decided by measured watts.
- **Rejected:** a process list in Today, hiding App Center, merging the small extensions, a hard memory gate in CI.
- **Built from the verdict (notes):**
  - The judge read test T1 as all four starter sites loading at login. The drawer's state in that same run shows only the two kept-loaded ones (Messages and Chat) loaded; WebKit runs several processes per site. So login loading already followed DESIGN.md, and drawer-test now checks it stays that way.
  - Two monitor labels failed contrast because GNOME marks any menu item that can't be activated as insensitive, and the theme greys its text (removing `popup-inactive-menu-item` didn't help). The power row and the footer are now plain boxes; the "Every 2 s" line is gone (the refresh button's accessible name says it). `tests/vm/contrast.sh` measures text lines in a screenshot.
  - The dock going INACTIVE after many cycles (and later the drawer) was the test VM's screen locking: a long ext-test run passes the 5-minute idle lock, and GNOME switches off every extension that doesn't run on the lock screen. ext-test now keeps the screen awake (as measure.sh does) and reports whether the screen was locked when a state is wrong. An earlier guess, toggling too fast, was wrong; each toggle now waits for its state anyway.
  - Camera, microphone and screen requests in the drawer were silently denied (WebKit's default), so calls couldn't work; each request now asks, naming the site, with "Don't allow" first. A tab in a call isn't unloaded for being idle.
  - Touchscreen `off --persist` stays promptless (the quick-settings tile uses it), against the verdict's suggestion of a password for it: DESIGN.md exempts the touchscreen.
  - `static-blur-on-battery` (experiment X1) exists, off; it is decided on the Dell by measured watts.
- **Settings from the terminal and in the dotfiles (S11, after X3 passed):** `ostrich config` lists, gets, sets (through gsettings, so values are checked against the schema), resets, diffs, exports and imports our settings, and switches an extension off or on over SSH. A key holding a command (`drawer/host-command`) is never exported, imported or set from there. The dotfiles carry `~/.config/ubuntu-ostrich/settings.dconf`, empty by default, and a chezmoi `run_onchange_` script applies it when it changes, with the same rules; nobody's settings ship in the repo. DEFAULTS.md lists the few settings with no control in Ostrich Settings, and a test keeps every setting accounted for. The DESIGN.md promise of "mise, the drawer and palette configs" in the dotfiles is still only partly met (the drawer's sites live in its own config file, not yet in chezmoi).
- **Keyboard (X4, part):** every key binding from GNOME and our extensions in try-me, compared: no two active bindings share a shortcut. The only duplicates (Super+1–9) are Space Bar's defaults, and Keep mode switches Space Bar off. The Tab walk with visible focus still needs a look on real hardware, with Orca (X5).

## 2026-10-24 — Critiques, round 3, and a council that explores

- **The top bar flicker** (solid black ↔ glass): the bar's blur backdrop wasn't laid out when it was made, so it wasn't drawn and Yaru's black bar showed until something else relaid the UI; each rebuild repeated it. The backdrop and its scene now ask for a layout when they change. The bar also skips windows by their app id as GTK 4 on Wayland reports it, and never mirrors an invisible window.
- **The drawer in the dock** (a gear icon, easy to close by mistake): GNOME couldn't tie the drawer's window to an app, so it got a placeholder. It now has a hidden `ubuntu-ostrich.drawer.desktop` (our icon), and the dock hides apps by their windows' app id as well.
- **Smaller:** removing a drawer site asks in a small dialog instead of a submenu; scrolling anywhere on the top bar switches workspaces (a touchpad too; the wheel's smooth copy isn't counted twice); the clock menu is one fixed size (688 × 468); the drawer's bottom corners are rounded; "Open the monitor ›" is in the text colour (an accent like slate was too dim).
- **The xdg-desktop-portal crash dialog** is Ubuntu's: WebKit's sandboxed web process asks the Realtime portal to raise a thread using its PID inside the sandbox, and xdg-desktop-portal 1.21.1 crashes in that error path (`g_propagate_error: assertion 'src != NULL'`). Opening a drawer site sets it off; the portal restarts by itself. WebKit has no switch for it short of turning its sandbox off, which we won't. To report upstream.
- **The council explores** (second edition): seats get the web and two lab VMs (`tests/vm/lab.sh`: throwaway overlays on a copy of try-me, silent, 5 GB each, never the main disk) and a round 0 to research from their own point of view; a curator merges what they found into `inspiration.md`; when the owner is to choose (the colour scheme), the judge shortlists 2–3 complete options instead of one. A `PreToolUse` hook (`.claude/hooks/council-bash.py`) limits seats' Bash to the lab and single read-only commands. No seats that imitate another OS: inspiration, not copying.

## 2026-10-24 — The council's second verdict (motion, now playing, Spotify, colour)

Full text: `docs/council/2026-10-24-motion-now-playing-spotify-colour.md` (the first run with round 0 exploration and lab VMs). The owner approved the plan; open questions are asked as each part is reached.
- **Defects first.** The VM tests found that the drawer registers empty "Stopped" media players at login (GNOME's clock menu shows a dead "ostrich-drawer" card), that the clock menu's right column overflows its 688 × 468 box (fully outside at 200 % text), that a drawer page can navigate the drawer to another site with no notice, that any page in a drawer view is granted notifications, and that two text lines are under 4.5:1 (inactive workspace numerals 3.73, "No Notifications" 4.47). These are fixed before anything new.
- **Clock menu:** stays 688 × 468; the right column scrolls when it doesn't fit (always above text scale 1.25). Plain labels ("System monitor", "Running for 1 minute"). Every private GNOME field the clock menu uses goes through one guard (the dock's don't yet: readiness council N1).
- **Motion:** one helper (`_lib/motion.js`) with 120 / 170 / 200 ms, position and opacity only, through `ease()` so `enable-animations`, power saver and `animation-speed` apply (checked: 20/20 clean cycles with animations off). Reduced motion turns slides into fades (read from gsettings until Shell 51). No per-duration keys: `animation-speed` is the one knob. The close-then-open race didn't reproduce (0/40) but the helper guards it anyway, and `motion-test.sh` gates it.
- **Now playing:** GNOME's own card stays. The owner's pill is built in `tweaks` (no new extension), shows only while something plays, opens its own drop-down (not the overflowing clock menu), uses MPRIS signals with no timers, never fetches art, and is one switch, off by default until an idle measurement (E1) passes. GNOME's card with a player present measured no idle cost.
- **Spotify and DRM sites:** a plain message with "Get the Spotify app" (Spotify's verified snap first) and "Open in browser", the button the first verdict promised and nobody built. **Widevine: no, for now (owner).**
- **Drawer safety:** navigation away from a service's site opens in the browser; notification permission goes only to the service's own site (as DESIGN.md already says); the data folder is private; drawer icons get names.
- **Colour:** one token file (`tools/icons/palette.toml`) drives the stylesheets, icons, accent, icon theme and wallpaper. Three complete schemes (A Slate Glass, B Ubuntu Ember, C Night Glass) are built as VM previews before the owner picks one.
- **Boot time:** the +99 % against the original is `snapd.seeded.service` (+4.8 s), not our units.
- **The portal crash dialog:** still Ubuntu's (see round 3 above). If no safe workaround turns up, it stays a known issue, reported upstream (owner question 8).
- **Rejected:** a Chromium view for DRM sites, depending on the third-party "Media Controls" extension, the calendar grid back by default, animating blur, a hard memory cap per site.
- `tests/vm/mock-mpris.py` is a mock media player for tests (no timers).
- **Built (M4, clean first login):** no fix for the portal crash exists in Ubuntu's archive (1.21.1+ds-1ubuntu3.1) or upstream that we could find, and WebKit can't skip the realtime request without dropping its sandbox, so it stays a known Ubuntu issue; a report is drafted for the owner to file (debate folder, `portal-crash-report-draft.md`). The critique extension was never in user builds: only `tests/vm/vm.sh` puts it into VM snapshots (the seat saw it in try-me).
- **Built (M5, the drawer honest and safe):** DRM sites (Spotify, Netflix, Disney+, Prime Video) open in their own app (Spotify's snap, else its Flatpak, else App Center's page) or the browser, from the wizard, the + menu and `ostrich-drawer --elsewhere ID`. A page that doesn't load says so, with Try again and Open in browser. Leaving the site opens the browser instead: checked at the main frame's response, where the address is final (load-changed's Started still has the old one, which let a script-driven move through), with a short list of sign-in hosts allowed; "same site" is the last two labels (three under `co.uk`-style suffixes), not the Public Suffix List. Notifications are allowed only while the page is on the service's site. The data folder is 0700, and removing a site deletes its cookies and storage, so it signs you out. Drawer icons say what they are.
- **Built (M6, one colour file and three schemes):** `tools/icons/palette.toml` fills the app icons and every extension stylesheet with a colour (`stylesheet.css.in`, filled by `build.sh`). No `_lib/tokens.js`: the two colours that were in JavaScript (the bar's tint, the lock screen's solid colour) became stylesheet classes, and the dock's tint stays a setting. The lock screen without blur uses the neutral `solid` colour, not the accent. The palette tool gives text on an accent 4.5:1 (white on the accent darkened just enough, black on a light one) and writes `accentStrong`. The three options are complete files in `tools/icons/schemes/`; Option A's wallpaper is drawn as SVG from its colours (no download, a few hundred bytes); B and C use Ubuntu's own backgrounds, checked present on 26.04, and a missing one leaves the wallpaper alone instead of installing a package. Previews (all six pass 4.5:1 on the top bar, clock menu and monitor): the clock menu's weekday (3.9:1 today) and, on light glass, its date (2.1:1) were dimmed by the theme and now get the full text colour, like "No Notifications"; Option A's light wallpaper starts deep slate at the top, because the bar stays dark glass with white text and pale mist under it read 1.4:1. Not measured yet: E3's brightness behind the glass, and the memory delta of each wallpaper.

- **All schemes, the user's choice (owner, 2026-10-31):** instead of one default, every scheme ships, with Classic (today's look), Graphite, Forest and High contrast added, and an editor in Ostrich Settings for your own. Switching is live: the extensions load a scheme stylesheet in place of their own (`_lib/scheme.js`; St ranks a later-loaded stylesheet below an earlier one, so loading it on top lost, seen in the VM: the bar didn't change). `ostrich theme scheme` does the work for the wizard, Settings and the terminal, so the installer's one-time scheme step and the bash wallpaper script went (one implementation). Classic undoes a scheme (settings and accent files saved before the first one). Not done: app icons in a scheme's colours (the installer's copies would overwrite them), and folder colours don't follow a later light/dark switch unless Ubuntu does that itself.


## 2026-10-30 — Audit fixes (ponytail audit of the whole repo)

- **Installer and uninstall:** the Store is pinned to the dock once (taking it out sticks); `--keep-new-settings` takes it out again, putting App Center back only if it was there; a dry run with git or curl missing says what to install instead of failing; an extension zip older than its source is rebuilt. Unused hardware helpers in `lib/detect.sh` are gone.
- **Extensions:** blur rebuilds when monitors change; keep-off's undo survives a second apply; the dock has one size-changed connection; the D-Bus proxy and palette helpers are shared in `_lib`; NVIDIA counts as on only when `active`.
- **Store and GitHub apps:** a checksum that can't be fetched is an error, not "unverified"; checksums match by file name; updates unpack or copy next to the old version and swap only on success; an unverified `.deb` asks twice. GitHub apps can now be updated (the same checked flow, which says when one is up to date) and removed, from the window and `ostrich store` (Ctrl+D on its link). Removal deletes the app's own folder and launcher, found from the repo name rather than from paths in the manifest, and removes a Flatpak or `.deb` through its package manager by the id recorded at install (apps installed before this can't be, and say so). Cached screenshots not used for 30 days are deleted when the Store window starts.
- **Drawer:** plain `http://` is allowed only for `localhost` itself (not `localhost.evil.com` or `localhost@evil.com`); notification permissions are set by one handler instead of one more per added site.
- **Not changed:** `lib/prompts.sh` stays (it's the whiptail fallback DESIGN.md describes).

## 2026-10-31 — The readiness council: install on the owner's Dell?

Full text: `docs/council/2026-10-31-ready-to-install-on-the-dell.md` (all twelve seats, rounds 0 to 3,
33 requested tests, 19 run in the VM). Verdict: **conditional go**, the first hardware run on the
external SSD unless the owner waives that rule.
- **Must, built:** the installer stops before any change on a partial or stale tools build (a source
  hash, `.tools-stamp`, written by `build-tools.sh`); 0.1.5. Uninstall copies drawer sites, saved
  desktops and the settings export into the kept restore point; root removes only our own system
  paths; a failed settings dump stops the install, and without dconf at install uninstall never
  resets every setting; keep-new mode undoes a scheme that is still on. Classic keeps the user's own
  gtk.css lines. Blur goes solid under GNOME's own High contrast (banners were 1.71:1). Docs say what
  carries over and name the setting that returns each old choice; `docs/INSTALLING.md`.
- **Rulings:** install from a checkout with `BUILD_DIR` pointing at the tested build (build-tools.sh
  alone never reached the installer). Keep-alive for Messages and Chat follows RAM (on from 12 GB),
  with a Settings switch. No preinstalled player: VLC in "Start here" (a Flathub app becomes the
  default by itself; `-ugly` codecs aren't needed). Power saver keeps a screen set to never blank.
  GNOME Settings stays in the grid (Users, Printers and Accessibility have no other route). The pill
  stays, off, until the Dell battery test (E1). Banners stay on by default.
- **Not now:** dock private-field guards and a private-API ledger, the drawer's NavigationAction
  policy and the GitHub-dialog wording, blur strengths under "Advanced", folding small extensions.

## 2026-10-31 — The "internal error" at a first drawer site was ours, and is fixed

The portal crash was not Ubuntu's Realtime bug, as rounds 3 and M4 above said. A backtrace (Ubuntu
debuginfod) puts it in xdg-desktop-portal's `authorize_callback` (`xdp-context.c:238`) with no app
and no error: WebKit writes the app's id into its sandbox's `/.flatpak-info`, the portal accepts a
dash only in an id's last part, and its Flatpak lookup turned `ubuntu-ostrich.drawer` down without
an error, which the next line dereferenced (upstream #2123 is the same NULL error; fixed only on
its main branch). Every portal call from a drawer page crashed the portal. The drawer's id is now
`ubuntu_ostrich.drawer` (its D-Bus path is the same); old launchers go on install. No apport
setting was needed. Reporting the portal's missing error upstream is optional (owner).

## 2026-10-31 — A portable install on a USB drive

To try Ubuntu Ostrich on a friend's laptop without touching it, and keep the work, the system is
installed onto a USB drive (as DESIGN.md → Testing planned for the external SSD), not run live:
a live session keeps nothing. `image/to-usb.sh` runs the image's installer in QEMU with the drive
as its only disk, so the developer's own disks can't be picked. Ubuntu puts shim at
`\EFI\BOOT\BOOTX64.EFI` with `fbx64.efi`, which writes an "ubuntu" boot entry into the NVRAM of any
PC the drive boots on; `build-iso.sh --portable` removes fbx64 and puts grub beside shim
(`image/portable-esp.sh`, re-run by an apt hook after shim/grub updates). `image-test.sh --portable`
boots the installed disk twice with empty firmware settings and checks no entry was added.

## 2026-11-01 — Animations: the VM never showed them; power saver keeps them

The owner saw no animations in the review VM (note 224415). GNOME Shell inhibits every animation
when rendering isn't hardware accelerated (`main.js`, `is_rendering_hardware_accelerated()`), and
the VM rendered with llvmpipe. `vm.sh view` now starts the VM with virgl (GPU) graphics, which GNOME
counts as accelerated; `VM_DISPLAY=std` for a host without GL. Separately, the owner chose to keep
animations on in power saver: ours only move, scale and fade what is already drawn, so the saver no
longer sets `enable-animations` false (it still dims the screen sooner).

## 2026-11-02 — One motion template: Spring

The owner wants things to come out of where they belong, cheaply. Three styles were shown on a demo
page (Liquid, Spring, Morph; https://claude.ai/artifact/P8r9zQzgTfiR7ZU5XPwQbz) and the owner
picked **Spring**: a small copy (20 %) at the middle of the source grows out and springs just past
full size before settling, 280 ms, ease-out-back; going back takes 140 ms, speeding up, into the
source. It lives in one place, `_lib/motion.js` (`popOut`, `retreat`), and the pop-out alerts, the
now-playing pill (out of the clock) and the dock previews (out of their icon) use it. While a
surface moves it is drawn once into a texture (offscreen redirect) and only moved, scaled and faded;
nothing is redrawn mid-motion. Power saver keeps it; Reduced Motion turns it into a fade.

## 2026-11-05 — The design council: the Ostrich look on top of GNOME

Full text: `docs/council/2026-11-05-the-ostrich-look.md` (design panel: newcomer, access, owner,
design, simplicity, maintainer; rounds 0 to 3, 32 claims fact-checked, 12 tests in the VM on
try-me-0.1.7 with this checkout's extensions; page: https://claude.ai/artifact/S4zjbPC5DFDjYjQyAYf9pQ).
The owner approved the plan; the verdict's seven questions are asked as each part is reached.

- **The look stays:** GNOME 50's tokens, the glass, one accent action per view, amber as a fixed brand
  colour on the app icons (it can't follow the wallpaper-picked accent: icons are exported files).
- **Monitor size:** no drag handle (GNOME's popup has no resize; a drag needs an alternative, WCAG
  2.5.7). One key, `section-rows` (default 6): an open section scrolls inside that height. Ostrich
  Settings offers Compact (6) and Tall (12); Open System Monitor is the "more" view.
- **Monitor width:** one fixed width in em; long values end in "…" instead of widening (the menu moved
  +32 px with a busy network and +55 px with Processor open, sliding sideways).
- **Power row** stays in the monitor; its checked segment must read at 4.5:1 and every segment gets a
  2 px foreground focus ring (the accent ring was invisible on the accent fill).
- **Saver:** the popup keeps the last values and says they are a last reading (they are frozen, but
  looked live beside the bar's dashes).
- **Names:** every icon-only control gets a visible label on hover and keyboard focus (there were no
  tooltips anywhere); drawer icons show it on focus, and on hover only when hover-to-open is off.
- **Clock menu:** the owner's fixed size, set in em, so it grows only when text is enlarged (it
  truncated at 200 %).
- **Alert card** keeps its fixed dark colours (measured 4.9:1 or better) as a documented exception.
- **Look rules fail in CI:** token-lint covers plain CSS, `dim-label` and `:focus` rules.
- **Experiments only:** a glass edge (kept at ≥ 93 % brightness and the owner's yes), "Power Saver" as
  the segment label. **Rejected:** three size layouts, cutting Vitals features, dropping the Workspaces tile.
- Clerk fixes found during the run: `compare.sh` without `--dark` now sets the light style (the
  evidence pack's "light" shots had been dark), and `lab.sh base SNAPSHOT` picks the lab's snapshot.

## 2026-11-09 — The owner's answers to the look council, and the 0.1.8 review

- **Power row: removed** from the monitor popup (council question 4; note 20261109-173822).
  GNOME's Power Mode tile switches modes. The monitor still applies our extra power settings on
  every change, whoever makes it, and the low-battery alert still offers to keep the mode.
- **Settings pages:** stay 13 (one per part); search comes first (question 5).
- **First screen:** a tour page that names the dock's bottom edge, the app grid, the clock and
  quick settings; no visible launcher (question 6).
- **Boot and memory** (+151 % / +24 % in the VM): measured on the owner's PC after the full install,
  where first-boot work doesn't skew the numbers (question 7).
- **Workspace scrolling:** one scroll movement moves one workspace, wheel or touchpad. GNOME 50
  blocks for 150 ms after a step; we block until scrolling has been quiet for 150 ms, because a
  touchpad swipe outlasts the 150 ms and moved from 1 to 5 (note 20261109-174537).
- **Quick settings redesign** goes to the council (notes 20261109-173903, -174440): fewer clicks,
  and what moves into the clock menu (media, sound and mic, Bluetooth, Focus, Do Not Disturb).
- **Monitor in power saver:** the top bar's readings fold away (fade and squeeze to the left) and a
  power-saver icon takes their place; they unfold when saver ends (note 20261109-173834). This
  replaces the dashes that held the readings' places (2026-11-01).
- **Top-right hot corner** opens quick settings, built like GNOME's own corner (same pressure, not in
  fullscreen); a switch in Settings, on by default (note 20261109-174704).
- **Hover to open** the clock menu and the now-playing orb, like the drawer's icons (rest 0.5 s,
  closes 0.5 s after the pointer leaves unless clicked inside); a switch, on by default (note
  20261109-174754).
- **Sharing (Track B):** not every piece is published alone. First the owner lives on Ostrich, then
  the repo goes public with the one-command install. After that only blur, workspaces and later
  monitor go to extensions.gnome.org, each with its own settings window and a pointer to Ostrich.
  The dock, tiling and tray clash with Ubuntu's own extensions; the drawer and the store need their
  apps; the rest mean little outside Ostrich. Each published piece costs a review at every GNOME
  release. One repo.

## 2026-11-10 — Quick settings and the clock menu (council 2026-11-09, full panel)

Verdict: `docs/council/2026-11-09-quick-settings-and-the-clock-menu.md`.

- **Power mode in one click:** on machines with three power profiles, GNOME's Power Mode tile takes
  open, arrow, item (tested with power-profiles-daemon's fake driver), and its body only toggles
  Balanced and the last-used mode. There, a full-width Power Saver | Balanced | Performance row
  replaces it. Machines with two profiles keep GNOME's tile, which is already one click.
- **Hiding a GNOME tile:** one guarded helper (`hideStockTile`) that leaves the stock tile on any
  failure and restores it on disable; used for `_powerProfiles` only. A `quick-settings-style`
  setting (`ostrich` or `stock`) puts GNOME's quick settings back.
- **Text on lit tiles reaches 4.5:1:** white on the accent measured 3.3–4.2:1 over a photo in light,
  dark and saver. Lit tiles use the accent darkened just enough (`accentStrong`). This reverses
  the 2026-11-05 ruling 9 ("no fill or class changes").
- **Clock menu:** Do Not Disturb and Focus switches below the date, on the same settings as their
  tiles (which stay), with a switch to hide them. The card keeps its fixed size; new rows scroll.
- **Quick settings stays stock** (owner): the top row, battery, sound, mic and GNOME's tiles are
  unchanged. Bluetooth recent devices come later, as tiles below GNOME's Bluetooth tile, once a
  mock Bluetooth service lets them be tested. GNOME's Bluetooth tile is never hidden.
- **Media:** GNOME's card stays at the top of the clock menu and gets restyled; our own card only if
  the restyle isn't good enough (owner's call).
- **Sound and mic** stay in quick settings; GNOME's widgets are never moved into our menus.
- **A menu opened by hover, the corner or a key never acts on a row:** tested for GNOME's rows; every
  new row gets the same test.
- **The orb** stays on by default. Measured 2026-11-10 in the VM (gnome-shell CPU, 60 s x 3, median): pill off 0.20 %, on with nothing playing 0.17 %, playing 0.15 %, paused 0.20 %. The council's bar was 0.3 points; it passes. Real-battery numbers still wait for your PC (E1 on the Dell).
- **Rejected:** a cycling power tile (GNOME's isn't one), hiding GNOME's Do Not Disturb tile, moving
  sound or mic into the clock menu, folding the system buttons into the power menu, a 44 px rule,
  a per-item layout engine (not now).
- Note 20261101-224331 is closed: it was the monitor popup's power row, removed on 2026-11-09.
- **Monitor popup, default content** (look council 2026-11-05 Should, owner chose "pinned strip + 4 open" on 2026-11-12): the popup starts with a strip of the pinned values, then Processor, Memory, Network and Battery (or Storage) open side by side, the rest folded, System reading "Up 12 min". GNOME's menus are accordions (opening a section closes the one before: `PopupSubMenuMenuItem._subMenuOpenStateChanged` tells the top menu's `_setOpenedSubMenu`), so the monitor clears the top menu's private `_openedSubMenu` after each section opens (GNOME 50, `popupMenu.js`; check it on a new GNOME: if renamed, sections go back to one at a time). The strip's rows are made once and shown or hidden, never destroyed: destroying them while one had focus (an idle 0 % reading drops out with hide-zeros) made GNOME touch a disposed object (the journal gate caught it). Open: the popup is about 790 px tall with four sections open, untested on a 768 px screen. 2026-11-14: what you leave open or folded is remembered (`monitor/sections-open`, owner: things stay as they were after a login). 
- **Audits #11 and #12 (2026-11-14).** #11, the monitor's rules while the screen is locked: nothing to change. The monitor declares no lock-screen session mode, so GNOME turns it off while locked (seen in the VM: ACTIVE, locked INACTIVE, unlocked ACTIVE; `power-test.sh` checks it) and its low-battery rule is evaluated at every start (`_checkBattery()` after the battery proxy is up), so at unlock. #12, audio-tune's target: `speaker_sink` falls back to the default output only when it is the machine's own sound card (`system::is_builtin`: an `alsa_output.` node that is not HDMI, USB or Bluetooth); otherwise the CLI asks for `--target`, so a preset can no longer be applied to a Bluetooth headset by accident.
- **Standalone extensions: blur, workspaces, monitor (Track B prep, 2026-11-14).** Each has its own `prefs.js` (a small shared helper, `_lib/prefs.js`) and a README, and the internal tags (owner, council and note references, a demo-page link) are out of their code and of the `_lib` files they ship. The monitor's "Monitor settings" button opens its own preferences window when Ostrich Settings is not installed, and its low-battery alert says "the monitor switched to power saver". `tests/vm/standalone-test.sh` installs each alone on `stock` (ACTIVE, no JS error, 40 cycles, steady-state memory, journal gate, the preferences window opens). Found on the way: blur alone on stock fails `ext-test`'s second-round memory limit (42 then 16 MB in 0.3.0 as well), but over five rounds it grows +23, +0, +2, +2, +1 MB, so it is warm-up and not a leak; the standalone test widens the first rounds and judges the steady state. Not done: each zip still carries all of `_lib` (some of it unused by that extension), which should be trimmed before submitting to extensions.gnome.org; the extensions.gnome.org account and the uuid namespace are the owner's.

## 2026-11-18 — First live install on the owner's Dell: fix round

The owner installed 0.4.0 on their own machine and listed what felt wrong in the first minutes.
Their calls, which replace earlier ones:

- **Super** opens and closes the overview, as stock GNOME. The "second Super shows the app grid"
  patch and its setting are gone; GNOME's own quick double press still reaches the grid.
- **Top-right corner** behaves exactly like GNOME's top-left hot corner: a second push closes quick
  settings, the ripple plays, it works in the overview, and a fullscreen window on that monitor
  blocks it.
- **Hover-to-open** is removed from the clock and the now-playing orb (both open on a click). The
  drawer keeps its hover. Supersedes the 2026-11-09 "rest the pointer to open the clock and the orb".
- **Every expandable section starts closed, always**: the monitor popup no longer opens four sections
  or remembers what was left open. Supersedes 2026-11-12 "pinned strip + 4 open" and the 2026-11-14
  memory.
- **Top bar order:** drawer icons, then tray (app) icons, then quick settings. Both used to claim the
  start of the right box, so they swapped as apps started.
- **One dock:** ours stays in the overview; GNOME's dash there (64 px icons on solid grey) is hidden.
  While in the overview the dock's blur shows the wallpaper only, as the windows aren't there.
- **Glass everywhere:** the cards the theme paints solid grey on top of glass (clock-menu notifications
  and buttons, quick settings' submenus, overview search results, the monitor's footer buttons and
  open section headers) take the glass tint; still solid when blur is off.

## 2026-11-19 (drawer round)

- **One drawer size, no move on a switch:** the owner saw a second of stutter and a resize each time they changed sites. Every site opens at the same size (the settings' percents, or the size the user dragged it to, kept in the `size` setting), and switching sites while it is open does not move or resize the window. Per-site narrow/wide shapes and per-site saved sizes are gone from the shell side (the host still reads them from drawer.toml and ignores them).
- **Order in the top bar:** tray apps, +, drawer sites, pinned apps, quick settings. The group sits fixed against quick settings and the tray puts new icons to its left, so a new background app moves nothing but the tray.
- **Unloaded sites are grey, middle click unloads:** the white "loaded" dot is gone; an unloaded icon is desaturated (like a browser's unloaded tab).
- **Memory per site:** the host assigns each WebKit web process to the site that committed a page when it appeared (WebKitGTK doesn't say which process runs which view), adds an equal share of the network and GPU processes, and shows that. The old figure was the total divided by the number of loaded sites, so every site said the same ("538 MB").
- **Pinned apps** share the drawer's floating window (`appslot.js`): the app's own first window, adopted and placed under its icon.
- **The monitor doesn't warn about Ostrich's own apps** (the drawer, Store, Settings), by cgroup id.
- **Dock:** running apps with no window (tray-only apps) get no dock icon: they widened the dock and moved it.
- **Keys:** Super+Alt+Tab / Super+Alt+Shift+Tab (next/previous site), Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+1…9 inside the drawer.

## 2026-11-20

- **Show Apps button:** from the app grid a second press hides the overview (back to the window you were in); after Super (window picker) it goes to the app grid; a press mid-animation is ignored. GNOME's own dash button could not be pressed with the overview closed, so it only ever went grid → window picker.
- **Saved workspaces remember what was inside the apps (format 2):** per window an optional `open` (web pages and local folders) and `cwd`; a version 1 file is still read. Files folders come from Files' own `OpenWindowsWithLocations`; terminal folders from `/proc/<shell>/cwd` under the terminal's process (matched to windows by title, else in order); Firefox-family pages from the browser's session file. **Why not copy the session file itself (the owner's first idea):** a running browser rewrites it every ~15 s, it holds every window (so workspace B would bring back workspace A's pages), and a browser reads it only at start with "restore previous session" on. So the file is read at Save time, only the page addresses of each window are kept (`focus/mozlz4.js`, `appstate.js`), and they are reopened with `--new-window A --new-tab B` (Firefox) which works whether or not the browser is running. The workspace file is the trust boundary: only `http(s)` and `file:///` addresses (40 a window, 200 a workspace) and absolute folders without `..` survive `validate()`.
- **Ubuntu Ostrich updates through the Store (0.5.0):** the Store compares its own version with GitHub's latest release (plain `vX.Y.Z` tags only) and lists "Ubuntu Ostrich" in Updates and the daily notification; Update opens a terminal running `REPO_REF=<tag> ostrich update`, which needs the password anyway and shows what it does. `install.sh --update` now fetches the latest release tag instead of `main` (the tools and zips are published per release, so main can be ahead of them). A checkout install is not updated this way (`ostrich update` says to use git); the one-line install creates the managed copy that is.
- **Chrome and other Chromium browsers are not included:** their session files are in a private binary format that could not be checked against a real browser in this round; a window of such a browser reopens blank, as before.

## 2026-11-21 — Proposed: Ostrich OS, browser picker, crash agent, tour redesign

- Proposed (pending plans review): rename to Ostrich OS. `ostrich-os` for paths, UUIDs and schemas; `ostrich_os` for app and D-Bus ids (the portal's dash rule). Migration keeps drawer logins and per-site notification settings.
- Proposed: a browser/profile picker as a Rust GTK tool. Drawer sites are targets; a shared same-site function keeps drawer ↔ picker loop-free; the drawer passes an activation token.
- Proposed: crash → agent diagnosis. Read-only, redacted local report, consent first; contribution only as a user-reviewed draft.
- Proposed: the tour/Settings redesign goes through the council (newcomer-led), not a new skill. ostrich-design and the council already exist.

## 2026-11-22 — Owner decisions on the plans

- Hover delay: 500 ms (the code). Docs change in build step 2.
- The rename ships alone as 0.6.0.
- User-facing copy: American English, applied when step 8 moves copy into tools/welcome/data/copy.toml.
- Keep the name Ostrich OS. No public ISO until Canonical's IP policy on modified images is checked; a USPTO class 9 search before announcing.
- Council session approval is deferred to build step 8.
- Agents: keep gemini as a data file; add a local-model agent (opencode with Ollama) so diagnosis works without a paid plan.

## 2026-11-22 — Renamed: Ostrich OS

- Name Ostrich OS; repo thehamandbread/ostrich-os. `ostrich-os` for paths, extension UUIDs and schemas; `ostrich_os` for app, .desktop and D-Bus ids (the portal's dash rule, 2026-10-31), which also fixes the store and setup ids. The CLI stays `ostrich`.
- Install order: stop our apps (graceful), migrate, install new .desktop files, migrate notification children, remove old launchers and autostart, enable new UUIDs. Cookies are never moved under a running drawer, and a cross-filesystem copy is checksummed before the old copy is deleted.
- Supersedes "never SIGKILL / never stop a 0.5.0 drawer": apps get app.quit if they have it, else SIGTERM; data moves only when fuser shows no process (including WebKit's network process) holding a file under it. SQLite with its -wal/-shm moved together is consistent after a terminated process. SIGKILL is never used.
- Old root files go at the next boot through the one-shot ostrich-os-cleanup-old.service, not "on a later run".

## 2026-11-25 — Owner's fix round (photos from the Dell)

- The top-right hot corner is removed (supersedes 2026-11-09): quick settings opens on a click only. The `quick-settings-corner` key and its wizard row are gone.
- Glass: the theme's drop shadow is removed from glass surfaces (drawn outside the blur, it read as a smudge round a frosted border). Glass that sits on other glass (clock-menu notifications, the Clear button, quick-settings submenus, search results) gets a visible hairline, new scheme colours `glass_edge` / `light_glass_edge`; a scheme of the user's own without them takes Classic's.
- A colour scheme's stylesheets are rewritten from the new templates on every install (`ostrich theme scheme refresh`): they replace the extensions' own, so a scheme applied before an update hid every newer rule (the owner's clock-menu notifications stayed grey).
- A pinned drawer app's window skips GNOME's minimize animation (it flew across the screen when put away).
- Waking from suspend: only critical kernel messages go to the text console (`kernel.printk = 3 4 1 3`, /etc/sysctl.d/60-ostrich-os-console.conf); the rest stay in the journal. On the Dell the kernel wakes in about 0.2 s every time; the wait is after the fingerprint is accepted (25–30 s before the desktop returns, every fingerprint unlock this week), which is not solved yet.
- Moving off GNOME to a lighter desktop: parked, the owner's call later.
