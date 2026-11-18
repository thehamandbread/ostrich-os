# Motion

The project's motion style is **Spring**: a surface (menu, pop-out alert card, drawer) grows out
of a small copy of itself at the thing that opened it, over 280 ms with an ease-out-back curve,
about `cubic-bezier(0.34, 1.56, 0.64, 1)`; it leaves in 140 ms with an ease-in, shrinking back
into its source. This file explains why, maps it onto Material 3 and onto Clutter, and sets the
cost rules. The style itself is a project decision (see docs/DESIGN.md), not an external rule.

## Principles

**Every animation has a job.** Motion should explain where something came from, what changed or
that an action worked. If it does none of these, cut it. Apple: "Add motion purposefully,
supporting the experience without overshadowing it."
Source: https://developer.apple.com/design/human-interface-guidelines/motion (read 2026-11-05, via the page's JSON)

**Keep frequent things calm.** Something the user does fifty times a day (hover, opening the
same menu) gets the shortest, plainest motion. Apple: avoid motion on interactions "that occur
frequently". Save the overshoot for moments that appear less often (an alert card arriving).
Source: https://developer.apple.com/design/human-interface-guidelines/motion (read 2026-11-05)

**Origin and continuity.** A surface should visibly come from its source and return to it, so
the user never loses track of it. Spring does this by scaling from the source's position and
size. The shell does the same for notification banners: they start at scale 0.9 with the pivot
at the centre and ease to 1 with EASE_OUT_BACK over 200 ms.
Source: gnome-shell 50.6 js/ui/messageTray.js:17, 1189-1203 (read 2026-11-05)

**Bigger travel, longer time.** Material: "duration should increase as the area/traversal of an
animation increases." A tooltip fades in near the short end; a full-height drawer sits near the
long end.
Source: https://github.com/material-components/material-components-android/blob/master/docs/theming/Motion.md (read 2026-11-05)

**Enter decelerates, exit accelerates.** Things arriving slow down into place; things leaving
speed up and get out of the way. Material assigns decelerate easings to elements that "enter
the screen" and accelerate easings to those that "exit the screen". Exits are shorter than entries.
Source: https://github.com/material-components/material-components-android/blob/master/docs/theming/Motion.md (read 2026-11-05)

**Never block.** Input works during an animation; a second click reverses or cancels it, it
does not queue behind it. Apple: "don't make people wait for an animation to complete before
they can do anything." In Clutter, call `actor.remove_all_transitions()` before starting the
opposite animation, as the shell does before showing a banner.
Source: https://developer.apple.com/design/human-interface-guidelines/motion (read 2026-11-05);
gnome-shell 50.6 js/ui/messageTray.js:1188 (read 2026-11-05)

**Motion is never the only signal.** Whatever the animation tells the user must also be true
in the final still frame. Source: https://developer.apple.com/design/human-interface-guidelines/motion (read 2026-11-05)

**Reduced motion.** With `org.gnome.desktop.interface enable-animations` off, `actor.ease()`
already runs with duration 0. With `org.gnome.desktop.a11y.interface reduced-motion` set to
`reduce`, which the shell itself does not read in 50.6, our code replaces scale and movement with
a plain opacity fade of about 100-150 ms. Details and sources: accessibility.md, "Motion".
Source: gnome-shell 50.6 js/misc/animationUtils.js:23-33 (read 2026-11-05)

## Material 3 duration tokens

Values from Material Web's token file (`md.sys.motion`, version v0_192), which carries the M3
numbers. The m3.material.io pages only render with JavaScript and could not be read directly.
Source: https://github.com/material-components/material-web/blob/main/tokens/versions/v0_192/_md-sys-motion.scss, lines 17-32 (read 2026-11-05)

| Token | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| short | 50 ms | 100 ms | 150 ms | 200 ms |
| medium | 250 ms | 300 ms | 350 ms | 400 ms |
| long | 450 ms | 500 ms | 550 ms | 600 ms |
| extra-long | 700 ms | 800 ms | 900 ms | 1000 ms |

## Material 3 easing tokens

Source: same file, lines 33-52 (read 2026-11-05). "Closest Clutter mode" is my own numeric fit
(largest vertical error over the curve, sampled); for an exact match use a cubic-bezier timeline
(see below).

| Token | cubic-bezier | Use | Closest Clutter mode (max error) |
|---|---|---|---|
| emphasized | (0.2, 0, 0, 1) | M3 default for most transitions | EASE_OUT_CUBIC (0.13) |
| emphasized-decelerate | (0.05, 0.7, 0.1, 1) | Entering, expressive | EASE_OUT_EXPO (0.16) |
| emphasized-accelerate | (0.3, 0, 0.8, 0.15) | Exiting, expressive | EASE_IN_CUBIC (0.05) |
| standard | (0.2, 0, 0, 1) | Utility transitions | EASE_OUT_CUBIC (0.13) |
| standard-decelerate | (0, 0, 0, 1) | Utility entering | EASE_OUT_CIRC (0.03) |
| standard-accelerate | (0.3, 0, 1, 1) | Utility exiting | EASE_IN_SINE (0.08) |
| legacy | (0.4, 0, 0.2, 1) | Older M2 curve | none closer than 0.17; use a bezier |
| legacy-decelerate | (0, 0, 0.2, 1) | | not fitted |
| legacy-accelerate | (0.4, 0, 1, 1) | | not fitted |
| linear | (0, 0, 1, 1) | Progress, colour | LINEAR |

Note the token file gives emphasized and standard the same plain bezier, and has a `path`
token whose value is null ("not supported"), which suggests emphasized is really a path that a
single bezier approximates (unverified; the M3 site could not be read).
Source: same file, lines 33-34, 47-48, 53 (read 2026-11-05)

## Material 3 springs

Material's Android docs give a spring scheme: spatial springs (position, size) are slightly
bouncy, effects springs (opacity, colour) are not.
Source: https://github.com/material-components/material-components-android/blob/master/docs/theming/Motion.md (read 2026-11-05)

| Spring | Damping ratio | Stiffness |
|---|---|---|
| Fast spatial | 0.9 | 1400 |
| Default spatial | 0.9 | 700 |
| Slow spatial | 0.9 | 300 |
| Fast effects | 1 | 3800 |
| Default effects | 1 | 1600 |
| Slow effects | 1 | 800 |

Which named scheme these belong to (standard vs expressive): unverified.

## How Spring maps onto these

- **Enter, 280 ms**: between medium1 (250) and medium2 (300). Right for a mid-size surface
  travelling a short distance. Shell comparison: popup menus 150 ms, banners 200 ms, panel and
  overview 250 ms, quick settings 400 ms.
  Source: gnome-shell 50.6 js/ui/boxpointer.js:14; messageTray.js:17; data/theme/gnome-shell-sass/widgets/_panel.scss:11; js/ui/quickSettings.js:19 (read 2026-11-05)
- **Enter curve**: `cubic-bezier(0.34, 1.56, 0.64, 1)` overshoots to about 1.098 at roughly
  57% of the time, then settles. M3's easing tokens have no overshoot; the M3 equivalent is a
  spatial spring with damping 0.9 (slightly under-damped). Overshoot only on scale/position,
  never on opacity (opacity uses an effects-style curve with no bounce).
- **Exit, 140 ms ease-in**: about short3 (150 ms) with an accelerate curve, matching Material's
  "exit accelerates, exits are shorter" pattern.

Overshoot numbers are my own sampling of the bezier, computed 2026-11-05.

## Clutter in GNOME 50

`Clutter.AnimationMode` members: LINEAR; EASE_IN/OUT/IN_OUT for QUAD, CUBIC, QUART, QUINT, SINE,
EXPO, CIRC, ELASTIC, BACK and BOUNCE; STEPS, STEP_START, STEP_END; CUBIC_BEZIER; EASE, EASE_IN,
EASE_OUT, EASE_IN_OUT; plus CUSTOM_MODE and the ANIMATION_LAST guard.
Source: mutter 50.6 clutter/clutter/clutter-enums.h:65-219;
https://mutter.gnome.org/clutter/enum.AnimationMode.html (read 2026-11-05; that page shows API 52, same list)

- **Spring enter = `Clutter.AnimationMode.EASE_OUT_BACK`.** Clutter's ease-out-back
  (overshoot constant 1.70158) peaks at 1.100 at 58% of the time; the project bezier peaks at
  1.098 at 57%, and both are at 0.82 at 25% and 1.09 at 50%. They are the same curve for design
  purposes. Source: mutter 50.6 clutter/clutter/clutter-easing.c:298-304 (read 2026-11-05); comparison computed 2026-11-05
- **Spring exit = `EASE_IN_QUAD`** (or `EASE_IN` for CSS-standard `cubic-bezier(0.42, 0, 1, 1)`,
  which EASE_IN_SINE matches within 0.02). Source: mutter 50.6 clutter/clutter/clutter-timeline.c:2284-2292 (read 2026-11-05)
- `EASE`, `EASE_IN`, `EASE_OUT`, `EASE_IN_OUT` are the CSS keyword beziers:
  (0.25, 0.1, 0.25, 1), (0.42, 0, 1, 1), (0, 0, 0.58, 1), (0.42, 0, 0.58, 1).
  Source: mutter 50.6 clutter/clutter/clutter-timeline.c:2280-2296 (read 2026-11-05)
- For an exact M3 bezier, build a transition and call
  `timeline.set_cubic_bezier_progress(new Graphene.Point({x: 0.05, y: 0.7}), new Graphene.Point({x: 0.1, y: 1}))`.
  Source: mutter 50.6 clutter/clutter/clutter-timeline.c:2505 (read 2026-11-05).
  Whether `actor.ease({mode: Clutter.AnimationMode.CUBIC_BEZIER})` lets you pass control points: unverified; assume not.
- There is no physics spring in Clutter; EASE_OUT_BACK or a CUSTOM_MODE progress function
  (`timeline.set_progress_func`) are the options. Source: mutter 50.6 clutter/clutter/clutter-timeline.c:2224 (read 2026-11-05)
- GNOME Shell's own motion is almost all EASE_OUT_QUAD (menus, dash, OSD), with EASE_OUT_BACK
  reserved for banners. Source: gnome-shell 50.6 js/ui/boxpointer.js:131, 188; dash.js:125-182; osdWindow.js:76-127; messageTray.js:1202 (read 2026-11-05)

## Cost rules

**Animate only transform and opacity.** In Clutter that means `opacity`, `scale_x/scale_y`,
`translation_x/y` and `pivot_point`. These change how an already-laid-out actor is drawn. Do not
ease `width`, `height`, `x/y` of a laid-out child, margins or padding mid-motion: size and
geometry changes queue a relayout of the actor and its parents on every frame.
Source: gnome-shell 50.6 src/st/st-widget.c:1657-1659 (relayout on geometry change); the
per-frame cost claim is general Clutter behaviour, unverified by measurement here (read 2026-11-05)

**Set the pivot first.** Scale grows from the pivot point (0..1 of the actor's size). For Spring,
set the pivot to the edge or point nearest the source before scaling, as the banner code does
with `set_pivot_point(0.5, 0.5)`. Source: gnome-shell 50.6 js/ui/messageTray.js:1194 (read 2026-11-05)

**Fade groups through an offscreen buffer.** Fading a container with overlapping children shows
the children through each other. `Clutter.OffscreenRedirect.AUTOMATIC_FOR_OPACITY` renders the
actor to a texture only while it is partly transparent; `ALWAYS` keeps a texture (the shell uses
it for modal dialogs and the panel). Use AUTOMATIC_FOR_OPACITY for cards and menus.
Source: mutter 50.6 clutter/clutter/clutter-enums.h:397-413; gnome-shell 50.6 js/ui/dialog.js:42,
panel.js:438, windowPreview.js:60 (read 2026-11-05)

**CSS transitions are already cheap but limited.** `transition-duration` cross-fades two
offscreen paints of the background and border, fixed at EASE_IN_OUT_QUAD. Fine for hover and
`:checked`; it cannot move or scale. Source: gnome-shell 50.6 src/st/st-theme-node-transition.c:44-55, 110 (read 2026-11-05)

**No re-blur or re-layout mid-motion.** Set blur strength, text, icons and size before the
animation starts, then animate only transform and opacity. Do not change a blur effect's radius
per frame. (The exact per-frame cost of shell blur effects: unverified.)

**Respect the global speed.** Use `actor.ease()` for anything you animate, so the slow-down
factor and `enable-animations` apply automatically.
Source: gnome-shell 50.6 js/ui/environment.js:219-231; js/misc/animationUtils.js:23-33 (read 2026-11-05)
