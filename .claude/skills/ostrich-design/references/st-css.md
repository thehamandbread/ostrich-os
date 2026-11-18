# St CSS in GNOME Shell 50

What GNOME Shell's St toolkit actually understands in a stylesheet, checked against the
gnome-shell **50.6** tag. St is not a browser. It parses CSS2-era syntax with libcroco and
reads only the properties its C code asks for. Anything else is silently ignored or logged
as a warning in the journal.

File references below are paths in the gnome-shell repo at tag 50.6. Read them online at
`https://gitlab.gnome.org/GNOME/gnome-shell/-/blob/50.6/<path>#L<line>`.
Clutter references are in mutter 50.6: `https://gitlab.gnome.org/GNOME/mutter/-/blob/50.6/<path>`.

## Where extension CSS comes from

- The shell loads one stylesheet per extension, picking the first file that exists from
  `<session-mode>-<variant>.css`, `stylesheet-<variant>.css`, `<session-mode>.css`, `stylesheet.css`.
  `<variant>` is the shell style variant (light or dark). So ship `stylesheet-dark.css` and
  `stylesheet-light.css` when the two need different colours.
  Source: js/ui/extensionSystem.js:129-141 (read 2026-11-05)
- Extension CSS applies to the shell and extensions only, not to the preferences window (that is GTK).
  Source: https://gjs.guide/extensions/overview/anatomy.html (read 2026-11-05)
- `@import url(...)` works and is resolved relative to the importing sheet.
  Source: src/st/st-theme.c:900-937 (read 2026-11-05)

## Selectors

- Supported: type selectors, `*`, `.class`, `#id`, pseudo-classes, the descendant combinator
  (space) and the child combinator (`>`).
  Source: src/st/st-theme.c:636-650, 728-760, 788, 837 (read 2026-11-05)
- Type selectors match GType names, not HTML tags: write `StLabel`, `StIcon`, `StBoxLayout`.
  A subclass matches its parent's type name. Source: src/st/st-theme.c:663-680 (read 2026-11-05)
- Not supported: attribute selectors (`[foo=bar]`) and the sibling combinator `+`. Both log a
  warning and never match. `~` is not handled either (falls to the default "no match").
  Source: src/st/st-theme.c:646-648, 833-835 (read 2026-11-05)
- A pseudo-class is just a string on the widget; any name works if code adds it with
  `widget.add_style_pseudo_class('name')`. Source: src/st/st-theme.c:532-549 (read 2026-11-05)
- Pseudo-classes St sets for you:
  - `:hover` when the widget has `track_hover: true`. Source: src/st/st-widget.c:1805-1828 (read 2026-11-05)
  - `:focus` on key focus. Source: src/st/st-widget.c:749, 757 (read 2026-11-05)
  - `:insensitive` when `reactive` is false. Source: src/st/st-widget.c:151-153 (read 2026-11-05)
  - `:active` while an StButton is pressed; `:checked` on a toggle StButton that is checked.
    Source: src/st/st-button.c:160, 727 (read 2026-11-05)
  - `:first-child` / `:last-child` on the first and last visible child.
    Source: src/st/st-widget.c:1415-1453 (read 2026-11-05)
  - `:ltr` / `:rtl` on every widget, for direction-aware padding. Source: src/st/st-widget.c:630-640 (read 2026-11-05)
  - `:focus` on StEntry, `:indeterminate` on its progress. Source: src/st/st-entry.c:241, 550 (read 2026-11-05)
- `:selected` used by the shell sass is set by shell JS code, not by St. unverified which widgets set it.

## At-rules

- `@media`, `@page`, `@charset` and `@font-face` rules are skipped entirely. No media queries,
  no `prefers-color-scheme`, no `prefers-reduced-motion`.
  Source: src/st/st-theme.c:940-946 (read 2026-11-05)

## Units and values

- Lengths: `px` (multiplied by the monitor scale factor), `pt`, `in`, `cm`, `mm`, `pc`
  (converted through the theme resolution), `em` and `ex` (`ex` is treated as 0.5em).
  Source: src/st/st-theme-node.c:1259-1301, 1345-1375 (read 2026-11-05)
- `em` resolves against the node's own font size (for `font-size`, the parent's). Use `em`
  for anything that should grow with the large-text setting; use `px` for hairlines and radii.
  Source: src/st/st-theme-node.c:1355-1375 (read 2026-11-05)
- A bare `0` is fine; any other unitless length is rejected ("length values must specify a unit").
  Source: src/st/st-theme-node.c:1310-1323 (read 2026-11-05)
- Percentages are rejected for lengths ("percentage lengths not currently supported"). They are
  accepted only in `font-size`, in `rgb()` and as the amount in the `st-*` colour functions.
  Source: src/st/st-theme-node.c:1325-1327, 3059-3063, 544-553, 621-624 (read 2026-11-05)
- `auto` is rejected for lengths. Source: src/st/st-theme-node.c:1306-1308 (read 2026-11-05)
- Times (`ms`, `s`) are read only by `transition-duration`. Source: src/st/st-theme-node.c:1078-1083 (read 2026-11-05)

## Colours

- Hex, CSS2 colour names, `rgb()` (via libcroco), `rgba()` and `transparent`.
  Source: src/st/st-theme-node.c:816-826, 862-874; src/st/croco/cr-rgb.c:398 (read 2026-11-05)
- St extensions: `-st-accent-color` and `-st-accent-fg-color` follow the user's accent colour
  setting. Use them instead of a hard-coded blue. Source: src/st/st-theme-node.c:485-497, 805-815 (read 2026-11-05)
- St colour functions: `st-transparentize(c, a)`, `st-mix(a, b, f)`, `st-lighten(c, f)`,
  `st-darken(c, f)`. These are evaluated at runtime, so they work on the accent colour.
  Source: src/st/st-theme-node.c:828-861 (read 2026-11-05)
- No `hsl()`/`hwb()`/`oklch()`, no `currentColor`. No hsl code exists in libcroco or st-theme-node.c.
  Source: grep of src/st/croco/*.c and src/st/st-theme-node.c (read 2026-11-05)

## Properties St reads

Box model and size (all lengths, no percentages):
- `padding`, `padding-*`, `margin`, `margin-*`, `width`, `height`, `min-width`, `min-height`,
  `max-width`, `max-height`, `-st-natural-width`, `-st-natural-height`.
  Source: src/st/st-theme-node.c:2024-2047 (read 2026-11-05)

Borders and corners:
- `border`, `border-width`, `border-color`, `border-<side>` and per-side `-width`/`-color`.
  Every style keyword (`dashed`, `dotted`, `double`, ...) is drawn as `solid`.
  Source: src/st/st-theme-node.c:1590-1660 (read 2026-11-05)
- `border-radius` with 1 to 4 values, plus per-corner `border-radius-topleft`,
  `-topright`, `-bottomright`, `-bottomleft` (St names, not the CSS3 `border-top-left-radius`).
  Elliptical `a / b` radii: unverified, do not use. Source: src/st/st-theme-node.c:1527-1580 (read 2026-11-05)
- `outline`, `outline-width`, `outline-color` are parsed. Source: src/st/st-theme-node.c:1719-1807 (read 2026-11-05).
  The shell's own focus rings use an inset `box-shadow` instead; prefer that.
  Source: data/theme/gnome-shell-sass/_drawing.scss:57-66 (read 2026-11-05)
- `border-image: url(...) <slices>`. Source: src/st/st-theme-node.c:3447 (read 2026-11-05)

Background:
- `background`, `background-color`, `background-image: url(...)` (file URL only),
  `background-position`, `background-repeat`, `background-size` (`contain`, `cover`, lengths).
  Source: src/st/st-theme-node.c:2291-2460 (read 2026-11-05)
- Gradients are St-specific: `background-gradient-direction: vertical | horizontal | radial`,
  `background-gradient-start: <color>`, `background-gradient-end: <color>`. Two stops only.
  `linear-gradient()` is not supported. Source: src/st/st-theme-node.c:2462-2495 (read 2026-11-05)
- `-st-background-image-shadow`. Source: src/st/st-theme-node.c:3914 (read 2026-11-05)

Shadows:
- `box-shadow`, `text-shadow`, `icon-shadow` (on StIcon). Format: `[inset] x y [blur] [spread] color`.
  Negative blur or spread is warned. Only one shadow per property: a comma list is not split,
  extra lengths are ignored with a warning. Source: src/st/st-theme-node.c:3636-3720, 3879, 3956;
  src/st/st-icon.c:237 (read 2026-11-05)

Text:
- `color`, `font`, `font-family`, `font-size` (lengths, %, keywords `xx-small`..`xx-large`,
  `smaller`, `larger`), `font-weight` (keywords or 100-900), `font-style`, `font-variant`
  (`small-caps`), `font-feature-settings` (e.g. `"tnum"`), `letter-spacing`, `text-align`
  (`left`, `right`, `center`, `justify`), `text-decoration` (`underline`, `overline`,
  `line-through`, `blink`). Source: src/st/st-theme-node.c:2557, 2776, 2853, 2910, 3218-3330, 3397 (read 2026-11-05)
- No `line-height`, `text-transform`, `white-space`, `word-spacing` or `text-overflow`.
  Ellipsizing is set in code on the ClutterText. Source: absent from the property list in
  src/st/st-theme-node.c (grep, read 2026-11-05)

Widget-specific:
- `spacing` (StBoxLayout gap between children). Source: src/st/st-box-layout.c:138 (read 2026-11-05)
- `icon-size` (StIcon). Source: src/st/st-icon.c:267 (read 2026-11-05)
- `-st-icon-style: requested | regular | symbolic`. Source: src/st/st-theme-node.c:2724-2741 (read 2026-11-05)
- `caret-color`, `caret-size`, `selection-background-color`, `selected-color` (StEntry).
  Source: src/st/st-entry.c:270-279 (read 2026-11-05)
- `-st-hfade-offset`, `-st-vfade-offset` (StScrollView edge fade). Source: src/st/st-scroll-view.c:721-722 (read 2026-11-05)
- `min-size`, `max-size` (StScrollBar handle). Source: src/st/st-scroll-bar.c:244-246 (read 2026-11-05)
- `warning-color`, `error-color`, `success-color` (symbolic icon recolouring).
  Source: src/st/st-theme-node.c:4051 (read 2026-11-05)

Custom lengths read from JS:
- Any property name can be read from code with `themeNode.get_length('-my-gap')`. This is how
  the shell does `-natural-hpadding`, `-arrow-rise`, `spacing-rows`. It is the only "custom
  property" mechanism; there is no `var()`. Source: data/theme/gnome-shell-sass/widgets/_panel.scss:28-29,
  _popovers.scss:12, _quick-settings.scss:11 (read 2026-11-05)

## Transitions

- `transition-duration: 150ms` cross-fades between the old and new *painted background* of a
  widget (background, border, shadow) whenever its style changes, e.g. on `:hover`. There is no
  `transition-property` and no `transition-timing-function`; the curve is fixed at
  EASE_IN_OUT_QUAD. Source: src/st/st-theme-node-transition.c:110; src/st/st-widget.c:1661-1690 (read 2026-11-05)
- Text colour, size and position changes do not animate; the code comment says "we can't animate
  that anyways". Use `actor.ease()` in JS for movement. Source: src/st/st-widget.c:1678-1683 (read 2026-11-05)
- The duration is multiplied by the slow-down factor and skipped when animations are disabled.
  Source: src/st/st-theme-node.c:2681-2699; src/st/st-widget.c:1667-1670 (read 2026-11-05)

## Not supported (do not write these)

| Feature | Status | Source (read 2026-11-05) |
|---|---|---|
| `display`, flexbox, grid, `position`, `z-index`, `float` | Not parsed. Layout is done by Clutter layout managers in code | absent from src/st/st-theme-node.c |
| `var()`, custom properties, `calc()`, `min()`/`clamp()` | Not parsed | no occurrence in src/st/st-theme-node.c or st-theme.c |
| Percent lengths, `auto` lengths | Warned and dropped | src/st/st-theme-node.c:1306-1327 |
| `@media` (incl. reduced motion, colour scheme) | Rule skipped | src/st/st-theme.c:940 |
| Attribute selectors, `+`, `~` | Never match | src/st/st-theme.c:646, 833 |
| `linear-gradient()`, multi-stop gradients | Use `background-gradient-*` | src/st/st-theme-node.c:2462-2495 |
| Multiple shadows in one property | First set only | src/st/st-theme-node.c:3636-3700 |
| `opacity`, `transform`, `filter`, `backdrop-filter` | Not CSS in St; set `actor.opacity`, scale, translation, effects in JS | absent from src/st/st-theme-node.c |
| `transition-property`, timing functions, `animation`, `@keyframes` | Only `transition-duration` | src/st/st-theme-node.c:2681 |

## How to make it look native (GNOME 50 shell values)

All from `data/theme/gnome-shell-sass/` at 50.6. Base tokens: font 11pt, padding 6px, margin 4px,
radius 8px, "modal" radius 16px, alert radius 18px, circular radius 999px.
Source: _common.scss:30-43 (read 2026-11-05)

`to_em(px)` in the sass is `px / 16 * 1.091` em, so 16px becomes 1.091em.
Source: _drawing.scss:6-10 (read 2026-11-05)

| Surface | Values | Source (read 2026-11-05) |
|---|---|---|
| Top bar `#panel` | height 2.2em, bold, transition 250ms; light theme adds `inset 0 -0.5px 0 0` bottom line. About 32px at 11pt and 96 dpi (derived, unverified on device) | widgets/_panel.scss:10-23 |
| Panel button | `border: 3px solid transparent` (fake padding), radius 999px, transition 150ms, hover fill = fg at 17% alpha, active 28%; natural h-padding 12px, minimum 6px | _drawing.scss:396-420; widgets/_panel.scss:27-29 |
| Panel status icon | icon-size 1.091em (16px), padding 0 6px, margin 0 4px | widgets/_panel.scss:32-36 |
| Popup menu | min-width 15em; content padding 6px, radius 20px, 1px border, shadow `0 2px 4px 0` | widgets/_popovers.scss:16-33 |
| Popup menu item | padding 9px 12px, spacing 6px, radius 12px, transition 100ms, normal weight | _common.scss:131-136; widgets/_popovers.scss:6, 36-39 |
| Quick settings panel | padding 18px, radius 36px, grid gaps 12px | widgets/_quick-settings.scss:1-12 |
| Quick toggle | pill (999px), width fixed 12em, min-height 3.273em (3 x scalable icon), inner padding 0 12px (15px on the leading side), icon 1.091em | widgets/_quick-settings.scss:15-47 |
| Quick toggle menu | radius 24px, top margin 12px | widgets/_quick-settings.scss:150-160 |
| OSD | pill (999px), 1px border, padding 12px 18px, icon 32px, level bar 6px high and at least 160px wide, 4em above screen bottom | _common.scss:291-300; widgets/_osd.scss:3-31 |
| Notification banner | width 34em, min-height 64px, radius 16px, margin 4px, shadow `0 2px 4px 2px` | widgets/_notifications.scss:3-16 |
| Dash (dock) | background radius 28px (16 + 12), padding 12px, item gap 2px each side | widgets/_dash.scss:4-25 |
| Focus ring | `box-shadow: inset 0 0 0 2px` accent at 80% alpha | _drawing.scss:57-66; _default-colors.scss:41 |

Colours (dark / light): window bg `#36363a` / `#fafafb`; text `#ffffff` / `#222226`;
panel bg `#000000` / `#fafafb`; shadow `rgba(0,0,0,0.2)` / `rgba(0,0,0,0.05)`; OSD bg is
`#222226` lightened 5%; accent is `-st-accent-color` (light) or a 60% mix with white (dark).
Source: _colors.scss:12-24; _default-colors.scss:4-8, 36; _palette.scss:37-46 (read 2026-11-05)

High contrast: the shell builds a separate `gnome-shell-high-contrast.scss` that sets borders to
50% and drops all shadows. Never rely on a shadow alone to separate a surface.
Source: data/theme/gnome-shell-high-contrast.scss; _default-colors.scss:44-50 (read 2026-11-05)

Rules of thumb:
- Reuse shell classes (`popup-menu-item`, `quick-toggle`, `osd-window`, `button`) before writing
  your own; you inherit the light, dark and high-contrast variants for free.
- Size text-bearing boxes in `em` so they follow the large-text setting; radii and borders in px.
- Match the radius family: 12px items inside 20px menus; pills (999px) for toggles and OSDs.
