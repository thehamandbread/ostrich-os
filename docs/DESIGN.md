# Design

Source of truth for what this project builds and why. Decisions and their dates are logged in `DECISIONS.md`; the audit of the original machine is in `INVENTORY.md`.

Target: Ubuntu 26.04 LTS, GNOME 50 (Wayland only), amd64. Reference hardware: Dell Precision 5570, Intel Iris Xe + NVIDIA RTX A2000 (Optimus, no MUX).

Project name: **Ostrich OS**. Slug `ostrich-os`, used for the config directory (`~/.config/ostrich-os/`), the state directory and the GNOME extension UUID suffix.

## Goals

A clean, fast GNOME desktop for power users, installed with one command, that:

- keeps live CPU, memory, GPU and temperature readouts;
- has an auto-hiding bottom dock, sized to its icons and coloured to match the theme;
- gives quick access to web apps (messaging, AI chat, mail, video, search) from the top bar with **Ostrich Drawer**, with notifications that look like the real apps;
- has a focus mode that removes everything except the current window;
- offers more theme colours, including colours taken from the wallpaper;
- has a fast app store, in the terminal and as a small GTK app, that can also install an app from a GitHub link;
- gives honest graphics modes (Integrated / Hybrid / Discrete) and power modes that genuinely save power or genuinely perform, tuned by an optional hardware calibration;
- tunes the built-in speakers natively (EQ, per-model correction, mic calibration, and an A/B listening test);
- walks a new user through setup in a GUI wizard after install.

Everything visible to the user is written by this project. Battery life, memory and CPU are the main constraints; functionality is kept.

## Principles

1. **Event-driven, no resident daemons.** Nothing polls unless something visible needs it. All timers stop when the screen is locked or blanked, or when the UI they feed is hidden. Privileged work runs as one-shot helpers.
2. **Battery-aware.** Components read power-profiles-daemon and UPower. On battery, intervals get longer and effects degrade gracefully.
3. **Never wake the dGPU.** NVIDIA stats are read only when `/sys/bus/pci/devices/<dgpu>/power/runtime_status` is `active`. (This logic already exists in the user's `nvidia-power` extension and is carried over.)
4. **A budget for every component, measured.** Idle CPU %, wakeups/s, gnome-shell RSS delta and package watts on battery are measured against a baseline. CPU, memory and wakeups are measured in a VM that replicates the original setup ("pre") and compared with the same VM running this project ("post"). Watts are measured on real hardware booted from an external SSD. A component that misses its budget is not done.
5. **Small, separate extensions.** Each can be turned on or off on its own and makes no network calls. A shared helper library (`_lib`) is vendored into each extension zip at build time.
6. **Safety.** Hardware limits are only ever set at or below vendor maximums. Every privileged action goes through polkit with user confirmation.
7. **Every user-facing feature has a wizard step.** A new feature isn't done until the welcome wizard explains it, shows its shortcut and lets the user choose. Each step can be skipped; steps that don't apply to the hardware are hidden.

## Architecture

| Layer | What | Language | License |
|---|---|---|---|
| Installer | `install.sh`, `lib/`, `modules/` | Bash | MIT |
| Dotfiles | chezmoi source in `home/` | templates | MIT |
| Shell extensions | `modules/gnome/extensions/` | GJS (ESM, GNOME 50 API) | GPL-2.0-or-later |
| Tools | `tools/` cargo workspace | Rust | MIT |

Tools and extensions are installed from pinned GitHub release artifacts verified by SHA256, so end users never need a Rust toolchain.

## GNOME Shell extensions

UUIDs: `<name>@ostrich-os` (e.g. `monitor@ostrich-os`). All extensions share `_lib`: settings helpers, a timer helper that pauses on lock/blank/battery, a power-state reader, and a signal bus that lets focus mode hide other components (`setHidden(bool)`).

| Extension | Replaces | Design |
|---|---|---|
| **monitor** | Vitals, `nvidia-power` | Async Gio reads of `/proc/stat`, `/proc/meminfo`, `/sys/class/hwmon`, `/sys/class/drm` (iGPU frequency/busy), `/sys/class/power_supply` (battery watts). No libgtop. The panel shows compact numbers. The popup shows per-core load, fans and dGPU state. When the dGPU is awake it also shows which apps woke it, with "quit" and "keep off NVIDIA" actions (from `nvidia-power`). It holds the graphics- and power-mode switches and a "Run calibration" button. Interval: 2 s on AC, 5 s on battery, 10 s in power saver. Detail reads only happen while the popup is open. |
| **dock** | ubuntu-dock | Bottom, auto-hide plus intellihide; the width fits its icons. The background is black or white from `color-scheme`, or the palette accent. Built on the shell's `Dash`/`AppFavorites`. Has a per-app "run on dGPU" toggle. No timers while hidden. |
| **drawer** | — | Shell side of Ostrich Drawer. An icon per site in the top bar (favicon, unread badge, grey while unloaded, middle click unloads; the rest in a ⌄ menu), fixed beside quick settings in the order tray apps, +, ⌄, sites; a click or hovering drops that site down under its icon, at its own size; a hotkey toggles it. The extension keeps the window above other windows and out of the dock and Alt+Tab, and talks to `drawer-host` over D-Bus. |
| **focus** | — | Hotkey plus a quick-settings tile. Turns on DND, mutes the drawer, and hides the dock, tray, monitor, workspace bar, drawer and its top-bar icons. Only the focused window and a minimal clock remain. Restores the exact prior state on exit. |
| **workspaces** | space-bar | Workspace bar with smart and per-app names. Imports an existing space-bar name map. |
| **tweaks** | just-perfection | Hides panel elements, sets animation speed, starts on the desktop. Re-runs `palette` when the wallpaper changes. Keeps Yaru's folder icons matched to light or dark. A now-playing pill left of the clock (on by default; only while something plays; MPRIS signals, no timers). Adds quick-settings tiles: speaker tuning (Off / Correction / Custom) and, only when a touchscreen is detected, **Touchscreen on/off**. |
| **tiling** | tiling-assistant | Halves and quarters by keyboard (Super+arrows: from a half, Super+Up/Down gives its quarters; Super+keypad 7/9/1/3) or by dragging to a screen edge or corner, with a preview. After tiling, a popup offers windows (from all workspaces by default) to fill the rest. Windows tiled together raise together, and resizing one moves the shared edge of its neighbours. Optional focus outline in a chosen colour. GNOME's edge tiling and clashing Super+arrow shortcuts are switched off while it's enabled and restored when it's disabled. Nothing runs except during a drag (a 50 ms pointer check, 100 ms on battery, because the window stops at the top bar while the pointer goes on to the edge). The installer copies Tiling Assistant's gap, popup and focus-hint settings once. |
| **tray** | ubuntu-appindicators | StatusNotifierItem host over D-Bus with lazy icon loading. |
| **blur** | blur-my-shell | See below. |
| **holder-monitor** | (user-authored) | Leaves windows on non-primary displays out of Alt+Tab and the window switcher. Does nothing with a single display. |
| **search-new-window** | (user-authored `new-window-on-search`) | Enter on a running app in overview search opens a new window. |

### Cheaper live blur

Live blur is on by default and can be switched off. It covers every surface blur-my-shell covers on the original machine, and each surface has its own **Blur / Solid** switch (solid uses the palette colour):

- top bar
- dock
- shell / overview background, including the app grid
- app folders
- drop-downs and pop-ups: quick settings, the calendar/notification menu, panel menus
- lock screen

It must use clearly less power than blur-my-shell at equal visual settings:

- blur only the actors that need it: the panel, the dock while visible, the overview;
- run the Gaussian on a ¼-resolution downsample, then upscale (about 16× fewer texel operations);
- re-blur only when the content behind changes, not every frame;
- use a cached static blur when only the wallpaper is behind;
- on battery, cap re-blur at about 15 Hz or on damage only; in power saver, use static blur only;
- skip blur entirely for fullscreen windows and hidden actors.

Measured with `intel_gpu_top` and powertop against blur-my-shell.

Spike result (`docs/spikes/blur.md`):
- **How it works:** live blur comes from a clone of `global.window_group` in a clipped, panel-sized container, so panel repaints (clock, monitor, workspace bar) never trigger a re-blur.
- **Cost in the VM:** idle cost equals no blur (0.66 % against 3.42 % for blur-my-shell's live panel blur), and about 2.3× less during animations.
- **Safety rule:** the extensions only add actors to fixed-layout parents, because a crash makes GNOME disable every user extension.

## Tools (Rust)

### drawer-host

**Ostrich Drawer**, a GTK4 + WebKitGTK 6.0 app (`ostrich-drawer`).

- **Services:** defined in `~/.config/ostrich-os/drawer.toml` (name, URL, icon, keep-alive, pinned, shape, saved size, muted, optional user agent). Each service has its own persistent `NetworkSession`, so logins are separate.
- **Any site:** the user can add any web page as a service (a **+** in the drawer or in the wizard). The icon is the site's favicon, saved the first time the page shows one (never shipped). The address/search bar also opens any page without saving it.
- **Recommended sites:** a built-in catalog (`tools/drawer-host/data/recommended.toml`) in four groups — messaging (Google Messages, Google Chat, WhatsApp, Messenger, Discord, Slack, Telegram, Teams), AI (Claude, ChatGPT, Gemini), mail & calendar (Gmail, Google Calendar, Outlook), media & notes (YouTube, YouTube Music, Google Keep, Notion, Todoist, Google Translate). Each is checked in the VM (`tests/vm/drawer-test.sh --sites`). DRM sites (Spotify, Netflix, Disney+, Prime Video) are listed as not yet supported and can't be added.
- **In the top bar:** an icon per pinned site, up to 4 by default (`bar-max`); the rest, and every site, are in the ⌄ menu. Unread badge (1–9, then 9+) from the page title; the icon dims while the site is unloaded and has a dot while it's loaded. Right-click: load/unload, reload, keep loaded in the background, mute its notifications, pin/unpin, remove.
- **Opening:** a click on an icon drops that site down under it (or top centre / top-left / top-right); a click on the open site's icon folds it up; Esc or a click outside hides it. Hovering over an icon for 300 ms opens it too; it folds back up 500 ms after the pointer leaves the drawer and the bar, unless the user clicked or typed in it.
- **Sizes:** one size for every site (50 % × 60 % of the screen below the bar, the settings), so switching sites never resizes or moves the window (owner, 2026-11-19; it stuttered for a second). Grips at the bottom edge and corner (or Super+right-drag) resize it, and that size holds for every site.
- **Pinned apps:** an installed app can be pinned to the drawer (its desktop id in the `pinned-apps` setting; type its name in the +). Its first window opens in the same floating place at the same size, above other windows, on every workspace, out of Alt+Tab and the overview; one thing is out at a time. The icon is grey while the app isn't running, and a middle click quits it.
- **Keys:** Super+Alt+D toggles the drawer; Super+Alt+Tab and Super+Alt+Shift+Tab open the next and previous site; inside it Ctrl+Tab, Ctrl+Shift+Tab and Ctrl+1…9 switch sites like a browser's tabs (all free on GNOME 50 and Ubuntu's defaults).
- **Memory:** each site's menu shows its own web processes plus its share of WebKit's network and GPU processes (PSS), as "about 260 MB" or "1.1 GB"; a site that has no process of its own yet shows nothing, never an average.
- **UI:** no title bar, rounded bottom corners, theme-aware colours. Inside: a row of the sites as tabs with unread badges, plus the address/search bar and **+**.
- **Load / unload tabs by hand:** right-click a tab or its top-bar icon → *Unload* frees its web process (the tab shows greyed out); clicking it loads it again. This sits alongside the automatic rule below.
- **Environments:** each saved environment can have its own top-bar sites and kept-loaded ones; opening it switches the bar (held in memory only, so a restart comes back to the normal sites), closing it brings the normal sites back. Logins are shared.
- **Not supported yet:** DRM video (Spotify web player, Netflix, Disney+), which needs Widevine and isn't in WebKitGTK; and browser extensions. Spotify is tracked as a later task.
- **Notifications look like the real app:**
  - each service gets its own `.desktop` file (`NoDisplay=true`) and icon;
  - web notifications are re-sent through GTK's notification interface (`org.gtk.Notifications.AddNotification`) with the service's own app ID (`ostrich_os.drawer.<service>`), so GNOME shows "Google Chat" with its icon and lists each service separately in Settings → Notifications. (GNOME 50 drops `org.freedesktop.Notifications` calls whose `desktop-entry` hint names another app; see `docs/spikes/drawer.md`);
  - each service's site gets notification permission up front (WebKit's initial notification permissions), because the user chose it, so the site never has to prompt;
  - clicking a notification opens the drawer on that service;
  - suppressed in DND and focus mode.
- **Memory:** each loaded service costs about 50–480 MB. In the spike, four signed-out sites together came to about 1.65 GB PSS, with YouTube and Claude the heaviest. So:
  - only keep-alive services (messaging) stay loaded in the background;
  - other tabs unload after N minutes hidden and reload on open;
  - the WebKit cache model is set to the low-memory profile;
  - in power saver, background tabs are suspended.
- **D-Bus:** GApplication actions on `ostrich_os.drawer`, path `/ostrich_os/drawer` (`org.gtk.Actions`): `toggle`, `show(s)`, `mute(b)`; per site `load`, `unload`, `reload`, `remove`, `add`, `pin(sb)`, `keep(sb)`, `mute-site(sb)`, `set-size((suu))`; `use-set((asas))` for environments; and a read-only `state` action whose value is JSON of the sites and the window, so the extension follows changes through the `Changed` signal without polling. The drawer extension places and animates the window; focus mode calls `mute` (never starting the app).
- **User agent:** WebKit's own user agent works; Messages, Claude and YouTube render normally, so the drawer doesn't fake Chrome's. A site that turns WebKit away can get a `user_agent` in the catalog or drawer.toml.
- **Sign-in:** Google sign-in works inside WebKit (tested with Chat and the first step of Messages).
  - Sign-in buttons open pop-ups, so the drawer gives them a related view (same session, `window.opener` kept) in a small window. When the pop-up reaches the service's own host, it closes and the page loads in the tab.
  - Each service's cookie manager gets explicit SQLite storage (`<service>/data/cookies.sqlite`). Without that, WebKit keeps cookies in memory and every restart signs the user out.

### store-core, store-tui, store-gtk

- **Index:** a local index built from Flathub AppStream (`/var/lib/flatpak/appstream/…/appstream.xml.gz`) and apt DEP-11 metadata (`/var/lib/swcatalog`). Fuzzy search returns in under 50 ms.
- **Actions:** install, remove and update go through the `flatpak` CLI. apt actions go through pkexec. Origin badges show flatpak, apt, snap or github.
- **Install from a GitHub URL:**
  1. If a Flathub entry's AppStream `vcs-browser` URL matches the repo, install from Flathub.
  2. Otherwise use the latest release's assets, in this order of preference:
     - `.flatpak` bundle
     - AppImage
     - `.deb` (with a strong warning, because it runs as root)
     - tarball containing a binary

     Published checksums are verified.
  3. Otherwise report "not an installable app repo".
  - Creates a `.desktop` file and icon, records the source in a manifest, and checks GitHub releases for updates.
  - An unverified-source warning is shown before every install. No building from source in v1.
- **Front ends:** the TUI (ratatui) comes first. The GTK front end comes later on the same core.

### palette

- Extracts accent colours from the wallpaper (k-means in OKLab) and adds GNOME's 9 accents plus an extended preset set.
- Writes:
  - `~/.config/gtk-4.0/gtk.css` (libadwaita `--accent-bg-color` and related variables)
  - `~/.config/gtk-3.0/gtk.css`
  - a Ghostty theme
  - palette JSON for the extensions
- Also sets the nearest built-in `accent-color` for apps that ignore CSS.
- Text on an accent fill reads 4.5:1 or better: white on the accent darkened just enough (`accentStrong`), or black on a light accent.
- **Colour schemes** (`ostrich theme scheme`; owner, 2026-10-31): the glass tints, text and solid colours of the extensions, the accent, Ubuntu's folder colours (Yaru) and the wallpaper, together. Built in: Classic (the colours without a scheme), Slate Glass, Ubuntu Ember, Night Glass (the council's three options), Graphite, Forest and High contrast. Your own live in `~/.config/ostrich-os/schemes/` (same `name = "value"` format as `tools/icons/palette.toml`).
  - Applying one writes each extension's stylesheet from its `stylesheet.css.in` template into `~/.config/ostrich-os/scheme/`; the extension loads it in place of its own and follows changes, so it switches without a logout. Classic puts back the accent, folders, wallpaper and accent files from before the first scheme.
  - A scheme that's incomplete or has a colour that isn't `#rrggbb` / `rgba()` is refused; text under 4.5:1 is warned about.
  - Picked in the wizard's and Ostrich Settings' Theme page (cards), where "New scheme…" opens an editor: accent, glass colour and strength, text colours, solid colour, wallpaper and folder colours, checked for contrast as you change them.
  - The installer doesn't apply one: the user picks in the wizard. Uninstall keeps the schemes you made.

### welcome

A GTK4/libadwaita wizard.

- Autostarts on the first login after install, removes its autostart entry when finished, and can be reopened from the app grid.
- Steps (hardware-specific steps are hidden when they don't apply; any step can be run on its own later):

  | # | Step |
  |---|---|
  | 1 | Welcome and what's installed |
  | 2 | Theme: light/dark, colour scheme (and your own), accent with wallpaper colours |
  | 3 | Top bar: monitor readouts, tweaks |
  | 4 | Dock: icons, auto-hide, "run on dGPU" |
  | 5 | Workspaces and tiling, with their shortcuts |
  | 6 | Blur on/off |
  | 7 | Notifications and DND (banners on by default) |
  | 8 | Ostrich Drawer: hover, top-bar icons, position and sizes, your sites (pin, remove, add), recommended sites |
  | 9 | Focus mode: hotkey and what it hides |
  | 10 | Graphics mode (hybrid laptops only) |
  | 11 | Power modes and auto rules |
  | 12 | Hardware calibration (optional; re-runnable from the monitor popup) |
  | 13 | Speaker tuning: presets, model correction, mic calibration, A/B test |
  | 14 | Touchscreen on/off (only if detected) |
  | 15 | App store, GitHub-link install, recommended apps |
  | 16 | Shortcut cheat sheet, finish |

- **Built (`tools/welcome`, `ostrich-setup [--step NAME]`):** rows are bound straight to each extension's GSettings schema, so changes apply at once. Hardware steps are hidden by sysfs/udev detection. Not yet in it: calibration (until `calibrate` exists) and mic calibration. The speakers step previews each preset with a music clip and runs the A/B test (both versions playing in sync, switched instantly); closing the wizard mid-test puts the previous tuning back. The drawer step lists, adds, pins and removes sites through the running drawer (`--list`, `--recommended`, `--add URL|ID`, `--pin ID`, `--unpin ID`, `--remove ID`); the Focus step's environments each get a checklist of their drawer sites (`ostrich env drawer`). The recommended-apps list (`tools/welcome/data/recommended.toml`) is a draft; nothing is pre-selected.

### system-helper and calibrate

**Touchscreen toggle.**
- The touchscreen is detected by its udev property (`ID_INPUT_TOUCHSCREEN=1`), never by position, so the touchpad and keyboard are never affected.
- `system-helper` unbinds or rebinds that device from its HID driver (`hid-multitouch`) through sysfs. The change is immediate, and the controller can power down while it is off.
- A udev rule persists the choice across reboot and resume.
- The polkit `allow_active` rule covers this action, so the tile doesn't ask for a password each time. The only other promptless action is applying a power mode's hardware settings, so the automatic switch to power saver at low battery never stops at a password dialog; changing the graphics mode asks (one polkit action per helper command, council verdict 2026-10-24).
- It unbinds at the transport level (`i2c_hid_acpi` on the 5570) when that transport serves only the touch controller, so the controller powers down. Otherwise it unbinds at the HID level.
- The spike passed off/on, persist-across-reboot and suspend/resume in the VM (`docs/spikes/touchscreen.md`), so no compositor fallback is needed.

Both are privileged, polkit-gated and one-shot. A boot-time oneshot systemd unit re-applies the saved limits. They are installed only when detection confirms the hardware.

**Graphics modes** (NVIDIA hybrid laptops only). Switching requires a log-out, and the UI says so.

| Mode | Mechanism | Notes |
|---|---|---|
| Integrated | `prime-select intel`, dGPU powered off | Best battery life. |
| Hybrid (default) | `prime-select on-demand`, runtime D3 power management | The desktop renders on the iGPU; the dGPU sits in D3cold when idle. Heavy apps (Blender, Resolve, Steam, games, user-flagged apps) launch on the dGPU automatically via `PrefersNonDefaultGPU`/switcheroo-control. A running app cannot move between GPUs, so routing happens at launch. |
| Discrete | `prime-select nvidia` | No MUX on the 5570, so output still goes through the iGPU. Mainly for GPU-bound sessions. |

**Power modes.** These are layered on power-profiles-daemon, so GNOME's own power menu keeps working. The monitor extension listens for profile changes and calls the helper.

| Mode | CPU | Platform / GPU | Display and devices | Desktop |
|---|---|---|---|---|
| Power saver | EPP `power`, turbo off, RAPL PL1/PL2 lowered | Dell `quiet`/`cool` platform_profile, dGPU forced to D3 | 60 Hz, power-save on Wi-Fi, USB, PCIe ASPM, audio | Static blur, drawer background tabs suspended, monitor at 10 s |
| Balanced | EPP `balance_power`, calibrated sustainable limits (steady clocks instead of boost-then-throttle) | Dell `balanced` | default | normal |
| Performance | EPP `performance`, turbo on, calibrated maximum sustainable PL1/PL2 | Dell `performance`, dGPU kept ready | maximum refresh rate | normal |

Auto rules (configurable): switch to power saver on battery below X %, and to balanced on AC.

**Calibration.**

- Optional in the wizard, and re-runnable any time from the monitor popup. Runs on AC only.
- Applies stepped CPU load (own load generator) and GPU load (a small wgpu compute shader).
- Records RAPL energy, package and GPU temperatures, clocks and `thermal_throttle` counters.
- Finds the highest sustained power with no throttling and a temperature margin.
- Aborts at Tjmax − 10 °C.
- Results are saved per machine. Limits are never set above vendor maximums.

### audio-tune (speaker tuning)

Speakers are tuned natively with PipeWire's own `filter-chain`: builtin biquads, plus a convolver when needed.
- The config lives in `~/.config/pipewire/pipewire.conf.d/`, written by `audio-tune`. There is no EasyEffects and no resident process.
- The filter is a WirePlumber 0.5 *smart filter* on the built-in speaker sink: WirePlumber routes whatever plays to the speakers through it, and the default output, its volume and the sound menu stay the hardware device. HDMI and Bluetooth are other sinks, so they never pass through it.
- Wired headphones on the laptop's jack share the speaker sink (a port switch), so they currently get the EQ too. Bypassing it for the headphone port is still to do; it needs real hardware to test.
- CPU budget: under 0.5 % of one core at 48 kHz.

`audio-tune` (Rust, GTK4) is a standalone app and a step in the welcome wizard. A quick-settings toggle (in the tweaks extension) switches between Off, Correction and Custom. It offers four kinds of tuning:

- **EQ and presets:**
  - a parametric EQ graph with about 10 bands;
  - loudness compensation;
  - a limiter to protect the small drivers;
  - presets: Flat, Voice, Music, Bass, Movie.
- **Laptop speaker correction:**
  - A per-model profile is chosen by DMI product name. Profiles are shipped as data in `modules/audio/profiles/<vendor>/<model>.toml`, starting with the Precision 5570.
  - The tool also checks that every speaker is driven (woofers and tweeters through SOF/UCM), and reports the known fix if not.
  - Unknown models fall back to Flat. Users can contribute profiles.
- **Mic calibration:**
  - Plays log sweeps and records them with a chosen mic. A USB measurement mic is best. The built-in mic gets a warning and a smoothed, conservative result.
  - Fits a correction EQ with boosts capped at about +6 dB.
  - Volume ramps up before each sweep and is capped.
- **Listening test ("which sounds better, A or B?"):**
  - Works like an eye exam: the user flips between two EQ variants of a short clip and picks one.
  - Each round narrows the low, mid and high adjustments (a binary search per band group), with about 10–15 comparisons in total.
  - It can start from Flat, the model correction or the mic result. The result is saved as the "Custom" preset.
  - Test signals are generated at runtime (pink noise, sweeps). Music and voice clips are public domain (CC0 or PD) from Wikimedia Commons, listed with their SHA-256 in `tools/audio-tune/data/clips.tsv`, downloaded at install time, decoded with GStreamer and cut to 20-second excerpts. No third-party audio is committed. Without them the tuner uses pink noise.

## Installer

- `install.sh` (runnable as `wget -qO- <url>/install.sh | bash`; a fresh Ubuntu has `wget` but not `curl` or `git`, so it installs those first) installs the base without prompts:
  - packages, Flatpak + Flathub, extensions, tools, dotfiles;
  - the autostart entry for the wizard.
- Choices are made in the welcome wizard after the next login. whiptail is only a fallback when there is no GUI session.
- Every module is idempotent, supports `--dry-run`, backs up before overwriting, and logs what it changed.
- **Modules:**
  - `core`: apt basics, Flatpak + Flathub, optional snapd removal (Flatpak/apt first).
  - `terminal`: Ghostty, pinned fonts downloaded from upstream.
  - `gnome`: gsettings, extensions, palette, the welcome autostart entry. Notification banners default to on (`show-banners=true`); only DND and focus mode suppress them.
  - `audio`: PipeWire filter-chain config and the speaker profile for the detected model.
  - `dev`, `apps`: package lists with the duplicates from INVENTORY removed. The wizard sets the defaults.
  - `claude-code`: native install only.
  - `hardware/nvidia-optimus`, `hardware/dell`, `hardware/power`, `hardware/touchscreen`: detection-gated; install `system-helper` and its polkit policy (shared `lib/helper.sh`).
    - `nvidia-optimus`: nvidia-prime and switcheroo-control; runtime D3 if the driver has it off; Hybrid set once on the first run (later runs keep the user's choice). The NVIDIA driver itself is left to `sudo ubuntu-drivers install`, which the module suggests if it isn't loaded.
    - `power`: the boot unit `ostrich-os-power.service` (after power-profiles-daemon, on graphical.target) re-applies the current mode's knobs; the monitor extension applies them on every mode change through pkexec.
    - `dell`: nothing to install; Dell thermal modes are the platform_profile that power-profiles-daemon already drives.
- **Dotfiles:** chezmoi, templated by hardware and by a user name/email prompt: `.bashrc`, Ghostty, gitconfig, mise, the drawer and palette configs.

## Roadmap

0. Design (this document), decision log, project name.
0b. VM test harness (`tests/vm/`), the replica of the original setup, and the "pre" baseline. Built first; every later phase is tested here.
1. Risk spikes (throwaway):
   - drawer-host loading web apps with notifications attributed to the service;
   - positioning the drawer window from an extension on Wayland;
   - a downsampled blur measured against blur-my-shell;
   - the touchscreen unbind/rebind across suspend and resume.
2. Installer foundation: `lib/` helpers with bats tests, core/terminal/dev/apps modules, snap choice, chezmoi dotfiles, Docker smoke test.
3. Extension tooling: build/pack script, `_lib` vendoring, ESLint, CI packing. Port holder-monitor and search-new-window.
4. monitor
5. dock
6. tweaks, workspaces, tray
7. palette
7b. audio-tune and the audio module
8. blur
9. drawer (host and extension)
10. store: core and TUI, then GitHub-URL install, then GTK front end
11. focus
12. tiling
13. Hardware and power: graphics modes, power modes, calibrate
14. welcome wizard and the recommended-apps list
15. Release: CI-built artifacts with checksums, end-to-end `curl | bash` test in a VM, repo made public after a gitleaks audit

## Testing

**The developer's live machine is never modified.** The project is only applied to it if the user explicitly opts in after it has passed both the VM and external-SSD testing. All testing happens in one of two places.

### 1. VM (`tests/vm/`, scripted QEMU/KVM)

- `vm.sh` covers:
  - fetching the Ubuntu 26.04 ISO (checksum and signature verified);
  - an unattended install;
  - start/stop, SSH (a VM-only key) and snapshots.
- Images live in `~/.local/share/ostrich-os/vm/` or in `VM_DIR`, never in the repo.
- Snapshots:
  - `stock`: fresh Ubuntu.
  - `pre`: stock plus a replica of the original setup from INVENTORY, made by `replicate-current.sh` (portable parts only, no personal data).
  - `post`: stock plus this project, saved per phase.
- `measure.sh` runs inside the VM. After 2 minutes idle it measures a 5-minute window, three times, and reports the median of:
  - gnome-shell %CPU, RSS and PSS
  - wakeups/s
  - used memory
  - process and service count
  - snap mounts
  - boot time
- Results go to `docs/BASELINE.md`.
- **What the VM can't measure:** watts and battery life, NVIDIA/PRIME, Dell thermals, RAPL calibration, the touchscreen, real speakers, and real GPU blur cost. VM numbers are for relative pre-vs-post comparison only.

### 2. Real hardware: external USB SSD

- Once the VM build works, Ubuntu plus this project is installed onto an external USB SSD, from inside the VM with the SSD passed through as a raw disk. The bootloader therefore lives only on the SSD.
- Boot it with the firmware's one-time boot menu; unplug it to go back.
- This tests watts and battery life, graphics and power modes, calibration, speaker tuning and the touchscreen.

### Per-layer checks

- **Installer:** shellcheck, shfmt, bats, and a Docker smoke test in `ubuntu:26.04` (dry run, then two real runs to prove idempotency). A full install is tested in the VM.
- **Extensions:**
  - no errors in the gnome-shell journal in the VM;
  - enable/disable cycles leak no signals or timers;
  - each is measured against its budget.
- **Rust:** `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`.
- **Power (SSD):** idle and load watts, 10-minute sustained clocks and throttle counters, per mode:
  - power saver must beat stock `power-saver` watts;
  - performance must beat stock `performance` sustained clocks.
- **Calibration:** the abort path is tested with a simulated temperature, and unit tests check that limits never exceed vendor maximums.

## Open questions

- Spotify and other DRM sites in the drawer: needs a Widevine-capable path (later task).

- Default drawer services: the starters are Google Messages, Google Chat, Claude and YouTube (none logged in, no personal data).
- The curated recommended-apps list.
