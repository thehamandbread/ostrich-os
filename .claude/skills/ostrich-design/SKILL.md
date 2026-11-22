---
name: ostrich-design
description: Design rules for Ostrich OS's UI, from the GNOME HIG, libadwaita 1.9, GNOME Shell 50's own theme (St CSS), WCAG 2.2 and Material/Apple motion. Use before and while writing or changing any GNOME Shell extension surface (top bar items, dock, menus, quick settings, pop-out cards, OSDs, stylesheet.css/.css.in) or any GTK4/libadwaita screen in tools/ (Ostrich Settings, Store, Drawer, speaker tuning), and when reviewing how something looks.
---

# Ostrich design

Ostrich OS should look like GNOME's own designers made it, then a little warmer. Every rule here
comes from a source in `references/`, each with its URL or source file and the date it was read.
When this file and a reference disagree, the reference wins; when a reference and the live GNOME 50
system disagree, the system wins (check it in the VM).

## Which surface are you designing?

| Surface | Toolkit | Read first |
|---|---|---|
| Top bar items, dock, menus, quick settings, pop-out cards, OSDs, banners | GNOME Shell extension: St widgets + St CSS | `references/st-css.md`, then `references/motion.md` |
| Ostrich Settings, Store, Drawer window, speaker tuning | GTK4 + libadwaita 1.9 (Rust) | `references/libadwaita.md`, then `references/gnome-hig.md` |
| Anything | — | `references/accessibility.md` (always), `references/components.md` (our components) |

St is not web CSS: no `var()`, `calc()`, flexbox, grid, `@media`, percentages or multiple shadows.
Layout is done in JS (St.BoxLayout, Clutter layouts); CSS only paints and pads. libadwaita is real
GTK CSS with variables (`--accent-bg-color`) and style classes; never hard-code a colour there.

## The process

1. **Find the pattern before drawing anything.** GNOME has one for most jobs: boxed lists, popovers,
   toasts, banners, status pages, quick toggles, OSDs (`references/gnome-hig.md`,
   `references/libadwaita.md`). Use it as it is. Only invent when nothing fits, and say so.
2. **Use the tokens, not numbers.**
   - Colours: `tools/icons/palette.toml` (`{{name}}` in an extension's `stylesheet.css.in`).
   - Sizes: corners, space, targets in `tools/icons/tokens.toml` (`[[name]]`).
   - GTK: libadwaita's CSS variables and style classes.
   - Motion: `_lib/motion.js` (`popOut`, `retreat`, `animate` with `QUICK`/`STANDARD`/`SLOW`).
   A number that has a token is a bug (`scripts/token-lint.sh`, which CI runs: sizes, fixed hex colours,
   a `:focus` rule on every `-button` and `-segment` class, `dim-label`). A justified exception is
   written in the stylesheet, with its reason: `/* token-lint: allow <why> */` on the line, or
   `token-lint: off <why>` ... `token-lint: on` around a block.
3. **Match the shell beside it.** A menu item inside a 20px menu has 12px corners; cards are 16px;
   toggles and OSDs are pills. Our surfaces sit next to GNOME's: same radius family, same padding
   rhythm (4 / 6 / 12 / 18 px), same type (11pt base, bold only for titles).
4. **Words.** Short, plain, sentence case, no jargon or raw errors (`references/gnome-hig.md`,
   Writing style). One line of help text, not a paragraph; a long line stretches its whole menu.
5. **Check before calling it done** (all of these, every time):
   - Contrast: text 4.5:1, large text and icons/borders 3:1, in light, dark and High contrast
     (`scripts/contrast.py FG BG`, `tests/vm/contrast.sh` on a screenshot).
   - Targets at least 24 × 24 px (`[[target_min]]`).
   - Keyboard: everything reachable with Tab/arrows, a visible focus ring, Esc closes.
   - Screen reader: every icon-only control has `accessible_name`; alerts have the ALERT role
     (`tests/vm/a11y-test.sh`).
   - Motion: only transform and opacity move; Reduced Motion gives a fade (`references/motion.md`).
   - Only offer what works on this machine (a power mode it doesn't have, a feature whose helper
     isn't installed): hide it, don't let it fail.
   - Look at it in the GPU VM (`tests/vm/vm.sh view SNAPSHOT`) in light and dark, and at 200 % text.
   - The journal gate stays clean (no St/Clutter warnings from our code).

## Ostrich's decisions (the owner's, on top of GNOME)

- **Motion: Spring.** A surface grows out of a small copy (20 %) at the middle of where it comes
  from, 280 ms, Clutter `EASE_OUT_BACK` (≈ cubic-bezier(0.34, 1.56, 0.64, 1)); it goes back in
  140 ms, `EASE_IN_QUAD`, into its source. Always through `_lib/motion.js`. Power saver keeps it.
  (docs/DECISIONS.md, 2026-11-02; `references/motion.md`.)
- **Things come from where they belong.** System alerts pop out of the top-bar item they're about
  (the monitor, the clock); previews from their dock icon. App notifications stay GNOME banners.
- **Glass:** the top bar always blurs the wallpaper only (steady, no flicker); the dock, menus and
  banners blur what's behind them, with a light tint. Power saver: menus, folders and the overview
  go solid black; bar and dock keep their wallpaper blur.
- **One accent action per view** (libadwaita's `suggested-action` / our accent pill): the thing the
  page is for. Destructive actions ask once ("End Firefox? Unsaved work is lost").
- **Readings and toggles keep their place.** Values that pause show a dash in the same width;
  nothing in the top bar jumps.

## What the design council still decides

The HIG gives the grammar; Ostrich's own look on top of it (icon style, Settings layout and search,
the quick-settings and monitor menus, the sound page) is the council's job (`/council`, docs/council/).
Its rulings go into `references/components.md` and this section, with the date.

## Mistakes we already made (don't repeat them)

- A one-line paragraph in a menu: the menu stretched across the screen (monitor, 2026-11-05).
- Clutter's `min_width` above a label's natural width: GNOME Shell aborted laying out the bar. Hold a
  width with an St `min-width` style instead.
- A choice the machine doesn't support (Performance mode in a VM) ended in a raw D-Bus error shown
  to the user.
- Moving or resizing an actor from `notify::allocation`: "needs an allocation" warnings and a frame
  late. Use `BeforeRedraw` (`_lib/timers.js`).
- Glass with a box-shadow: St draws the shadow under the whole surface and darkens what's behind.
- Hard-coded colours in an extension's `stylesheet.css`: they ignore the user's colour scheme.

## Files

- `references/gnome-hig.md`: GNOME HIG, condensed, with links.
- `references/libadwaita.md`: libadwaita 1.9 widgets, style classes, variables, feedback, adaptive.
- `references/st-css.md`: what GNOME Shell 50's St CSS supports, and the shell's own sizes.
- `references/accessibility.md`: WCAG 2.2 and GNOME's accessibility specifics.
- `references/motion.md`: Material 3 and Apple motion, Clutter easing, our Spring.
- `references/components.md`: Ostrich's components and how each is built.
- `scripts/contrast.py FG BG`: WCAG contrast ratio of two colours (hex or rgba over a background).
- `scripts/spec-sheet.py OUT.html`: the whole spec on one page, from tokens.toml, palette.toml and motion.js.
- `scripts/token-lint.sh`: literal sizes in extension stylesheets that should be tokens.
