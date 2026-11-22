# Parity with the extensions Ostrich OS replaces

Each of our extensions replaces a popular one. The bar: match the original's look and every feature
the user used (docs/INVENTORY.md), add its most-used features, then beat it. Status: ✅ done, ⏳ planned,
➖ not doing (why). Checked side by side in the VM with `tests/vm/compare.sh` (the `pre` snapshot runs
the originals).

## Dock — replaces Dash to Dock / Ubuntu Dock

| Feature | Original | Ours |
|---|---|---|
| Auto-hide, intellihide (hide only when a window overlaps) | ✓ (user: intellihide off) | ✅ both; default: hide only when a window is in the way |
| Show by pushing the edge / pressure threshold | ✓ | ✅ (threshold 0: just touch the edge) |
| Fixed (always shown) | ✓ | ✅ (auto-hide off) |
| Icon size | ✓ (user: 34 max) | ✅ default 40 |
| Floating, rounded, sized to its icons | partial (extend-to-edge off) | ✅ 8 px gap, 18 px corners |
| Background colour and opacity | ✓ (user: purple 20 %) | ✅ black/white by style or the wallpaper accent; opacity % |
| No grey square behind each icon | — (Ubuntu theme draws it) | ✅ bare icons; fill only on hover/press |
| Running indicators | dots, dashes, segmented, metro… | ✅ a dot per window (up to 4, accent on the focused app), one dot, or none |
| Click: focus, minimize, cycle windows | ✓ | ✅ focus-or-minimize (default), focus-or-cycle, focus |
| Middle-click: new window | ✓ | ✅ (GNOME's own) |
| Scroll: cycle windows | ✓ | ✅ |
| Window previews | ✓ | ✅ live thumbnails on hover; click to switch, middle-click to close |
| Unread badges and progress (Unity launcher API) | ✓ | ✅ |
| Show Apps button at either end | ✓ | ✅ |
| Monitor choice | primary / any / all | ✅ primary or a chosen one; ⏳ a dock on every monitor |
| Launch on the discrete GPU | — | ✅ (GNOME's own app menu item on hybrid machines) |
| Trash and drives in the dock | ✓ | ➖ (Files has them; adds clutter) |
| Hides from fullscreen apps | ✓ | ✅ |
| No polling, one timer while visible | — | ✅ (beats it: nothing runs while hidden) |

## Blur — replaces Blur my Shell

| Feature | Original | Ours |
|---|---|---|
| Top bar, dock, menus, overview, app folders, lock screen | ✓ | ✅ each on or off (off: solid) |
| Strength (radius) and brightness per surface | ✓ (user: 30 / 0.6, folders and popups 60) | ✅ per surface; defaults: bar and dock 30, menus and notifications 40, folders and overview 60; brightness 0.7–1.0 |
| Frosted, not see-through | ✓ | ✅ measured: a checkerboard behind the bar loses its contrast (`tests/vm/blur-test.sh`) |
| Static (wallpaper only) vs dynamic (live) | per surface | ✅ live everywhere; the overview and power saver blur the wallpaper only |
| Rounded corners on the dock and menus | ✓ | ✅ |
| Re-blur only when something behind changes | partly | ✅ |
| Blur behind application windows | ✓ | ➖ (costly on battery; apps choose their own) |
| Noise / colour effects, pipelines | ✓ | ➖ (rarely used; a tint per surface instead) |

## Workspace bar — replaces Space Bar

| Feature | Original | Ours |
|---|---|---|
| A pill per workspace with its name or number | ✓ (user: bold, 3/8 px padding) | ✅ bold pills, 3 × 8 px, 3 px gaps |
| Active, inactive and empty styles | ✓ | ✅ accent (or white) fill, white text, empty at 50 % |
| Click to switch; click the active one for the overview | ✓ | ✅ |
| Scroll to switch, optional wrap-around | ✓ (user: no wrap) | ✅ |
| Rename (right-click) | ✓ | ✅ |
| Smart names (named after their apps) | ✓ (user: on) | ✅ same name map format |
| Drag to reorder | ✓ | ✅ names move with them |
| Drop a window onto a workspace | ✓ | ✅ (from the overview) |
| New, move left/right, remove (menu) | ✓ | ✅ (remove moves its windows next door) |
| Show or hide empty workspaces | ✓ | ✅ |
| Current-name-only style | ✓ | ✅ |
| Shortcuts: new, rename, move | ✓ | ✅ Super+Alt+N, Super+Alt+R, Super+Alt+Page Up/Down |
| App icons per workspace | — | ✅ option (beats it) |

## Tweaks — replaces Just Perfection

| Feature | Original | Ours |
|---|---|---|
| Animation speed | ✓ (user: set) | ✅ (carried over) |
| Hide top-bar items | ✓ | ✅ |
| Super twice for the app grid | ✓ (user: on) | ➖ GNOME's own quick double press (owner, 2026-11-18: a second Super must close) |
| Start in overview or desktop | ✓ | ✅ (GNOME's own setting) |
| Accent from the wallpaper, following it | — | ✅ (beats it) |
| The many other visibility toggles | ✓ | ➖ only on request (each is a setting to maintain) |

## Ostrich Drawer — replaces separate browser windows and pinned tabs

✅ per-site top-bar icons with unread badges, click or hover to open under the icon, per-site sizes,
keep-alive and mute per site, environments' own sites, recommended sites checked in WebKitGTK,
kept running (closing only hides it), out of Alt+Tab, the dock and the overview. ⏳ DRM video.

## System monitor — replaces Vitals

| Feature | Original | Ours |
|---|---|---|
| CPU, memory, temperature in the top bar | ✓ (user: CPU, memory, temperature, 2 s) | ✅ |
| GPU state (NVIDIA asleep or awake) | — | ✅ (beats it) |
| Popup of sections with icons (processor, memory, temperature, fans, voltage, system, network, storage, battery, graphics), values on the right | ✓ | ✅ |
| Pin any value to the top bar (the star on its row), in the order pinned | ✓ | ✅ |
| Per-core usage, clocks, load, swap, uptime, processes | ✓ | ✅ |
| Network speeds and totals; disk reads and writes; free space | ✓ | ✅ |
| Hide zero values | ✓ | ✅ |
| Refresh, open the system monitor app, settings from the popup | ✓ | ✅ |
| Slower updates on battery, none while locked; a shut popup reads only what's pinned | — | ✅ (beats it) |
| Battery time left and draw in watts; apps on the NVIDIA GPU, with quit and keep-off | — | ✅ (beats it) |
| Public IP, Wi-Fi signal | ✓ | ➖ (a network request on every tick; GNOME's own menus show Wi-Fi) |

## Tiling — replaces Tiling Assistant

✅ halves and quarters by keyboard or drag, fill the rest, windows raised together, gaps,
focus outline (the user's settings carried over). ⏳ custom layouts.

## Tray — replaces AppIndicator

✅ StatusNotifierItem icons, menus fetched only when opened, middle-click and scroll passed on,
no polling.
