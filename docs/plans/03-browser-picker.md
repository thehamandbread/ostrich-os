# 03 — Browser picker (`ostrich-browser`) and its integration with Ostrich Drawer

Amended 2026-11-21 (owner): the picker is a **new Rust tool**, `tools/browser-picker`, binary `ostrich-browser` (gtk4-rs 0.11 + libadwaita-rs 0.9, as in `tools/welcome`). Ostrich Drawer sites are picker targets. Names follow plan 01 (`ostrich-os` paths, `ostrich_os` app ids).

## Spec (kept as written, except where the amendment overrides)

- App `ostrich-browser`, desktop file with `MimeType=x-scheme-handler/http;x-scheme-handler/https;text/html;`, set via `xdg-settings`.
- Modes: (a) invoked with a URL as the default handler; (b) no URL, via a shortcut (Super+B) → open a new window in the chosen profile.
- UI: small centred window (~480 px), search focused, rows = browser icon + profile name, the domain shown at the top. Keys: type-to-filter, ↑↓, Enter, 1–9 quick pick, Esc cancel, **Ctrl+Enter = open and always use for this domain**. Single-instance `GtkApplication` (D-Bus activation) so warm opens are near-instant; measure cold and warm.
- Rules: `~/.config/ostrich-os/browser-rules.json` (domain glob → target); a match skips the UI. Editable in Settings.
- Discovery on every open. Chromium family via `Local State` → `profile.info_cache`: Chrome `~/.config/google-chrome`, Chromium snap `~/snap/chromium/common/chromium`, Brave `~/.config/BraveSoftware/Brave-Browser`, Edge `~/.config/microsoft-edge`, Vivaldi `~/.config/vivaldi`, Flatpak `~/.var/app/<id>/config/...`. Firefox family via `profiles.ini`: `~/.mozilla/firefox`, `~/snap/firefox/common/.mozilla/firefox`, `~/.var/app/org.mozilla.firefox/.mozilla/firefox`, any XDG location, and Firefox's newer profile manager (profile groups). Zen/LibreWolf the same. List only browsers whose launcher exists.
- Launch: **never** `xdg-open`/`gio open` the URL (recursion). Exec the browser directly from its `.desktop` `Exec` binary: Chromium `--profile-directory=<dir> <url>`; Firefox `-P <name> <url>` (test with the browser already running on another profile); Flatpak via `flatpak run`; snap via `/snap/bin`.
- Failure: on any error, open in the last-used profile and log. A URL is never lost. URLs are logged only at debug level.
- Settings shows whether the picker is still the default (browsers reclaim it) with a Restore button.
- Omarchy prior art is MIT: reuse only if useful, keep the licence notice. (Audit A4: no `seanpk` picker branch found; the nearest upstream work is omacom/omarchy PR #9679, an install-time Bash launcher generator. Nothing copied.)

## Amendment: drawer sites are targets

- The picker offers **"Open in Drawer → <site>"** first, and only for URLs on that site's host.
- The drawer only sends **off-site** URLs out.
- The drawer's same-site function moves to a **shared crate** used by both, with a test proving there is no drawer ↔ picker loop.
- If no drawer action opens an arbitrary URL in a site, plan one.
- The drawer passes the display's launch context (an XDG activation token), and a VM test proves the picker takes focus instead of GNOME showing "… is ready".
- The tour offers the picker when there are ≥2 browser profiles **or** ≥1 drawer site.

## Audit of every place the drawer sends a URL out

`tools/drawer-host/src/main.rs`, all via `gio::AppInfo::launch_default_for_uri(…, None)` or `info.launch(&[], None)`. The line numbers the owner gave (~558, 659, 769, 837) are exact, and `open_elsewhere` has more than one call. Once the picker is the default handler, **every one of these opens the picker**:

| # | Line | Function / trigger | URL | Off-site? | After the picker exists |
|---|---|---|---|---|---|
| 1 | 558 | "Open in browser" button on the *"<site> didn't load"* error page | the site's own URL | **No, it is the site itself** | Must **not** offer "Open in Drawer": the drawer just failed to load it. Call the picker with `--no-drawer`. Today it would loop (error → picker → "Open in Drawer" → error). |
| 2 | 651 (`info.launch(&[], none)`) | `open_elsewhere` (DRM site): the site's own installed app by `.desktop` id | none (launches an app, not a URL) | n/a | Unaffected by the picker; still needs a launch context for focus (section below). |
| 3 | 655 | `open_elsewhere`: `snap://<app>` (App Center page) | `snap://…` | n/a | Not http/https/html, so the picker is never the handler. Needs a launch context only. |
| 4 | 659 | `open_elsewhere`: the DRM site's own URL in the browser | the site's own URL | **No** | `--no-drawer`. A DRM site can't be added to the drawer, so it must never be a drawer target either (`recommended.rs` marks them `drm`/`drm-app`). |
| 5 | 769 | `connect_decide_policy`: main-frame navigation that **leaves the site** (`!stays_in_drawer`) | arbitrary off-site URL | **Yes** | The picker's intended input. May offer "Open in Drawer → B" if the host is another drawer site's host. Pass `--from-drawer <site-id>` so that site is never offered back. |
| 6 | 837 | `connect_create`: a new-window request to an off-site URL (most links in a chat) | arbitrary off-site URL | **Yes** | Same as 5. |

Other callers of `launch_default_for_uri` in the workspace, for completeness: `tools/store-gtk/src/main.rs:910` and `tools/welcome/src/main.rs:2317` open `snap://` App Center pages (not http/https), so the picker is never involved. No other crate opens web URLs through the default handler. **Open item:** the drawer's notification click and any `xdg-open` in shell scripts or extensions were not audited for http(s) URLs (`git grep -n "xdg-open\|launch_default_for_uri\|show_uri" -- modules tools` is the first task of the integration step); add any hit to this table.

`open_elsewhere` (calls 2–4) and call 1 pass the **site's own URL**: those must carry `--no-drawer`, and calls 5–6 carry `--from-drawer <site-id>`. The drawer should not shell out to the picker only when it is the default; it uses one helper:

```
open_external(url, ctx, mode)
    if mode == SameSite  → default handler or picker is irrelevant: spawn the picker directly with --no-drawer if
                           the picker is the default http handler, else launch_default_for_uri(url, ctx)
    if mode == OffSite   → launch_default_for_uri(url, ctx)  (the picker, if default, receives --from-drawer via the
                           D-Bus Open call's platform-data, see below)
```

(One honest limit: `launch_default_for_uri` cannot carry extra flags. For the "from drawer" marker the drawer therefore calls the picker over D-Bus (`org.freedesktop.Application.Open`/`org.gtk.Actions` with `platform-data`) when the picker is the default handler, and falls back to `launch_default_for_uri` otherwise. Resolve the handler with `gio::AppInfo::default_for_uri_scheme("https")` and compare its id to `ostrich_os.browser.desktop`.)

## The shared crate: no loop by construction

Move `host_of`, `site_of`, `same_site`, `SIGN_IN_HOSTS` and `stays_in_drawer` from `tools/drawer-host/src/config.rs:291-344` (with their tests at ~605-623) into a new pure crate, **`tools/site-match`** (no GTK). `drawer-host` and `browser-picker` both depend on it. Public API:

```rust
pub fn host_of(url: &str) -> Option<String>;
pub fn same_site(a: &str, b: &str) -> bool;        // registrable domain (existing function; used by the drawer)
pub fn stays_in_drawer(site: &str, url: &str) -> bool;   // same_site OR a sign-in host OR non-web scheme (existing)
pub fn drawer_offer(site: &str, url: &str) -> bool;      // NEW, stricter: the URL's host equals the site's host
```

`drawer_offer` is what the picker uses for "Open in Drawer → <site>": **the same host** (case-insensitive, a leading `www.` ignored on both sides), not the registrable domain. Reason: `same_site` treats `mail.google.com` and `messages.google.com` as one site, so offering "Open in Drawer → Google Messages" for a Gmail link would be wrong. The amendment says "that site's host".

Invariants (each is a test):

1. `drawer_offer(site, url) ⇒ stays_in_drawer(site, url)`. Whatever the picker hands to a drawer site, that site's own policy keeps in the drawer, so it can never bounce back out. **This is the no-loop proof**; the property test in `tools/site-match` enumerates hosts × sites (including sign-in hosts, `www.`, uppercase, ports, userinfo, IDN, `localhost`) and asserts the implication.
2. The drawer sends out only `!stays_in_drawer` URLs (calls 5–6) — unchanged code, now covered by a test against the same crate.
3. The picker's own external launches execute browsers directly (never the default handler), so they cannot reach the drawer either.
4. The drawer's own-site calls (1, 4) use `--no-drawer`, so "Open in browser" never offers the drawer.
5. A navigation that came *from* drawer site A is never offered back to A (`--from-drawer A`), a belt-and-braces guard against redirect ping-pong between two drawer sites (A redirects to B's host, B's to A's: the picker would otherwise keep asking). Plus a rate guard: the same URL arriving from the drawer twice within 2 s opens in the default browser profile with no UI.
6. **Integration test in the VM** (`tests/vm/picker-drawer-test.sh`): two stand-in local sites A and B (different ports on `localhost` are the same host, so use `a.localtest.me`-style names via `/etc/hosts` in the VM; no internet) where A links to B and B redirects back to A; click through, and assert the picker appears at most once per user action, the drawer never spawns more than N picker processes (count with `pgrep` before and after), and the sequence terminates. A negative control (set `drawer_offer` to always-true) must fail the test, proving it detects a loop.

## A drawer action that opens an arbitrary URL in a site

Existing GApplication actions (`main.rs` doc comment and `docs/DESIGN.md` D-Bus line): `toggle`, `show(s)`, `mute(b)`, `load/unload/reload/back/remove/add(s)`, `elsewhere(s)`, `pin/keep/mute-site(sb)`, `set-size((suu))`, `use-set((asas))`, `visible(b)`, read-only `state`. **None opens a URL in a site:** `show(s)` takes a site id, `add(s)` creates a new site from an address, `load(s)` loads the site's own start page.

Plan one new action: **`open((ss))`** = (site id, url). Rules, all in the host:

1. Reject unless the site exists, is not DRM, and `site_match::stays_in_drawer(site.url, url)` holds (a hostile caller on the session bus can't make a site load an unrelated page in its cookie jar; this is the same rule the picker used and the one that makes the loop impossible).
2. Reject anything that is not `https`/`http`.
3. Load the URL in that site's view (starting the view if unloaded), then do what `show` does (drop the drawer under the site's icon).
4. Take the activation token from the call's `platform-data` (`activation-token`, `desktop-startup-id`) and use it when presenting the drawer window (the shell moves focus only with a valid token).

CLI twin: `ostrich-drawer --open ID URL` (used by tests and scripts). Add it to the doc comment, `docs/DESIGN.md` and a drawer-test case (`DRW-13`: "open URL in site loads it there and shows the drawer"; **new** in `docs/FEATURES.md`). The Settings/tour never needs it.

## Activation token: focus instead of "is ready"

Today every call above passes `None::<&gio::AppLaunchContext>`, so the launched app gets no XDG activation token. On Wayland GNOME then refuses to give it focus and shows an "<app> is ready" notification.

- **Drawer side:** use `gdk::Display::default().app_launch_context()` (a `GdkAppLaunchContext`) in `open_external` and in the `open_elsewhere` launches (calls 1–6) and pass it as the `AppLaunchContext` argument; where the call is triggered by a click or key (calls 1, 5, 6 come from a user's click in the page), the context picks up the event's serial/timestamp, which the shell needs to accept the token. For D-Bus calls to the picker, put the token in `platform-data`.
- **Picker side:** GTK reads `XDG_ACTIVATION_TOKEN`/`DESKTOP_STARTUP_ID` from the environment (set by GIO when it spawns the app) or from `platform-data` of the activation (D-Bus-activated, single-instance) and uses it for its first `present()`. When the picker opens "Open in Drawer", it forwards **its own** token (`display.app_launch_context().startup_notify_id()`) in `platform-data` to the drawer's `open` action, so the drawer window can take focus.
- **VM test** (`tests/vm/picker-focus-test.sh`): from a drawer site, click an off-site link; within 1 s assert (a) the picker window is the focused window (use the shell's window introspection method already used in `tests/vm`; if none exists, plan to read `org.gnome.Shell.Introspect GetWindows` `has-focus`), and (b) **no** "is ready" notification was shown (query the shell's notification source list over D-Bus or `journalctl --user -u gnome-shell` for the activation warning). Negative control: a build that still passes `None` must fail (a) or (b), proving the test measures the thing. Repeat for picker → drawer ("Open in Drawer" focuses the drawer) and for `open_elsewhere` (the DRM site's app).

CONFLICT: the tour/wizard **already** pushes to the drawer through a similar path (`ostrich-drawer --add`, etc.) with no token; those run from the wizard's own focused window so are not affected — RECOMMEND: leave them, and note that only the six sites above are in scope.

## CONFLICTs and open points

CONFLICT: the spec's desktop file `ostrich-browser.desktop` and the app id — plan 01's rule makes app ids and desktop ids `ostrich_os.<name>` — RECOMMEND: `ostrich_os.browser.desktop` (`Exec=ostrich-browser %U`), GApplication id `ostrich_os.browser`, D-Bus path `/ostrich_os/browser`. The binary keeps the spec's name. The app-id lint from plan 01 covers it.

CONFLICT: "offered only when ≥2 browser profiles" — the amendment adds drawer sites as targets — RECOMMEND: offered when **≥2 browser profiles or ≥1 drawer site**, in the tour and in Settings. With **one** target only (one profile, and no drawer site matching the URL) the picker never shows: it opens the URL straight in that profile, so installing it can't add a pointless extra click.

CONFLICT: "Super+B" — repo search finds no Super+B binding (Ostrich uses Super+Alt+D, Super+Alt+Tab, Super+arrows and the keypad; the host's installed schemas had none and Ubuntu's help lists Super, Super+A, Super+D, Super+V). The GNOME 50 custom-keybinding path is **not confirmed from upstream** — RECOMMEND: verify in the VM before building:
```bash
gsettings describe org.gnome.settings-daemon.plugins.media-keys custom-keybindings
```
and prefer registering the key from an Ostrich extension (`Main.wm.addKeybinding`, as the other extensions do), so it appears in the shortcut cheat sheet and is released when disabled. If a dconf custom keybinding is used instead, **append** to the existing list, never overwrite it. Make the binding a setting.

CONFLICT: the spec says "measure cold and warm" but sets no numbers — RECOMMEND: cold ≤ 400 ms and warm ≤ 80 ms from keypress or activation to visible window, measured in the VM and recorded in `docs/BASELINE.md` (principle 4); a GTK4 + libadwaita Rust app should meet it; if it doesn't, trim the first frame (no icons loaded until after present, discovery on a worker).

CONFLICT: "Firefox `-P name <url>` … choose flags that open in the correct instance" — research found no single reliable flag. `-P` selects a profile but a plain second launch may hand the URL to the **already-running instance of another profile**; `-no-remote` isolates but errors if that profile is already running ("already running"); no documented `--profile-group` flag exists (Firefox 138+ selectable profiles live in `~/.mozilla/firefox/Profile Groups/<storeID>.sqlite`; the exact filename and schema are unverified). — RECOMMEND: a VM test matrix and per-case flags; ship only observed behaviour:
  1. profile not running → `firefox -P <name> -no-remote <url>`;
  2. profile already running → `firefox -P <name> <url>` (its own remoting; verify);
  3. another profile running, target not → `-no-remote -P <name> <url>`;
  4. profile-group profiles → `-profile <path-from-sqlite>`, else default profile + log (never lose the URL).

CONFLICT: snap Firefox (Ubuntu's default) keeps its profiles under `~/snap/firefox/common/.mozilla/firefox` and must be launched as `/snap/bin/firefox`; `-profile <path outside the snap's home>` may fail under confinement — RECOMMEND: `-P` names only for snap Firefox; test.

CONFLICT: "set via `xdg-settings`" covers http/https only, not `text/html`; browsers reclaim the handler — RECOMMEND: also `xdg-mime default ostrich_os.browser.desktop x-scheme-handler/http x-scheme-handler/https text/html`; read back with `xdg-settings get default-web-browser` and `xdg-mime query default …` for the Settings status; save the previous default to `~/.local/state/ostrich-os/browser-previous-default` for `revert`.

CONFLICT: "A URL is never lost" and "Esc cancels" — RECOMMEND: Esc is an explicit cancel, so the URL is not opened; the rule applies to errors. Say so in one line of the Settings copy.

## Design

### Components

- `tools/browser-picker` crate: `discover.rs`, `rules.rs`, `launch.rs`, `drawer.rs` (D-Bus client for `open`), `ui.rs`, `main.rs`. Depends on `tools/site-match`.
- `ostrich_os.browser.desktop`: `Exec=ostrich-browser %U`, the three MIME types, `DBusActivatable=true` with a service file; hidden when the option is off.
- One resident-for-20-s process: `hold()` released after 20 s idle so a quick second pick is warm; no polling, no daemon after that.
- Discovery and rules are pure modules with fixture tests.

### Targets and rows

A **target** is `Drawer(site-id)` or `Browser(profile)`. Rows: first, if `drawer_offer(site, url)` holds for any drawer site (from `ostrich-drawer --list` or the drawer's `state` action; skipped if the drawer isn't running and can't be started in 300 ms, in which case no Drawer row is shown), a row **"Open in Drawer → <site name>"** with the site's favicon; then browser profiles (last used first). Mode (b) shows only browser profiles. Numbers 1–9 count visible rows, so the drawer row is 1 when present.

Rules file (`~/.config/ostrich-os/browser-rules.json`): `{"match": "*.slack.com", "target": {"drawer": "slack"}}` or `{"match": "github.com", "target": {"profile": "chrome:Profile 2"}}`. A drawer rule is checked with `drawer_offer` at use time; if it no longer holds (the site was removed or changed), the rule is skipped and the picker shows normally (never silently falls to a different browser).

### Discovery

Run on every open (cheap file reads). Roots are the spec's. Chromium: `<root>/Local State` JSON → `profile.info_cache.<dir>.name`; Firefox, Zen, LibreWolf: `profiles.ini` (`[ProfileN] Name=,Path=,IsRelative=`, skip `[Install…]`); Firefox profile groups: read-only `Profile Groups/*.sqlite` (`immutable=1`) — **first VM spike: dump `.schema` from a real Firefox ≥ 138 before writing the parser.** A browser is listed only if its launcher resolves: parse `.desktop` files in `/usr/share/applications`, `~/.local/share/applications`, flatpak exports (`/var/lib/flatpak/exports/share/applications`, `~/.local/share/flatpak/exports/share/applications`) and snap (`/var/lib/snapd/desktop/applications`); take the `Exec` first word; skip `ostrich-browser` itself and any `ostrich_os.*` desktop id (recursion guard); check the executable or `flatpak info <id>` exists.

### UI

Stock widgets only: `AdwWindow` ~480 px, `GtkSearchEntry` focused, `GtkListBox.boxed-list` of `AdwActionRow`s (prefix icon, title = profile or "Open in Drawer → …", subtitle = browser, number as suffix). Heading shows the host (middle-truncated), never the whole URL or its path. Keys per the spec; Ctrl+Enter writes a rule for the **exact host** (a drawer rule when the chosen target is a drawer site) and shows a toast with Undo for 5 s. Accessible label per row "<target>, <browser>"; single tab stop with arrow navigation. The window follows the `ostrich-design` skill (and its copy rules).

### Launch

Rules → picker → build argv from the target; spawn without a shell, `setsid`, URL as a single argv element after `--` where supported. Only `http`, `https` and `file` URLs are accepted; a URL starting with `-` or any other scheme exits with an error and launches nothing. Flatpak: `flatpak run <id> <flags> <url>`; snap: `/snap/bin/<name>`. Mode (b): `--new-window` (Chromium `--profile-directory=<dir> --new-window`; Firefox `-P <name> -new-window about:blank`). A `Drawer` target calls the drawer's `open((ss))` over D-Bus with the activation token; if the call fails, fall back to the last-used browser profile and log.

### Failure

Any error (no profiles, launcher missing, spawn fails, rules unreadable, drawer call fails) → open in the **last-used profile** (`~/.local/state/ostrich-os/browser-last` stores a profile id only, never a URL), else the first discovered browser's default profile, else the previous default saved at install time. Log with the usual logger: `warn` for the error, the URL only at `debug`. A rules-file parse error is logged and the file ignored for this open, never rewritten or deleted.

### Settings and tour

Settings → **Browser** page (copy from `tools/welcome/data/copy.toml`, plan 02): status row ("Ostrich browser picker is your default browser" / "Another app took over as default browser") with **Restore**; the rules list (pattern, target combo that includes drawer sites; an unknown target is shown "Not found" and kept, not deleted); the shortcut row; and turning the option off runs `revert` (restore the saved default, remove the desktop file and keybinding; the machine is never left without a default browser). The tour offers the page when there are **≥2 browser profiles or ≥1 drawer site** (placement is for the council, plan 02).

## Files to touch

`tools/site-match/` (new crate; the moved functions and tests), `tools/drawer-host/src/{config.rs,main.rs}` (use the crate; `open((ss))` action; `open_external` helper with the launch context; `--open` CLI; remove the six `None` contexts), `tools/browser-picker/` (new), `tools/Cargo.toml` (workspace members), `modules/browser-picker/install.sh` (+ `status`, `revert`), `share/applications/ostrich_os.browser.desktop`, `share/dbus-1/services/ostrich_os.browser.service`, `tools/welcome/data/copy.toml` + Browser page, `tests/fixtures/browsers/`, `tests/browser-picker.bats`, `tests/vm/{browser-test,picker-drawer-test,picker-focus-test}.sh`, `docs/FEATURES.md` (new rows; DRW-13), `docs/DESIGN.md`, `docs/DECISIONS.md`.

## Done criteria

1. `tools/site-match` holds the moved functions; the drawer's existing unit tests pass unchanged against it; the property test proves `drawer_offer ⇒ stays_in_drawer`.
2. Discovery returns the right profiles, with the names each browser shows, for every fixture (Chrome ×3 profiles, snap Chromium, Brave, Edge, Vivaldi, Flatpak Chrome, Firefox deb/snap/flatpak, Zen, LibreWolf, Firefox ≥138 profile group).
3. Keyboard-only: type, arrows, Enter, 1–9, Esc, Ctrl+Enter; Ctrl+Enter writes a valid rule and the next open skips the UI.
4. Launch never calls `xdg-open`/`gio open` (`strace -f -e execve` in the VM shows no such exec); rejects `-`-prefixed and non-http(s)/file URLs.
5. Firefox matrix cases 1–4 pass: the URL lands in the chosen profile's window every time.
6. Drawer integration: from a drawer site an off-site link opens the picker; "Open in Drawer → B" loads the URL in B and shows the drawer (`open` action); a link to a host that no drawer site owns shows no Drawer row; "Open in browser" on the error page shows no Drawer row (`--no-drawer`); the loop test (6 above) terminates and its negative control fails.
7. Focus: the picker takes focus and no "is ready" notification appears for calls 1, 5, 6; picker → drawer focuses the drawer; the negative control (`None` context) fails.
8. Failure paths: remove the launcher, corrupt the rules file, kill the browser mid-launch, stop the drawer: the URL still opens in the last-used profile; the log has no URL at the default level.
9. Cold ≤ 400 ms, warm ≤ 80 ms in the VM; no resident process after 20 s idle.
10. Settings shows "not default" after a browser steals the handler and **Restore** fixes it.

## Test method

`cargo test` for `site-match` (pure, including the property test), discovery, rules and argv construction on fixtures; bats for the module and `.desktop` validation (`desktop-file-validate`). Docker `ubuntu:26.04` for all of that. VM (GNOME 50, Wayland) for real browsers (Firefox snap + deb, Chrome deb, Chromium snap), the drawer integration, focus and notification checks, timings, and the Super+B registration. Never the live machine.
