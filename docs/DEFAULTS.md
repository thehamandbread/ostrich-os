# Ubuntu Ostrich: what's on by default

Ubuntu Ostrich is opinionated: it makes the choices below for you, so a fresh install is ready to use. Every one of them can be changed in **Ostrich Settings** (in the app grid, or `ostrich settings`), and most in GNOME Settings too. Nothing here is permanent, and nothing you already had is deleted. Replaced extensions are switched off, not uninstalled, and changed files are backed up first (`~/.local/state/ubuntu-ostrich/backups/`).

## Desktop

| Area | Default |
|---|---|
| Top bar | System monitor: CPU, memory, temperature and GPU. It updates every 2 s on AC and 5 s on battery; in power saver it stops and shows a dash, and it stops while the screen is locked. The workspace bar is on the left. |
| Dock | Floating at the bottom, sized to its icons, 40 px icons, frosted. It hides only when a window is in the way; push the pointer against the bottom edge to bring it back. A dot per open window; click an app that's in front to minimize it (or go to its next window), scroll over it to go through its windows, hover for previews of its windows. Unread counts and progress from apps that send them, and a speaker on an app that's playing sound (click it to pause). |
| Blur | The top bar always blurs the wallpaper (steady, and computed once). The dock, menus and pop-ups blur what's behind them, live; the overview, app grid and app folders blur the wallpaper; the lock screen too. Each one can be switched to solid. In power saver the dock blurs only the wallpaper, and menus, the overview and folders turn solid black. |
| Notifications | Banners on. Do Not Disturb and focus mode hide them (they still collect in the list). |
| Focus mode | Super+Alt+F or the top-right menu. Turns on Do Not Disturb, and hides the drawer and its icons, the dock, tray, system monitor and workspace bar. Optionally only the apps you choose stay (the others are minimised and gone from the app grid and search). Everything comes back when you turn it off. |
| Saved workspaces | Save a workspace (its apps, window places, and what was open inside them) and open it again with one click: it comes back on its own workspace, named after it, e.g. Video editing or School. Closing it saves where you left off, closes its apps and removes the workspace. A saved workspace can also turn on focus with its own apps, a power mode and Do Not Disturb. **What comes back inside the apps:** the folder each Files window showed, the folder each terminal was in (Ghostty, Ptyxis, GNOME Terminal and others; with several terminals open and titles that don't name their folder this is partly a guess), and the pages open in each Firefox, Zen, LibreWolf, Waterfox or Floorp window (read from the browser's own session file, which the browser writes about every 15 seconds, so a page opened in the last few seconds can be missing). Not running programs, splits, scrollback, Chrome's pages, or the history inside a tab. Pages are stored as plain text in `~/.config/ubuntu-ostrich/environments/`. Switch it off in Ostrich Settings. Top-right menu → Focus, Ostrich Settings, or `ostrich workspace`. Focus itself is separate: it quiets the whole desktop. |
| Ostrich Drawer | An icon per site in the top bar (up to 4; the rest in a ⌄ menu), with unread badges, fixed beside quick settings in the order tray apps, +, sites, pinned apps. An icon is grey while its site isn't loaded, like an unloaded browser tab; a middle click unloads a loaded site. Click an icon, or rest the pointer on it for half a second, and the site drops down under it; click it again, press Esc or click outside to fold it up. Every site opens at one size (50 % × 60 %, or what you dragged it to with the bottom edge), and switching sites never moves or resizes the window. Super+Alt+D toggles it, Super+Alt+Tab (Shift: back) opens the next site, and inside it Ctrl+Tab, Ctrl+Shift+Tab and Ctrl+1…9 switch like a browser's tabs. Pins an app too (type its name in the +, or choose one that is running): it opens in the same small floating window, kept out of Alt+Tab and the overview; its icon is grey while the app isn't running, and a middle click quits it. Text fields underline misspelled words. Each site's menu says what it costs, measured per site. It starts hidden at login: sites kept loaded (the messaging ones) load then, so they can notify; the others load the first time you open them, and right-click → keep loaded changes which is which. The + adds a site by address or from the recommended list, and says so when it can't. Starter sites: Google Messages, Google Chat, Claude, YouTube; about 20 recommended ones to add, or any site. Each saved workspace can have its own sites. |
| Tiling | Super+←/→ for halves, then Super+↑/↓ for quarters (Super+keypad 7/9/1/3 also gives quarters). Dragging a window to a screen edge or corner tiles it. After a tile, it offers windows for the rest of the screen. Tiled windows raise together. No gap; focus outline off. |
| Workspaces | Bold pills at the top left, named after their apps. Click to switch (the current one opens the overview), scroll to move, drag to reorder, drop a window from the overview onto one to move it; right-click to rename, add, move or remove. Super+Alt+N new, Super+Alt+R rename, Super+Alt+Page Up/Down move. |
| Tray icons | Shown in the top bar (StatusNotifier apps such as Discord or Nextcloud). |
| Replaced | Ubuntu Dock, Ubuntu AppIndicators and Tiling Assistant are switched off, plus Vitals, Blur my Shell, Space Bar and Just Perfection if you had them. Their settings carry over where ours has the same setting: Space Bar's workspace names; Just Perfection's animation speed and start-in-overview; Tiling Assistant's keys, gap and pop-up; how Dash to Dock hides, its icon size and its own colour and opacity; Vitals' top-bar readings, their place and how often they update; Blur my Shell's strength and brightness per surface (see [Your old settings](#your-old-settings)). |
| Left as they are | Light/dark mode, accent colour, wallpaper, workspace count and speaker tuning, until you choose in the tour. |

## System

| Area | Default |
|---|---|
| Apps | Flatpak with Flathub. `ostrich store` searches everything; paste a GitHub link to install a project (an AppImage is unpacked into your home folder; an Electron app asks for your password once, for the AppArmor rule its sandbox needs). Once a day the Store looks for updates to both, and a notification opens its Updates tab. **Ubuntu Ostrich itself** shows there too when a newer release is published on GitHub ("New release v0.5.0"); its Update button opens a terminal that runs `ostrich update` for that release and asks for your password. `ostrich update` follows the latest release, not the `main` branch. A copy installed from a git checkout (not the one-line install) is updated with git instead. |
| Terminal | Ghostty, set as the default terminal. |
| Shell | A small `~/.bashrc` addition (your own `.bashrc` is kept). Dotfiles are managed by chezmoi. |
| Graphics (NVIDIA laptops) | Hybrid: the desktop runs on the integrated GPU and the NVIDIA GPU sleeps until an app needs it. Set once; your later choice sticks. The NVIDIA driver itself comes from `sudo ubuntu-drivers install`. |
| Power modes | GNOME's power menu (on a laptop with all three modes, one Saver / Balanced / Performance row in quick settings instead of the Power Mode tile: Settings > Top bar > Quick settings > GNOME's own puts the tile back), plus more. **Power saver:** CPU boost off, CPU power limit lowered to 60 % (never under 15 W, so the web stays smooth), deepest PCIe power saving, USB autosuspend (not keyboards, mice or audio), Wi-Fi and disk link power saving, the NVIDIA GPU sleeps, the screen dims after 2 minutes, the drawer's background tabs pause, the system monitor stops reading (its top-bar readings fold away to a power-saver icon and, on battery, the time left; only memory is still watched), the top bar and dock keep a blur of the wallpaper and menus, the overview and folders turn solid black. **Balanced:** the machine's own defaults. **Performance:** full speed, on battery too (some laptops' firmware still limits power on battery). Below 20 % battery it switches to power saver by itself and goes back when you plug in. Re-applied at every boot. |
| Clock menu | Do Not Disturb and Focus switches under the date (the quick-settings tiles stay), On or Off in text. Settings > Top bar turns them off. |
| Touchscreen | An on/off tile in the top-right menu, only if the machine has a touchscreen. |
| Setup tour | Opens at your first login until you finish it. Its first page lists everything Ubuntu Ostrich added, each with a switch. |
| Blur | Frosted glass behind the top bar, dock, menus, overview and app folders, each on or off with its own strength. In power saver only the wallpaper is blurred. |
| Super key | Once: your windows. Again: all your apps. |
| Accent colour | Picked from the wallpaper, and picked again when the wallpaper changes (unless you chose one yourself). |
| Folder colour | Ubuntu's folder icons take the accent colour when it changes (or the colour scheme's), or one colour you pick in Ostrich Settings > Theme. A non-Yaru icon theme is left alone. |
| Speaker tuning | Presets to preview with real music (public-domain recordings downloaded at install) and Use; or tune by ear: twelve A/B comparisons with the music playing, switching instantly. |

## Your old settings

Where a default differs from what you may have had, this is the one setting that brings yours back:

| You had | Ostrich's default | To get yours back |
|---|---|---|
| Notification banners off | On | Ostrich Settings > Notifications > Show banners |
| A dock that hides your way (Dash to Dock) | Carried over | Ostrich Settings > Dock: "Hide when not in use", "Only hide when a window is in the way" |
| Your dock's icon size | Carried over | Ostrich Settings > Dock > Icon size |
| A coloured dock background | Carried over | Ostrich Settings > Dock > Colour |
| Vitals' readings in the top bar | Carried over (the ones the monitor also has) | Ostrich Settings > Top bar, or the star on a row in the monitor's popup |
| Blur my Shell's strength and brightness | Carried over | Ostrich Settings > Blur |
| Screen never blanks | Kept, also in power saver | — |
| Messages sites always loaded | Kept loaded | Right-click a drawer icon > "Keep loaded in the background" |

## Undo

The first install takes a restore point: all your settings, your extensions, the files it replaces and the packages you had. `ostrich uninstall` puts all of it back and removes Ubuntu Ostrich (apps you installed with `ostrich store` stay). The default puts back **every** setting from install time, including ones you changed since; `--keep-new-settings` keeps those and undoes only Ostrich's own (and a colour scheme that is still on). What you made with Ostrich (drawer sites, saved desktops, a settings export) is copied into the kept restore point, and the last line says where. `--remove-packages` also removes the apt packages added since the install, including ones you added yourself (it lists them and asks you to type remove); without it they are only listed. It's not a full disk backup: files you create yourself are never touched either way.

## Keep or Clean

If you already have GNOME extensions, the installer asks:

- **Keep** (the default): only the extensions Ubuntu Ostrich replaces are switched off (dock, tray, blur, tiling, system monitor, workspace bar, and similar); some of their settings carry over (see the Replaced row above). Everything else stays as it is.
- **Clean**: every other extension is switched off too, and its settings are reset.

Nothing is deleted in either case, and `ostrich uninstall` brings it all back. In scripts: `--keep` or `--clean`.

## The one command

On a machine already running Ubuntu 26.04 (desktop):

```bash
wget -qO- https://raw.githubusercontent.com/thehamandbread/ubuntu-ostrich/main/install.sh | bash
```

A fresh Ubuntu has `wget` but not `curl` or `git`, so the installer adds those first and asks for your password once. Run `ostrich update` any time to get the latest version; it's safe to run again.

## Passwords for hardware changes

The system helper (`/usr/libexec/ubuntu-ostrich/system-helper`) has one polkit action per command:

| Action | Default for you at the machine |
|---|---|
| `org.ubuntu-ostrich.system-helper.power` (applying a power mode) | no password |
| `org.ubuntu-ostrich.system-helper.touchscreen` (on/off) | no password |
| `org.ubuntu-ostrich.system-helper.graphics` (changing the graphics mode) | your password, remembered for a few minutes |

To change one, add a rule, for example `/etc/polkit-1/rules.d/50-ostrich.rules`:

```js
polkit.addRule(function (action, subject) {
    if (action.id == "org.ubuntu-ostrich.system-helper.graphics" && subject.active && subject.local)
        return polkit.Result.YES;
});
```


## Only in `ostrich config`

Ostrich Settings has a control for nearly every setting. These few are for fine-tuning or are the
extensions' own bookkeeping; change them with `ostrich config set EXT KEY VALUE` (or keep them in
your dotfiles with `ostrich config export`). `tests/lib.bats` checks every setting is either in
Ostrich Settings or listed here.

| Setting | What it is |
|---|---|
| `blur/static-blur-on-battery` | Experiment: blur only the wallpaper whenever on battery (off) |
| `dock/hide-delay` | How long the dock waits before hiding, in ms |
| `dock/pressure-threshold` | How hard to push on the bottom edge to bring the dock back |
| `dock/edge-gap` | Space between the dock and the bottom edge, in px |
| `dock/hidden-app-prefixes` | Apps the dock never shows (desktop-file id prefixes) |
| `dock/background-color` | The dock's own colour when Colour is "Your own colour" (`#rrggbb`; carried over from Dash to Dock) |
| `drawer/hover-switch-ms` | How long to rest on another icon to switch sites while one is open |
| `drawer/next-site` | Super+Alt+Tab: open the next site in the top-bar order (opens the drawer if it is folded) |
| `drawer/previous-site` | Super+Alt+Shift+Tab: open the previous site |
| `drawer/pinned-apps` | The apps pinned to the drawer (desktop ids); they open in its floating window |
| `drawer/size` | The size you dragged the drawer to, the same for every site (0 × 0: the percentages in `drawer/width` and `drawer/height`) |
| `focus/restore-app-contents` | Saved workspaces also remember and reopen what was inside their apps (folders, terminal folders, browser pages) |
| `drawer/host-command` | The drawer program the extension starts (never exported or imported) |
| `monitor/interval-ac`, `monitor/interval-battery`, `monitor/interval-saver` | Seconds between readings on AC and on battery, and between the memory checks in power saver |
| `monitor/panel-box` | Which side of the top bar the readings sit on |
| `tiling/tile-top-left`, `tiling/tile-top-right`, `tiling/tile-bottom-left`, `tiling/tile-bottom-right` | Quarter-tiling shortcuts |
| `tiling/fill-popup-all-workspaces` | The fill-the-rest pop-up offers windows from every workspace |
| `tiling/focus-hint-color` | The colour of the focused window's outline, when it's on |
| `tweaks/now-playing-play-pause` | Shortcut to play or pause what the now-playing pill shows (unset) |
| `tweaks/hidden-panel-items` | Top-bar items hidden (set by the Top bar page's switches) |
| `workspaces/names-map` | Your workspace names (set by renaming a workspace) |
| `workspaces/scroll-wrap` | Scrolling past the last workspace goes back to the first |
| `blur/migrated-bms`, `tweaks/migrated-jp`, `focus/saved-show-banners`, `tweaks/bluetooth-recent` (addresses of the Bluetooth devices last seen connected, newest first; orders the quick-settings device tiles), `focus/focus-on` (whether focus is on now; the tile and the clock-menu switch follow it), `monitor/auto-saver-from`, `monitor/saved-desktop`, `tiling/migrated`, `tiling/overridden-settings` | Bookkeeping: what to put back later. Not settings to change |
