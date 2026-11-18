# GNOME HIG: rules for Ubuntu Ostrich

Distilled from the GNOME Human Interface Guidelines (https://developer.gnome.org/hig/), all pages read 2026-11-05. Rules are paraphrased; short quotes are marked. When a rule here conflicts with the live HIG, the live HIG wins. Abbreviation: HIG = https://developer.gnome.org/hig

## Principles

- Design for people: be inclusive of different physical abilities, cultures and device form factors, and require little specialist knowledge.
  Source: https://developer.gnome.org/hig/principles.html (read 2026-11-05)
- Make it simple: "The best apps do one thing and do it well." Focus on one situation and one type of experience; don't try to suit everyone.
  Source: https://developer.gnome.org/hig/principles.html (read 2026-11-05)
- Don't show too many elements at once; use progressive disclosure and navigation to guide. Keep frequent actions close at hand and less important ones further away.
  Source: https://developer.gnome.org/hig/principles.html (read 2026-11-05)
- Reduce user effort: if something can be done automatically, do it; minimise steps; reduce what people must remember (tabs, recent lists, suggestions); keep text short.
  Source: https://developer.gnome.org/hig/principles.html (read 2026-11-05)
- Be considerate: anticipate and prevent mistakes, let destructive actions be undone instead of asking for confirmation, and don't interrupt or distract unnecessarily.
  Source: https://developer.gnome.org/hig/principles.html (read 2026-11-05)

## Layout, sizing and styling

- Support windows down to 1024×600px (smallest recommended desktop display); apps suited to phones should scale down to 360×294px.
  Source: https://developer.gnome.org/hig/guidelines/adaptive.html (read 2026-11-05)
- Design from the most constrained size and input up. Avoid splitting windows into many small panes; they are hard to make adaptive. Prefer list patterns, which scale to narrow and wide widths.
  Source: https://developer.gnome.org/hig/guidelines/adaptive.html (read 2026-11-05)
- Every container's width should feel right at any window width; sidebars must never look excessively wide or narrow next to the main area. At large sizes put content in max-width containers (visible lists or invisible clamps) so lines and controls don't spread apart.
  Source: https://developer.gnome.org/hig/guidelines/adaptive.html (read 2026-11-05)
- Use breakpoints to switch layouts (for example a utility pane becomes a bottom panel). Resizing must be smooth: widgets must not jump or vanish without animation.
  Source: https://developer.gnome.org/hig/guidelines/adaptive.html (read 2026-11-05)
- Use the system font (Adwaita Sans in GNOME). Don't hard-code font sizes or styles; use the standard style classes (body, heading, caption, caption-heading, large-title, title-1 to title-4) or relative sizes.
  Source: https://developer.gnome.org/hig/guidelines/typography.html (read 2026-11-05)
- Minimise the number of font sizes and weights. Use smaller/lighter text for less important information, heavier/darker for important. Avoid italics and all caps. large-title only with lots of white space.
  Source: https://developer.gnome.org/hig/guidelines/typography.html (read 2026-11-05)
- Never put text over graphical backgrounds or textures; it reduces contrast.
  Source: https://developer.gnome.org/hig/guidelines/typography.html (read 2026-11-05)
- Use proper Unicode: “curly quotes”, × for dimensions (1024×768), … (U+2026), ’ apostrophe, • bullets, – en dash for ranges, and a narrow no-break space (U+202F) between number and unit (32 GB).
  Source: https://developer.gnome.org/hig/guidelines/typography.html (read 2026-11-05)
- Default to the light style and follow the system dark preference; dark-by-default is mainly for image/video apps. A per-app style choice, if offered, has three options: light, dark, follow system.
  Source: https://developer.gnome.org/hig/guidelines/ui-styling.html (read 2026-11-05)
- Keep custom styling minimal. Build on libadwaita style classes and color variables (they adapt to light, dark and high contrast) and don't use them outside their intended purpose.
  Source: https://developer.gnome.org/hig/guidelines/ui-styling.html (read 2026-11-05)
- Never use color as the only carrier of information (add shape, position or text), and never use flashing or blinking elements.
  Source: https://developer.gnome.org/hig/guidelines/ui-styling.html (read 2026-11-05)
- The GNOME palette (Blue/Green/Yellow/Orange/Red/Purple/Brown 1–5, Light 1–5, Dark 1–5; e.g. Blue 3 #3584e4) is meant for app icons and illustrations, not for UI chrome.
  Source: https://developer.gnome.org/hig/reference/palette.html (read 2026-11-05)
- Note: the HIG pages read give no pixel values for margins, padding or row heights. Take those from libadwaita's widgets and style classes rather than inventing them.
  Source: https://developer.gnome.org/hig/guidelines/ui-styling.html (read 2026-11-05)

## Navigation and sidebars

- Prefer showing views inside the existing window over opening new windows, especially for core content.
  Source: https://developer.gnome.org/hig/guidelines/navigation.html (read 2026-11-05)
- Flat navigation: a view switcher for a few equal pages; a sidebar when there are too many for a view switcher. Hierarchical navigation: a parent list or grid links to sub-views, reached by browsing.
  Source: https://developer.gnome.org/hig/guidelines/navigation.html (read 2026-11-05)
- Keep each view focused and not overpacked. Avoid deep hierarchies: generally only one level of depth. Don't combine navigation types in non-standard ways.
  Source: https://developer.gnome.org/hig/guidelines/navigation.html (read 2026-11-05)
- View switchers hold 3 to 5 views, labelled with nouns in header capitalization (Albums, Updates) of similar length. In preferences, controls in one view must not affect controls in another. Move the switcher to the bottom edge when the window is too narrow (AdwViewSwitcherBar).
  Source: https://developer.gnome.org/hig/patterns/nav/view-switchers.html (read 2026-11-05)
- Use a sidebar for more views than a view switcher fits, for dynamic locations, or for frequent back-and-forth. Avoid sidebars in rich or immersive content apps.
  Source: https://developer.gnome.org/hig/patterns/nav/sidebars.html (read 2026-11-05)
- Order the sidebar by what is most useful (recently updated first for dynamic lists). Header bar controls that affect the sidebar list go above that list. Rows may have multiple lines and images but must stay clean. Widget: AdwNavigationSplitView.
  Source: https://developer.gnome.org/hig/patterns/nav/sidebars.html (read 2026-11-05)
- Sidebar locations and view switchers are exceptions where an icon and a label are used together.
  Source: https://developer.gnome.org/hig/guidelines/ui-icons.html (read 2026-11-05)
- Browsing: the back button sits top-left (in left-to-right locales); the header bar title, controls and menu update with the current view. Widget: AdwNavigationView.
  Source: https://developer.gnome.org/hig/patterns/nav/browsing.html (read 2026-11-05)
- Utility panes (not sidebars) hold tools or info relevant to the main view: left if it affects the main view, right if subordinate. They do not intersect the header bar, should overlap the main view when narrow (AdwOverlaySplitView), and toggle with F9.
  Source: https://developer.gnome.org/hig/patterns/containers/utility-panes.html (read 2026-11-05)

## Header bars

- Start: main action buttons (new, add, open, back). Center: window title or a view switcher. End: menus. Keep only a few controls, update them with the view, and always leave empty space for dragging.
  Source: https://developer.gnome.org/hig/patterns/containers/header-bars.html (read 2026-11-05)
- Header bar buttons should be flat (no background or border). Avoid label-only, suggested/destructive and linked buttons in primary-window header bars; add icons and group with spacer separators or split buttons instead. Action dialogs may keep label-only buttons.
  Source: https://developer.gnome.org/hig/patterns/containers/header-bars.html (read 2026-11-05)
- Every control in a primary window's header bar has a tooltip.
  Source: https://developer.gnome.org/hig/patterns/containers/header-bars.html (read 2026-11-05)

## Lists and rows

- Boxed lists suit small, static lists of controls or information (preferences, recent documents); use list views for large or dynamic lists. Order them semantically, like menus; use several lists with headings as sections.
  Source: https://developer.gnome.org/hig/patterns/containers/boxed-lists.html (read 2026-11-05)
- A row that links to another view ends with a go-next-symbolic arrow.
  Source: https://developer.gnome.org/hig/patterns/containers/boxed-lists.html (read 2026-11-05)
- A row with controls has usually one, at most two. Clicking the row background triggers the control; the controls are focusable but the row is not.
  Source: https://developer.gnome.org/hig/patterns/containers/boxed-lists.html (read 2026-11-05)
- Differentiate multiple text elements in a row by size, weight and color; row icons should be symbolic. Lists need a minimum and a maximum width.
  Source: https://developer.gnome.org/hig/patterns/containers/boxed-lists.html (read 2026-11-05)
- Use the predefined rows before inventing: switch, action, combo, entry, spin, property, expander and button rows.
  Source: https://developer.gnome.org/hig/patterns/containers/boxed-lists.html (read 2026-11-05)
- Editable lists: an add button at the top or an add button row at the end; a remove button at the end of each row. If reordering: drag handles at the start and a per-row menu with Move Up, Move Down and Remove (the move items are required for accessibility).
  Source: https://developer.gnome.org/hig/patterns/containers/boxed-lists.html (read 2026-11-05)
- List actions: a pill button for a single action that needs separation from the content; otherwise button rows. Button rows follow button label rules, but a row that opens a new view uses a trailing right arrow instead of an ellipsis.
  Source: https://developer.gnome.org/hig/patterns/containers/boxed-lists.html (read 2026-11-05)
- Empty views get a placeholder page (AdwStatusPage): an image, a heading stating the empty state ("Empty Folder"), optional guidance text, optional action (a suggested button is acceptable here). Illustrated placeholders only for an unavoidable first-run empty main view; symbolic ones elsewhere (empty folders, no search results), subtle and neutral.
  Source: https://developer.gnome.org/hig/patterns/feedback/placeholders.html (read 2026-11-05)
- Selection mode only for large collections with at least three bulk actions: hover check box per item, header bar shows Cancel and the selected count, actions in a bottom action bar. Edit mode for a distinct editing task with two or three per-item actions, entered with an Edit button and left with Done.
  Source: https://developer.gnome.org/hig/patterns/containers/selection-mode.html (read 2026-11-05)

## Buttons, switches and main actions

- Outside header bars a button has an icon or a label, not both. Use at most one or two button widths per window; adjacent buttons share a width.
  Source: https://developer.gnome.org/hig/patterns/controls/buttons.html (read 2026-11-05)
- Labels are short imperative verbs in header capitalization (Save, Update); allow for translation growth. No double-click or right-click actions on buttons. Make invalid buttons insensitive rather than erroring on click.
  Source: https://developer.gnome.org/hig/patterns/controls/buttons.html (read 2026-11-05)
- Suggested action (affirmative, next step) and destructive action (warns of damage) are strong colors. "Each view should only ever include a single button using either the suggested or destructive styles."
  Source: https://developer.gnome.org/hig/patterns/controls/buttons.html (read 2026-11-05)
- Pill shape for a text button in open space that is the view's primary action; circular for many small buttons close together. Toggle buttons for clearly binary modes when space is tight; linked toggles for a short set of options in a row or header bar.
  Source: https://developer.gnome.org/hig/patterns/controls/buttons.html (read 2026-11-05)
- Switches are for clear on/off features, settings or hardware and are preferred over check boxes. If the label can't explain both states, use radio buttons.
  Source: https://developer.gnome.org/hig/patterns/controls/switches.html (read 2026-11-05)
- Label switches with nouns in header capitalization (Automatic Location) and give the label an access key. A switch's active color can lag its position to show a feature still coming online; make it insensitive when the feature is unavailable.
  Source: https://developer.gnome.org/hig/patterns/controls/switches.html (read 2026-11-05)
- Destructive actions need either undo (usually a toast) or a confirmation; undo is preferred because people click through confirmations. Confirm only when undo is impossible.
  Source: https://developer.gnome.org/hig/patterns/feedback/dialogs.html (read 2026-11-05)
- Dialogs: only in direct response to a user action, always modal to a parent, initial focus on the expected first control. Alert dialogs have 1 to 3 buttons. Cancel comes before the affirmative button; the affirmative label is a specific verb (Save, Print), never OK or Done.
  Source: https://developer.gnome.org/hig/patterns/feedback/dialogs.html (read 2026-11-05)
- Return activates the affirmative button unless it is irreversible or destructive; Esc activates cancel. Keep the affirmative button insensitive until required options are chosen. Prefer inline controls and toasts over action and error dialogs.
  Source: https://developer.gnome.org/hig/patterns/feedback/dialogs.html (read 2026-11-05)

## Menus and popovers

- Menu items: verbs for commands, adjectives for settings, header capitalization, an access key for each (unique within the menu). Use check/radio items for settings, not label-swapping items.
  Source: https://developer.gnome.org/hig/patterns/controls/menus.html (read 2026-11-05)
- Menus hold 3 to 12 items; submenus 3 to 6. Never nest submenus. Put important items at the top or bottom; group similar items; don't mix actions, check and radio items in one group.
  Source: https://developer.gnome.org/hig/patterns/controls/menus.html (read 2026-11-05)
- The primary menu uses open-menu-symbolic at the header bar end (above the sidebar list when there is a sidebar; only on the top-level view with hierarchical navigation). Its tooltip and accessible name are "Main Menu".
  Source: https://developer.gnome.org/hig/patterns/controls/menus.html (read 2026-11-05)
- The primary menu ends with a group of Preferences, Keyboard Shortcuts, Help and About <App Name> (About is mandatory). No Close or Quit items.
  Source: https://developer.gnome.org/hig/patterns/controls/menus.html (read 2026-11-05)
- Secondary menus hold actions for the current view or item, are optional, and don't repeat Preferences or About.
  Source: https://developer.gnome.org/hig/patterns/controls/menus.html (read 2026-11-05)
- Secondary click opens a context menu only when there is a relevant set of items; it must not hold alternative actions like delete, and must be reachable by keyboard (Menu or Shift+F10).
  Source: https://developer.gnome.org/hig/guidelines/pointer-touch.html (read 2026-11-05)
- Popovers are attached to a button, small (rule of thumb: no more than a third of the parent window) and simple. Don't mix many control types; group like with like; add a heading if the purpose is unclear; no Close/Done button; Esc closes.
  Source: https://developer.gnome.org/hig/patterns/containers/popovers.html (read 2026-11-05)

## Notifications, toasts and tooltips

- Notifications are for events relevant while the user is elsewhere (download finished, message received). If it only matters inside the app, use a toast.
  Source: https://developer.gnome.org/hig/patterns/feedback/notifications.html (read 2026-11-05)
- Question every notification. For high-volume apps, rate-limit or summarise and offer a way to reduce or disable them. Withdraw notifications that are no longer valid. Never rely on them alone; the app window must show the same information.
  Source: https://developer.gnome.org/hig/patterns/feedback/notifications.html (read 2026-11-05)
- Notification parts: app icon; a title in header capitalization that is understandable alone; an optional one-sentence body in sentence capitalization; a default action (click) that dismisses it and shows the relevant app view; up to three action buttons.
  Source: https://developer.gnome.org/hig/patterns/feedback/notifications.html (read 2026-11-05)
- Notification actions only for frequently needed, related actions that also exist in the app; never duplicate the default action (no "Open" button).
  Source: https://developer.gnome.org/hig/patterns/feedback/notifications.html (read 2026-11-05)
- Toasts are transient, dismissible in-window messages for single events (often Undo after a destructive action). Ongoing states use banners instead. Short title in the informal heading style; a button only when directly relevant; bottom-centred in the window.
  Source: https://developer.gnome.org/hig/patterns/feedback/toasts.html (read 2026-11-05)
- Tooltips: required on primary-window header bar controls, otherwise use sparingly and never for essential information. If one control in a container has a tooltip, all its siblings do.
  Source: https://developer.gnome.org/hig/patterns/feedback/tooltips.html (read 2026-11-05)
- Tooltip text is short, header capitalized, a noun phrase rather than an instruction ("Grid View", not "Switch to grid view"); don't repeat a visible label. Standard ones: Back, Search, Main Menu, Menu (or "Document Menu"), New Tab, Bookmarks.
  Source: https://developer.gnome.org/hig/patterns/feedback/tooltips.html (read 2026-11-05)

## Search

- Offer search whenever there are more text-bearing items than fit easily, but don't make it the only way to find things. Search filters; find highlights in place.
  Source: https://developer.gnome.org/hig/patterns/nav/search.html (read 2026-11-05)
- Standard: a search bar sliding down below the header bar, hidden until activated by type-to-search, Ctrl+F, or a toggling search button in the header bar. Keep it permanently visible only if search is central.
  Source: https://developer.gnome.org/hig/patterns/nav/search.html (read 2026-11-05)
- Results are live, fast and incremental; show a "No results" message in the content view when empty; most relevant first.
  Source: https://developer.gnome.org/hig/patterns/nav/search.html (read 2026-11-05)
- Search globally across views, tolerate typos (fuzzy matching, suggestions), and match related terms (a city list matching country or region).
  Source: https://developer.gnome.org/hig/patterns/nav/search.html (read 2026-11-05)

## Writing style

- Fewest words that keep the meaning; a clear three-word label beats an ambiguous one-word label. Neutral tone; avoid "you" and "my", but prefer "your" when ownership is needed.
  Source: https://developer.gnome.org/hig/guidelines/writing-style.html (read 2026-11-05)
- Use the user's terms, not system internals, and GNOME's standard UI terms ("pointer", "window"). Don't build sentences across several controls; avoid "e.g."/"i.e." (write "for example").
  Source: https://developer.gnome.org/hig/guidelines/writing-style.html (read 2026-11-05)
- Header capitalization for headings, header bar titles, tabs, buttons, switch labels, menu items and tooltips: capitalize words of 4+ letters, verbs and nouns of any length, first and last words, and hyphenated parts ("Find and Replace").
  Source: https://developer.gnome.org/hig/guidelines/writing-style.html (read 2026-11-05)
- Sentence capitalization for check boxes, radio buttons, sliders, entries, field and combo labels, and body text in dialogs and notifications.
  Source: https://developer.gnome.org/hig/guidelines/writing-style.html (read 2026-11-05)
- Headings drop auxiliary verbs and articles ("Three Documents Updated"). An informal heading may be a full sentence in sentence case, still bold ("File has changed on disk").
  Source: https://developer.gnome.org/hig/guidelines/writing-style.html (read 2026-11-05)
- End a label with … only when more input or confirmation follows (Save As…, Delete…), not for Preferences or Properties. Generally no trailing periods, even on full sentences, except to split multiple sentences or in long text.
  Source: https://developer.gnome.org/hig/guidelines/writing-style.html (read 2026-11-05)
- Never mention specific devices or buttons in UI text (no "move the mouse").
  Source: https://developer.gnome.org/hig/guidelines/pointer-touch.html (read 2026-11-05)

## Accessibility, pointer and keyboard

- Every element needs a short, descriptive accessible name; override GTK defaults with app-specific names where useful.
  Source: https://developer.gnome.org/hig/guidelines/accessibility.html (read 2026-11-05)
- Test with high contrast, large text, keyboard only, the screen reader (usable with the display off?) and the on-screen keyboard.
  Source: https://developer.gnome.org/hig/guidelines/accessibility.html (read 2026-11-05)
- Click targets must be comfortably large for any pointing device and low precision. Avoid double-click and chording; don't rely on hover to reveal actions or essential information; don't depend on buttons only some devices have (including middle click).
  Source: https://developer.gnome.org/hig/guidelines/pointer-touch.html (read 2026-11-05)
- Esc cancels a pointer operation in progress (drag and drop, drawing). Three- and four-finger gestures and top/bottom screen-edge drags are reserved for the system.
  Source: https://developer.gnome.org/hig/guidelines/pointer-touch.html (read 2026-11-05)
- Scrolling views: wheel/two-finger drag scroll, Ctrl+wheel or pinch zoom. Panning views: click+drag pans, wheel zooms.
  Source: https://developer.gnome.org/hig/guidelines/pointer-touch.html (read 2026-11-05)
- Everything doable with a pointer must be doable with the keyboard, drag and drop included.
  Source: https://developer.gnome.org/hig/guidelines/keyboard.html (read 2026-11-05)
- Use standard GNOME shortcuts; add shortcuts only for common actions, as mnemonic Ctrl+letter, with Shift+Ctrl+letter to reverse/extend (Ctrl+Z / Shift+Ctrl+Z). Apps must not use Alt (access keys) or Super (system) for shortcuts; avoid awkward two-hand reaches.
  Source: https://developer.gnome.org/hig/guidelines/keyboard.html (read 2026-11-05)
- Give labelled controls access keys (Alt+underlined letter): first letter or a memorable consonant, avoid thin letters (i, l) and descenders (g, y), vowels last. A label must directly precede its control in focus order.
  Source: https://developer.gnome.org/hig/guidelines/keyboard.html (read 2026-11-05)
- Standard keys must work in custom UI: Tab/Shift+Tab move focus (Ctrl+Tab where Tab is taken), Return activates, Space toggles, F10 opens the primary/secondary menu, Menu or Shift+F10 the context menu, Esc closes transient containers (menus, popovers, dialogs). Arrow keys move directionally where possible.
  Source: https://developer.gnome.org/hig/guidelines/keyboard.html (read 2026-11-05)

## Icons

- UI icons are symbolic: monochrome, drawn at 16×16px, usable at 32, 64 and 128px only (other sizes render fuzzy), recolored programmatically. Full-color icons are for app icons and large focal items like files.
  Source: https://developer.gnome.org/hig/guidelines/ui-icons.html (read 2026-11-05)
- Reuse icons from GTK and the Icon Library before drawing new ones. Use an icon instead of a label only if users will recognise it (search, menu, back, forward, share); some icons (stop, remove) only read as part of a set.
  Source: https://developer.gnome.org/hig/guidelines/ui-icons.html (read 2026-11-05)
- Drawing symbolics: 16×16px nominal with margin, orthogonal (no perspective), 2px main strokes (avoid 1px), pixel-grid aligned, one property per metaphor, negative space that survives inverted colors.
  Source: https://developer.gnome.org/hig/guidelines/ui-icons.html (read 2026-11-05)
- App icons: unique per app, a simple metaphor tied to the name (no mascots or style-dependent logos), drawn in a 128×128px area without filling it, on the template baseline, with a darker "front" profile usually no taller than 4 nominal pixels. Use App Icon Preview.
  Source: https://developer.gnome.org/hig/guidelines/app-icons.html (read 2026-11-05)

## What the HIG doesn't cover (look elsewhere)

- GNOME Shell surfaces: top bar indicators, quick-settings tiles, the dash/dock, Shell popup menus, the overview and Shell notification banners as drawn by extensions. The HIG is about apps; use GNOME Shell's own source/CSS (gnome-shell-extensions, js/ui) and gjs.guide for these.
- Motion and animation timing: the HIG only says resizing must be smooth and nothing should flash. Durations and easing come from libadwaita (AdwAnimation, spring animations) and Shell's own code.
- Concrete spacing, padding, corner radii and row heights: not given in the pages read; use libadwaita's widgets, style classes and CSS variables.
- Contrast ratios: the HIG asks for high-contrast testing but gives no numeric ratio; use WCAG (4.5:1 for text) as this project already does.
- Banners, progress bars, spinners, text fields, drop-downs, sliders, tabs, grid and column views, windows: exist in the HIG patterns index but were not condensed here. Read them at HIG/patterns/... when needed.
- Pages that 404'd at the guessed URLs: HIG/patterns/controls/selection-mode.html (the real page is HIG/patterns/containers/selection-mode.html, read) and HIG/resources/icons.html (icons are covered by guidelines/ui-icons and app-icons, read).
