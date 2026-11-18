# Ostrich components

Each component: what it's for, the GNOME pattern it follows, how it's built, and what's still open.
Sizes are tokens (`tools/icons/tokens.toml`), colours are palette names (`tools/icons/palette.toml`).
"Open" items wait for the design council (SKILL.md, "What the design council still decides").

## Pop-out alert card (system alerts)

- **For:** an Ostrich system alert: memory nearly full, power saver switched on, the NVIDIA GPU woken
  on battery. Not for app notifications (those stay GNOME banners).
- **Pattern:** a notification banner's shape (radius `[[radius_card]]` 16px, like GNOME 50's banner,
  references/st-css.md) that grows out of its top-bar source (references/motion.md).
- **Built:** `_lib/alert.js` (`PopOut`), placed by `_lib/place.js`, moved by `_lib/motion.js`
  (`popOut`/`retreat`). Title (bold), one plain line, the app's icon, up to 3 buttons (GNOME allows
  up to 3 notification actions, references/gnome-hig.md). A destructive button asks once. Closes
  with ✕ or Esc, after 20 s unless hovered, and when the screen locks. Role ALERT for Orca.
- **Open:** its CSS lives in `monitor/stylesheet.css.in` (palette names for the focus ring; sizes still literal,
  the `[[tokens]]` move is council 2026-11-05 M5).

## Now-playing pill

- **For:** what's playing, beside the clock, only while something plays.
- **Pattern:** a pill (`[[radius_pill]]`) like the clock's own bubble; its menu is a standard
  popup menu with previous / play-pause / next.
- **Built:** `tweaks/nowplaying.js`, MPRIS via `_lib/mpris.js`; floats beside the clock (top chrome)
  so the clock never moves; springs out of the clock on Play, back 6 s after it stops.

## System monitor menu

- **For:** live readings (pinned ones in the top bar) and the monitor's own actions. Power modes
  are GNOME's Power Mode tile (the popup's own row was removed: owner, 2026-11-09).
- **Pattern:** a popup menu (`[[radius_menu]]` 20px, items `[[radius_item]]` 12px) with expandable
  sections, like Vitals' layout the owner used.
- **Built:** `monitor/extension.js`. In power saver the top bar's readings fold away to a
  power-saver icon (`motion.js`), and a short note in the popup says the readings are paused.
- **Open (owner's notes 2026-11-05):** "doesn't seem designed well", wants a resize option, and a
  redesign. For the council: section layout, how much it shows by default, sizing.

## Quick-settings tiles (Focus, Workspaces, Touchscreen, speaker tuning)

- **Pattern:** GNOME's quick toggle (pill, fixed 12em wide, 3 × icon high; references/st-css.md),
  through `QuickSettings.QuickToggle` / `QuickMenuToggle`, never a look-alike.
- **Built:** focus/extension.js (Focus is a plain toggle; Workspaces is a menu toggle listing saved
  workspaces), tweaks (Touchscreen, speakers).
- **Open (owner, 2026-11-05):** redesign the quick-settings menu as a whole: council.

## Dock icon overlays

- **Badges:** unread count, top-right, accent fill. **Progress:** a bar along the bottom. **Dots:** a
  dot per window. **Speaker:** top-left, accent disc with a dark ring, click pauses that app (MPRIS).
- **Rule:** overlays are icon-sized corners only; at most two at once on an icon.

## Ostrich Settings (GTK4 / libadwaita)

- **Pattern:** `AdwNavigationSplitView` (sidebar of pages) + `AdwPreferencesPage` of
  `AdwPreferencesGroup`s with switch / combo / spin / action rows (references/libadwaita.md).
- **Rules from libadwaita 1.9:** `dimmed`, not the deprecated `dim-label`; `AdwPreferencesDialog`,
  not the deprecated `AdwPreferencesWindow`; one `suggested-action` per page (our convention);
  toasts for "done, undo", banners for a lasting state, dialogs only to stop and ask.
- **Built:** `tools/welcome/src/main.rs`. One window: a second launch with `--step` goes to that page.
- **Open (owner's notes):** search for settings (NavigationSplitView has none built in: a
  GtkSearchBar in the sidebar over our own index of pages and rows), a sidebar that scrolls, the
  sound page with a play button per setting: council.

## Drawer (web apps under the top bar)

- **Pattern:** the drawer drops from its top-bar icon (a popover's relationship to its button,
  references/gnome-hig.md: popovers point at what opened them).
- **Built:** `drawer/` (shell side) + `tools/drawer-host` (GTK4 + WebKitGTK). Icons: favicon, unread
  badge, a dot while loaded, dimmed while unloaded, a speaker in the corner while playing.
