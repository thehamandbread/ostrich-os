# libadwaita reference (GNOME 50 / Ubuntu 26.04)

Target version: **libadwaita 1.9** (Ubuntu 26.04 "resolute" ships `libadwaita-1-0` 1.9.0, with 1.9.1 in updates).
Source: https://packages.ubuntu.com/km/resolute/libadwaita-1-0 (read 2026-11-05)

All doc links below are the 1.9 docs (pages report library version 1.9.4). Rust names follow the
C names: `adw::SwitchRow`, `set_active()`, property `"active"`, and so on. If a property is not
listed here, check the docs before you use it. Never guess an API.

Base URL: `https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/`

---

## 1. Which widget for which job

| Need | Widget | Key properties / methods |
|---|---|---|
| Settings window with a sidebar and pages | `AdwNavigationSplitView` with two `AdwNavigationPage` children | `sidebar`, `content`, `collapsed`, `show-content`, `min-sidebar-width`, `max-sidebar-width`, `sidebar-width-fraction` |
| Header bar and scroll shadow for a page | `AdwToolbarView` | `content`, `add_top_bar()`, `add_bottom_bar()`, `top-bar-style`, `reveal-top-bars` |
| A scrolling page of settings groups | `AdwPreferencesPage` | `title`, `icon-name`, `description`, `banner`, `add()`, `scroll_to_top()` |
| A titled group of rows | `AdwPreferencesGroup` | `title`, `description`, `header-suffix`, `separate-rows`, `add()`, `bind_model()` |
| On/off setting | `AdwSwitchRow` | `active` (watch `notify::active`) |
| Pick one of N | `AdwComboRow` | `model` (a `GtkStringList`), `selected`, `selected-item`, `use-subtitle`, `enable-search` |
| Number setting | `AdwSpinRow` | `adjustment`, `value`, `digits`, `climb-rate`, `numeric`, `snap-to-ticks`, `wrap`; `new_with_range()` |
| Text setting | `AdwEntryRow` | `show-apply-button`, `input-purpose`, `max-length`; signals `apply`, `entry-activated` |
| Secret text | `AdwPasswordEntryRow` | as `AdwEntryRow` |
| Row with a button, or a row that opens a subpage | `AdwActionRow` | `subtitle`, `activatable-widget`, `add_prefix()`, `add_suffix()`, signal `activated` |
| Row that acts as a button at the end of a list | `AdwButtonRow` | |
| Optional sub-settings behind one row | `AdwExpanderRow` | `expanded`, `enable-expansion`, `show-enable-switch`, `add_row()` |
| Read-only value (version, path) | `AdwActionRow` + `.property` | |
| Empty state, error page, "nothing found" | `AdwStatusPage` | `icon-name`, `paintable`, `title`, `description`, `child` |
| Short "done" / "undo" message | `AdwToast` in an `AdwToastOverlay` | `title`, `button-label`, `action-name`, `timeout`, `priority` |
| Persistent state (offline, needs restart) | `AdwBanner` | `title`, `button-label`, `revealed`, `button-style` |
| Confirm a question or destructive action | `AdwAlertDialog` | `heading`, `body`, `default-response`, `close-response`, `add_response()`, `set_response_appearance()`, `choose()` |
| About | `AdwAboutDialog` | `application-name`, `application-icon`, `developer-name`, `version`, `website`, `issue-url`, `license-type`; `new_from_appdata()` |
| Limit the width of content on wide windows | `AdwClamp` (or `AdwClampScrollable`) | |
| Grid of cards that wraps (app store) | `AdwWrapBox` | `line-spacing`, `child-spacing` |

Rules:

- For a sidebar + pages app, use `AdwNavigationSplitView`. Both children must be `AdwNavigationPage`. In UI XML the sidebar child takes `type="sidebar"`. The default sidebar width is 25%, between 180sp and 280sp.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.NavigationSplitView.html (read 2026-11-05)
- Put an `AdwHeaderBar` inside each pane's `AdwToolbarView`. The split view hides the window buttons in the middle by itself, and shows a back button when collapsed.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.NavigationSplitView.html (read 2026-11-05)
- Use `AdwToolbarView` for bars rather than a `GtkBox`. It handles the shadow when content scrolls. `top-bar-style` takes `ADW_TOOLBAR_FLAT` (the default; "shadow only for scrolled content"), `ADW_TOOLBAR_RAISED` or `ADW_TOOLBAR_RAISED_BORDER`.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.ToolbarView.html and https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/enum.ToolbarStyle.html (read 2026-11-05)
- Its `banner` property (since 1.7) puts an `AdwBanner` at the top.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.PreferencesPage.html (read 2026-11-05)
- A child added to `AdwPreferencesGroup` that is an `AdwPreferencesRow` goes into the boxed list. Any other widget goes below the list. Use `header-suffix` for a button next to the group title, such as "Add" or "Reset".
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.PreferencesGroup.html (read 2026-11-05)
- For on/off, use `AdwSwitchRow`, not an `AdwActionRow` with a hand-added `GtkSwitch`. Activating the row "will invert its active state".
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.SwitchRow.html (read 2026-11-05)
- For `AdwComboRow`, give it a `GtkStringList` as `model` and read `selected`. Set `enable-search` when the list is long.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.ComboRow.html (read 2026-11-05)
- Put buttons on an `AdwActionRow` with `add_suffix()`. To make the whole row clickable, set `activatable-widget` to that button, or connect to `activated`. The row is not activatable by default.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.ActionRow.html (read 2026-11-05)
- Do not use `AdwActionRow:icon-name`, which is deprecated since 1.3. Add a `GtkImage` with `add_prefix()` instead.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.ActionRow.html (read 2026-11-05)
- Use `AdwEntryRow` with `show-apply-button` when saving a value is expensive, such as a network call. Do the work in the `apply` signal.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.EntryRow.html (read 2026-11-05)
- Use `AdwExpanderRow` with `show-enable-switch` for a feature that has sub-options only while it is on.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.ExpanderRow.html (read 2026-11-05)
- Use `AdwStatusPage` for empty and error states. Add `.compact` when it sits in a sidebar or popover.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.StatusPage.html (read 2026-11-05)
- For About, use `AdwAboutDialog`, ideally built with `new_from_appdata()` from the app's metainfo. Every part is optional. Keep the copyright to one or two lines.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.AboutDialog.html (read 2026-11-05)
- Do not use `AdwPreferencesWindow`, which is deprecated since 1.6. Use `AdwPreferencesDialog` for a preferences dialog. A full Settings app uses its own window with a split view.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.PreferencesWindow.html (read 2026-11-05)

## 2. Boxed lists

- Outside a preferences group, build a list as a `GtkListBox` with `selection-mode` set to `none` and add `.boxed-list`. Use `.boxed-list-separate` to put each row on its own card. `GtkListView` does not work as a boxed list.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/boxed-lists.html (read 2026-11-05)
- Inside `AdwPreferencesGroup` you get the boxed list for free. Set `separate-rows` (since 1.6) for separate cards.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/boxed-lists.html (read 2026-11-05)
- Put a boxed list in an `AdwClamp` so it does not stretch across a wide window.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/adaptive-layouts.html (read 2026-11-05)

## 3. Style classes that matter

Add them with `widget.add_css_class("name")` or `<style><class name="..."/></style>`.

| Class | Use it for |
|---|---|
| `suggested-action` | The one primary or confirm button in a view or dialog. Keep it to one per view (our convention). |
| `destructive-action` | A button whose action can lose data (Remove, Uninstall, Reset). |
| `flat` | A button that looks like a label or icon until hovered. Use it for suffix buttons in rows. |
| `raised` | Keeps a button in a toolbar looking non-flat. |
| `circular` | An icon-only (or 1–2 character) round button. |
| `pill` | A large standalone button, such as the call to action in an `AdwStatusPage`. |
| `linked` | Joins the children of a box with no spacing into one group. |
| `toolbar` | A horizontal box used as a toolbar, so its buttons go flat. |
| `card` (+ `activatable`) | A card look for any widget, such as app tiles in a store. Add `activatable` for hover and pressed states. |
| `boxed-list`, `boxed-list-separate` | A `GtkListBox` shown as a card list. |
| `navigation-sidebar` | A sidebar list with rounded items and neutral selection. |
| `title-1` … `title-4` | Title sizes for hierarchy. Bigger views take bigger titles. |
| `heading` | A heading at normal text size, such as a list label. |
| `body` | Wrapping descriptive text, such as a dialog body. Avoid it on text that does not wrap. |
| `caption`, `caption-heading` | Smaller supporting text. |
| `document` | Larger, more readable text for main content (since 1.8). |
| `dimmed` | Secondary or de-emphasized text. Replaces `dim-label`, deprecated since 1.7. |
| `numeric` | Tabular figures for numbers that change or line up (dB, Hz, percentages). |
| `monospace` | Code, logs, shell commands. |
| `accent`, `success`, `warning`, `error` | Colour a label or icon. `success`/`warning`/`error` also mark validation on a `GtkEntry`. |
| `property` | An `AdwActionRow`/`AdwExpanderRow` that shows a read-only value; the subtitle is emphasised. |
| `osd` | A dark see-through overlay (with `circular`/`pill` for overlay buttons, with `toolbar` for floating controls). |
| `compact` | A smaller `AdwStatusPage`. |
| `devel` | Striped header bars on a dev or nightly build window. |
| `inline` | A `GtkSearchBar`, `AdwTabBar` or `GtkTextView` with a neutral background inside other content. |
| `lowres-icon`, `icon-dropshadow` | Shadows for app icons up to 32px and over 32px. |

Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/style-classes.html (read 2026-11-05)

Deprecated, do not use: `dim-label` (use `dimmed`), `large-title` (use `title-1`), `content` (use `boxed-list`), `sidebar` (use `navigation-sidebar`), `app-notification` (use `AdwToastOverlay`), `opaque` (use `suggested-action` and override accent variables), `flat` on header bars (use `AdwToolbarView`).
Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/style-classes.html (read 2026-11-05)

## 4. Colours and CSS variables

libadwaita 1.9 uses CSS custom properties: `var(--name)`.

- Never hard-code a colour in CSS or drawing code. Use the variables, or a style class such as `accent` or `error`, so light, dark, high contrast and the user's accent all work.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/styles-and-appearance.html (read 2026-11-05)
- Do not use GTK3 names such as `@theme_bg_color`. They ignore overridden variables.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/css-variables.html (read 2026-11-05)
- Use each `-bg-color` with its matching `-fg-color` on the same element.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/css-variables.html (read 2026-11-05)
- Accent: `--accent-bg-color` and `--accent-fg-color` fill backgrounds. `--accent-color` is for coloured text or icons on a neutral background, because it has better contrast.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/css-variables.html (read 2026-11-05)
- Use accent sparingly. Keep it off large surfaces and off many items in one view.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/css-variables.html (read 2026-11-05)
- Status colours come in the same three-part sets: `--destructive-*`, `--success-*`, `--warning-*`, `--error-*` (`-bg-color`, `-fg-color`, `-color`).
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/css-variables.html (read 2026-11-05)
- Surfaces: `--window-bg-color`/`--window-fg-color`, `--view-*`, `--headerbar-*` (also `-border-color`, `-backdrop-color`, `-shade-color`), `--sidebar-*`, `--secondary-sidebar-*`, `--card-bg-color`/`--card-fg-color`/`--card-shade-color`, `--dialog-*`, `--popover-*`, `--thumbnail-*`, `--overview-*`, `--active-toggle-*`. Use these for custom widgets so they match the built-in ones.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/css-variables.html (read 2026-11-05)
- Helpers you must not override: `--border-color`, `--border-opacity`, `--dim-opacity`, `--disabled-opacity`, `--window-radius`. They already handle high contrast.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/css-variables.html (read 2026-11-05)
- Fonts: `--document-font-family` with `--document-font-size`, and `--monospace-font-family` with `--monospace-font-size`. Use each family with its size.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/css-variables.html (read 2026-11-05)
- The GNOME palette is `--blue-1`…`--blue-5`, plus green, yellow, orange, red, purple, brown, light and dark. The accent choices are `--accent-blue`, `--accent-teal`, `--accent-green`, `--accent-yellow`, `--accent-orange`, `--accent-red`, `--accent-pink`, `--accent-purple` and `--accent-slate`. Use the palette for illustrations and charts (EQ curves), not for UI chrome.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/css-variables.html (read 2026-11-05)
- Theming an app: apps follow the system accent by default. To brand an app, set `--accent-bg-color` on `:root`. If the new accent is light, also set a dark `--accent-fg-color`. To override for one widget, also redefine `--accent-color`.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/styles-and-appearance.html (read 2026-11-05)
- If you override a background on one widget, derive its standalone colour as the docs do: `oklab(from var(--accent-bg-color) var(--standalone-color-oklab))`. Also set the matching `-backdrop-color` to the same value.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/css-variables.html (read 2026-11-05)
- In code, read the accent from `AdwStyleManager:accent-color-rgba` (background) or `accent-color` plus `adw_accent_color_to_standalone_rgba()`. The style manager reports the system accent even when your CSS overrides it.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/styles-and-appearance.html (read 2026-11-05)
- Loading CSS: `AdwApplication` loads `style.css`, `style-dark.css`, `style-hc.css` and `style-hc-dark.css` from the app's resource base path by itself. Ship them as GResources; no manual `CssProvider` is needed.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/styles-and-appearance.html (read 2026-11-05)

## 5. Light, dark and high contrast

- All stock widgets handle dark mode. Your own CSS only works in both if it uses the variables.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/styles-and-appearance.html (read 2026-11-05)
- `AdwStyleManager:color-scheme` takes `ADW_COLOR_SCHEME_PREFER_LIGHT` (the default; it follows the system), `PREFER_DARK`, `FORCE_LIGHT` or `FORCE_DARK`. For a System/Light/Dark choice, map System to `PREFER_LIGHT`, Light to `FORCE_LIGHT` and Dark to `FORCE_DARK`. Most apps should not offer the choice and should just follow the system.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/styles-and-appearance.html (read 2026-11-05)
- For custom drawing (EQ graph, speaker diagram), read `AdwStyleManager:dark` and `:high-contrast`, and redraw on `notify`. In CSS use `@media (prefers-color-scheme: dark)` and `@media (prefers-contrast: more)`.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/styles-and-appearance.html (read 2026-11-05)
- High contrast follows the system, cannot be turned off by apps, and is separate from dark. Dim things with `.dimmed` and the opacity variables, not a hand-set `opacity`, so high contrast can undo it.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/styles-and-appearance.html (read 2026-11-05)

## 6. Adaptive layouts

- Use `AdwBreakpoint` on an `AdwApplicationWindow`, `AdwWindow`, `AdwDialog` or `AdwBreakpointBin`. Its condition looks like `max-width: 400sp`, and its setters change properties on other widgets.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/adaptive-layouts.html (read 2026-11-05)
- A window with breakpoints has no minimum size. Always set `width-request` and `height-request` to the smallest size you support. GNOME apps usually support 360px wide; that number is a convention, not from this page.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/adaptive-layouts.html (read 2026-11-05)
- Settings split view: at `max-width: 400sp`, set the split view's `collapsed` to `True`. When the user picks a sidebar item, call `set_show_content(true)` so the collapsed view goes to the page. Raise the threshold if the sidebar has many or long titles.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/adaptive-layouts.html (read 2026-11-05)
- For a sidebar that slides over the content (a drawer), use `AdwOverlaySplitView`. After a pick while collapsed, hide it with `set_show_sidebar(false)`.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/adaptive-layouts.html (read 2026-11-05)
- Top-level views (an app store's Explore/Installed/Updates): put `AdwViewSwitcher` in the header bar. At `max-width: 550sp`, reveal an `AdwViewSwitcherBar` at the bottom and clear the header's `title-widget`.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/adaptive-layouts.html (read 2026-11-05)
- Use `AdwMultiLayoutView` to rearrange the same widgets between layouts, for example a side panel that becomes a bottom sheet, by switching `layout-name` in a breakpoint.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/adaptive-layouts.html (read 2026-11-05)
- `AdwDialog` (including `AdwAlertDialog`) becomes a bottom sheet in narrow windows by itself. Do not build your own.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/adaptive-layouts.html (read 2026-11-05)
- Use `sp` units in conditions so breakpoints scale with the text size. The page's examples use `sp` but it does not define the units.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/adaptive-layouts.html (read 2026-11-05)

## 7. Feedback: toasts, banners, dialogs

- **Toast** (`AdwToast` in `AdwToastOverlay`): a short message after something happened, such as "Saved" or "App removed" with an Undo button (`button-label` + `action-name`, or `button-clicked`). Wrap the window's main content in one `AdwToastOverlay` and call `add_toast()`. A toast can be updated while it is shown, for example to count a batch undo. Inside a dialog, use the dialog's `add_toast()`.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.Toast.html and https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.ToastOverlay.html (read 2026-11-05)
- **Banner** (`AdwBanner`): a state that persists until something changes, such as offline, read-only or "restart to apply". Show it with `revealed`; it is hidden by default. Use at most one button. Place it at the top of the content or in `AdwPreferencesPage:banner`. The HIG says banners are for "ongoing, persistent states"; one-off events get toasts.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.Banner.html and https://developer.gnome.org/hig/patterns/feedback/banners.html (read 2026-11-05)
- **Alert dialog** (`AdwAlertDialog`): only when the user must decide before going on, such as confirming an irreversible action. Always set `default-response` and `close-response` to the safe answer ("cancel"). Give the dangerous response `ADW_RESPONSE_DESTRUCTIVE`, or the confirm response `ADW_RESPONSE_SUGGESTED`. Wait for the answer with `choose()`.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.AlertDialog.html (read 2026-11-05)
- Prefer doing the action and offering Undo in a toast over asking first. Keep `AdwAlertDialog` for actions that cannot be undone. This is design judgement drawn from the toast and alert-dialog pages above, not a quoted rule.
- **Status page**: when a whole view is empty or failed, such as no network in the store or no search results, use `AdwStatusPage` with a `pill` + `suggested-action` button as its `child`.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.StatusPage.html and https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/style-classes.html (read 2026-11-05)

## 8. Search in a settings-style app

- `AdwPreferencesDialog` has built-in search, turned on with `search-enabled` (since 1.5). Group `title`s help the search. It suits a dialog-sized preferences window.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.PreferencesDialog.html and https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.PreferencesGroup.html (read 2026-11-05)
- Not verified: exactly which row fields `AdwPreferencesDialog` searches. The `AdwPreferencesRow` page lists only `title`, `use-markup`, `use-underline` and `title-selectable`, and has no keywords property. Do not invent a `search-keywords` API.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.PreferencesRow.html (read 2026-11-05)
- A full Settings window built on `AdwNavigationSplitView` gets no built-in search. Build it yourself: put a `GtkSearchBar` holding a `GtkSearchEntry` as a top bar of the sidebar's `AdwToolbarView` (`GtkSearchBar` is a supported toolbar bar), with a search toggle button in the header. Match the query against your own index of page title, group title, row title and subtitle. Show the matches as an `AdwActionRow` list that opens the page, and use `AdwStatusPage` for no results. The widgets come from the docs; the pattern is our own design.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.ToolbarView.html (read 2026-11-05)
- For long `AdwComboRow` lists, set `enable-search` instead of building a filter.
  Source: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/class.ComboRow.html (read 2026-11-05)

## Pages not read

The Migrating guides were not needed for 1.9. `AdwAboutWindow`'s deprecation status was not checked; use `AdwAboutDialog`. The `AdwToastPriority` and `AdwBannerButtonStyle` value names, and the default toast timeout, are not on the pages read, so check the enum pages before using them.
