# Accessibility for shell extensions and GTK apps

WCAG 2.2 is written for web content, but its numbers are the accepted yardstick for desktop UI
too. Treat one CSS px as one St/GTK logical pixel (before monitor scaling). Every threshold
is a hard floor: WCAG says ratios are not rounded, so 4.499:1 fails 4.5:1.
Source: https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum (read 2026-11-05)

## Contrast

**1.4.3 Contrast (Minimum), level AA.** Text needs 4.5:1 against its background. Large text
needs 3:1. Large means at least 18pt (24px) regular, or 14pt (about 18.5px) bold. Disabled
(insensitive) controls, pure decoration and logotypes are exempt.
Quote: "at least 4.5:1".
Source: https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum (read 2026-11-05)

**1.4.6 Contrast (Enhanced), level AAA.** 7:1 for text, 4.5:1 for large text, same exemptions.
Aim for this on the text people read most (notification bodies, menu items, the top bar).
Source: https://www.w3.org/WAI/WCAG22/Understanding/contrast-enhanced (read 2026-11-05)

**1.4.11 Non-text Contrast, level AA.** 3:1 against adjacent colours for anything needed to see
a control and its state: toggle on/off fill, slider track and handle, checkbox box, focus ring,
icons that carry meaning. A button with a text label does not need a visible border, but its
focus indicator still needs 3:1. Inactive controls are exempt.
Source: https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast (read 2026-11-05)

How to check: measure screenshots from the VM with `tests/vm/contrast.sh`, in light, dark and
high-contrast modes, and over the busiest wallpaper you ship (translucent surfaces change
contrast with what is behind them).

**1.4.1 Use of Color, level A.** Colour must never be the only signal. A red badge also needs
a shape, icon or word. Two colours count as distinct only if their lightness differs by 3:1.
Source: https://www.w3.org/WAI/WCAG22/Understanding/use-of-color (read 2026-11-05)

GNOME has a setting for this: `org.gnome.desktop.a11y.interface show-status-shapes` (boolean,
default false), "Whether to use shapes to indicate status in addition or instead of color."
Show shapes always if you can; at least honour the key.
Source: gsettings-desktop-schemas 50.1, schemas/org.gnome.desktop.a11y.interface.gschema.xml.in:11-17 (read 2026-11-05)

## Text spacing and size

**1.4.12 Text Spacing, level AA (brief).** Layout must survive line height 1.5x the font size,
paragraph spacing 2x, letter spacing 0.12x, word spacing 0.16x. On the desktop the practical
lesson is: never fix the height of a box that holds text; let it grow.
Source: https://www.w3.org/WAI/WCAG22/Understanding/text-spacing (read 2026-11-05)

Large text in GNOME is `org.gnome.desktop.interface text-scaling-factor` (double, 0.5 to 3.0,
default 1.0). The Large Text switch in Settings sets it above 1. Size every text-bearing St box
in `em`, never in px, so it scales; see st-css.md.
Source: gsettings-desktop-schemas 50.1, schemas/org.gnome.desktop.interface.gschema.xml.in:121-126 (read 2026-11-05).
How the shell applies the factor to its fonts: unverified.

## Keyboard and focus

**2.1.1 Keyboard, level A.** Everything a pointer can do must work from the keyboard, with no
timing. Only path-dependent input (freehand drawing) is exempt; drag-to-reorder is not exempt,
so give it a keyboard alternative (for a dock: move left/right actions).
Source: https://www.w3.org/WAI/WCAG22/Understanding/keyboard (read 2026-11-05)

In St, a widget takes key focus only with `can_focus: true`; it then gets the `:focus`
pseudo-class. Source: gnome-shell 50.6 src/st/st-widget.c:749, 979 (read 2026-11-05)

**2.4.7 Focus Visible, level AA.** The focused element must always show a visible indicator,
and the indicator must not disappear after a timeout.
Source: https://www.w3.org/WAI/WCAG22/Understanding/focus-visible (read 2026-11-05)

**2.4.13 Focus Appearance, level AAA (target).** The indicator should be at least as large as a
2px-thick line around the control and change by 3:1 between focused and unfocused pixels. A
solid 2px outline passes; a 2px inset ring fails and needs 3px.
Source: https://www.w3.org/WAI/WCAG22/Understanding/focus-appearance (read 2026-11-05)

The shell's own focus ring is `box-shadow: inset 0 0 0 2px` in the accent colour at 80% alpha.
Matching it is native; by the 2.4.13 rule above an inset ring needs 3px to reach AAA.
Source: gnome-shell 50.6 data/theme/gnome-shell-sass/_drawing.scss:57-66 (read 2026-11-05)

GNOME exposes a focus timeout key, `org.gnome.desktop.a11y.interface keyboard-focus-visible-timeout`
(int, default -1; 0 means forever). Reported on the schema's main branch; not present in the 50.1
file I read, so treat as not in GNOME 50.
Source: gsettings-desktop-schemas 50.1 schemas/org.gnome.desktop.a11y.interface.gschema.xml.in (read 2026-11-05)

**2.4.11 Focus Not Obscured (Minimum), level AA.** A focused control must not be completely
hidden by something we drew (a pop-out card, the dock, a sticky header). Partly covered is
allowed at AA. Content the user opened and can dismiss without moving focus does not count.
Source: https://www.w3.org/WAI/WCAG22/Understanding/focus-not-obscured-minimum (read 2026-11-05)

## Target size

**2.5.8 Target Size (Minimum), level AA.** Pointer targets at least 24x24px. A smaller target
passes only if a 24px circle centred on it touches no other target or circle (so 20x20 icons
with 4px gaps pass; 16px buttons 1px apart fail). Inline text links and unchanged toolkit
controls are exempt.
Source: https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum (read 2026-11-05)

**2.5.5 Target Size (Enhanced), level AAA.** 44x44px, unless an equivalent 44px target exists,
the target is inline, or the size is essential.
Source: https://www.w3.org/WAI/WCAG22/Understanding/target-size-enhanced (read 2026-11-05)

Our rule: 24px is the floor for anything; primary actions (dock items, alert buttons, quick
toggles, close buttons on cards) aim for 44px in the reactive area, even if the visible shape
is smaller. Padding counts; margin does not.

## Motion

**2.3.3 Animation from Interactions, level AAA.** Motion triggered by an interaction must be
possible to turn off, unless essential. Colour and opacity changes that do not move, resize or
reshape anything do not count as motion.
Source: https://www.w3.org/WAI/WCAG22/Understanding/animation-from-interactions (read 2026-11-05)

GNOME has two switches; honour both:
- `org.gnome.desktop.interface enable-animations` (boolean, default true). The shell reads it into
  `St.Settings.get().enable_animations`. `actor.ease()` durations already become 0 when it is
  off, and CSS `transition-duration` is skipped. Animations you drive yourself (timelines,
  `GLib.timeout_add` loops) must check it.
  Source: gnome-shell 50.6 js/misc/animationUtils.js:23-33; src/st/st-settings.c:29, 85-92;
  src/st/st-widget.c:1667-1670 (read 2026-11-05)
- `org.gnome.desktop.a11y.interface reduced-motion` (enum `no-preference` | `reduce`, default
  `no-preference`). GNOME Shell 50.6 code does not read it (no reference in src/st or js/).
  When it is `reduce`, our extensions should swap movement and scale for a short cross-fade.
  Source: gsettings-desktop-schemas 50.1 schemas/org.gnome.desktop.a11y.interface.gschema.xml.in:18-24,
  headers/gdesktop-enums.h:296-297; grep of gnome-shell 50.6 (read 2026-11-05)
- GTK4 apps: `Gtk.Settings:gtk-enable-animations` (default TRUE) and, since GTK 4.22,
  `gtk-interface-reduced-motion` (default no preference), also exposed to GTK CSS as
  `prefers-reduced-motion`. Libadwaita animations follow these. (That libadwaita follows them: unverified.)
  Source: https://docs.gtk.org/gtk4/property.Settings.gtk-enable-animations.html,
  https://docs.gtk.org/gtk4/property.Settings.gtk-interface-reduced-motion.html (read 2026-11-05)

## High contrast

`org.gnome.desktop.a11y.interface high-contrast` (boolean, default false). The shell then loads
its high-contrast stylesheet: borders get stronger and every shadow becomes transparent. So a
surface separated from the wallpaper only by a shadow vanishes; give it a border too.
Source: gsettings-desktop-schemas 50.1 a11y.interface schema:4-10; gnome-shell 50.6
src/st/st-settings.c:35, 151-155; data/theme/gnome-shell-sass/_default-colors.scss:43-50 (read 2026-11-05)

Ship `stylesheet-dark.css` and `stylesheet-light.css`; test both plus high contrast. The GNOME
HIG lists high contrast and large text as standard checks; they are switched on in Settings >
Accessibility or from the GTK Inspector.
Source: https://developer.gnome.org/hig/guidelines/accessibility.html (read 2026-11-05)

## Screen readers (Orca, AT-SPI)

The HIG asks that every element has a short, descriptive accessible name, and that the whole UI
works with a keyboard, a screen reader and the on-screen keyboard.
Quote: "All interface elements should have descriptive, accessible names."
Source: https://developer.gnome.org/hig/guidelines/accessibility.html (read 2026-11-05)

In GJS (St, ATK based):
- `accessible_name` (string) and `accessible_role` (an `Atk.Role`) are properties of every
  Clutter actor, settable in the constructor: `new St.Button({accessible_name: _('Close'),
  accessible_role: Atk.Role.PUSH_BUTTON})`. Role defaults to `Atk.Role.INVALID`.
  Source: mutter 50.6 clutter/clutter/clutter-actor.c:6953-6972 (read 2026-11-05)
- `label_actor` on St.Widget points to a visible St.Label so Orca reads that label's text;
  prefer it over a duplicate string. Source: gnome-shell 50.6 src/st/st-widget.c:989;
  https://gjs.guide/extensions/development/accessibility.html (read 2026-11-05)
- States: `widget.add_accessible_state(Atk.StateType.CHECKED)` / `remove_accessible_state()` for
  toggles; set the role to a check or toggle type so Orca announces on/off.
  Source: https://gjs.guide/extensions/development/accessibility.html (read 2026-11-05)
- Icon-only buttons always need `accessible_name`. Do not put the role or state in the name
  ("Wi-Fi", not "Wi-Fi toggle button on").

In GTK4 apps, widgets carry an accessible role and label; set a label for icon-only buttons
(for example `tooltip-text` plus an accessible label). Exact GTK4 API calls: unverified here.

## Checklist before shipping a surface

1. Text 4.5:1 (7:1 for body text where you can), state and focus 3:1, in light, dark and high contrast.
2. Status never by colour alone.
3. Reachable and operable by keyboard; focus ring visible and never fully covered.
4. Targets 24px minimum, 44px for primary actions.
5. Every interactive actor has a name and role; toggles expose their state.
6. `enable-animations` off removes motion; `reduced-motion = reduce` swaps motion for a fade.
7. Text boxes sized in `em` and grow with text-scaling-factor 1.25 and 1.5.
