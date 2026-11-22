# Ostrich OS app icons

One scheme for every app we ship: a flat rounded square with one plain glyph. Two looks, one per
colour style (owner, 2026-11-06): the dark style has a pale tile tinted in the app's hue with the glyph
in the strong hue (`template.svg`, `dark.toml`, written to `modules/tools/icons/`); the light style has a
dark tile with the glyph in a bright hue and a thin rim, because the dock is dark in both styles
(`template-light.svg`, `light.toml`, written to `modules/tools/icons-light/`). The installer puts both in
`~/.local/share/ostrich-os/icons/` and `modules/tools/ostrich-icon-style` copies the right one into
the icon theme when the style changes. Shape and hue tell the apps apart.

| App | Glyph |
|---|---|
| Ostrich Store | a shopping bag |
| Ostrich Settings | three sliders (not a gear, so it isn't mistaken for GNOME Settings) |
| Ostrich Drawer | the top bar with a panel dropped down from it |
| Help (in the dock only) | a question mark in a ring |
| The dock's Show Apps button | a grid of nine tiles |

Each app also has a one-colour 16 px `-symbolic` icon for menus and status pages.

## Making them

```bash
tools/icons/export.sh            # writes modules/tools/icons/*.svg (+ PNG previews if it can)
tools/icons/export.sh --check    # CI: are the committed icons up to date?
```

- `template.svg`, `template-light.svg`: the two tiles, with `{{glyph_svg}}` where the glyph goes.
- `dark.toml`, `light.toml`: their colours, read over `palette.toml`.
- `palette.toml`: the shared colours. Change one and re-export to recolour every icon.
- `glyphs/NAME.svg`: one app's glyph, as shapes on the 128 px grid inside 32..96, coloured with
  palette names (`{{glyph}}`, `{{accent}}`, `{{shell_bottom}}`...).
- `symbolic/NAME.svg`: the 16 px version, one colour (`#2e3436`, which GNOME recolours).

To try another look without touching the committed icons, set `ICONS_OUT` to a fresh folder (it is
emptied; the script refuses without it) and any of: `TEMPLATE` (another template; `@NAME@` in it is
the app's name), `PALETTE` (a scheme), `PALETTE_OVER` (a file of `name = "#rrggbb"` lines that replace
single colours), `GLYPHS=symbolic` (the 16 px drawing, scaled up, as the glyph).

The script needs only bash and sed. Previews need `rsvg-convert` (`librsvg2-bin`) or Inkscape.

## Drawing by hand

Inkscape (in Ostrich Store's recommended apps; the installer never adds it) opens the generated
SVGs. Draw on the 128 px canvas, then copy your shapes into `glyphs/NAME.svg`, replacing the colours
with palette names, and run `export.sh`. The installer puts the icons in
`~/.local/share/icons/hicolor/{scalable,symbolic}/apps/`.
