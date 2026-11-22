# 03 — Browser picker (`ostrich-browser`)

Depends on 01 (names), 02 (option + Settings page), 05 (UI checklist).

## Spec (kept as written)

- App `ostrich-browser`, desktop file with `MimeType=x-scheme-handler/http;x-scheme-handler/https;text/html;`, set via `xdg-settings`. Offered only when ≥2 browser profiles are detected.
- Modes: (a) invoked with a URL as default handler; (b) no URL, via a shortcut (Super+B) → open a new window in the chosen profile.
- UI: small centred window (~480 px), search focused, rows = browser icon + profile name, domain shown at top. Keys: type-to-filter, ↑↓, Enter, 1–9 quick pick, Esc cancel, **Ctrl+Enter = open and always use for this domain**. `Gtk.Application` single instance (D-Bus activation) so warm opens are near-instant; measure cold and warm.
- Rules: `~/.config/ostrich/browser-rules.json` (domain glob → profile id); a match skips the UI. Editable in Settings.
- Discovery on every open. Chromium family via `Local State` → `profile.info_cache`: Chrome `~/.config/google-chrome`, Chromium snap `~/snap/chromium/common/chromium`, Brave `~/.config/BraveSoftware/Brave-Browser`, Edge `~/.config/microsoft-edge`, Vivaldi `~/.config/vivaldi`, Flatpak `~/.var/app/<id>/config/...`. Firefox family via `profiles.ini`: `~/.mozilla/firefox`, `~/snap/firefox/common/.mozilla/firefox`, `~/.var/app/org.mozilla.firefox/.mozilla/firefox`, plus any XDG location and Firefox's newer profile manager (profile groups). Zen/LibreWolf same format. List only browsers whose launcher exists.
- Launch: **never** `xdg-open`/`gio open` the URL (recursion). Exec the browser directly from its `.desktop` `Exec` binary: Chromium `--profile-directory=<dir> <url>`; Firefox `-P <name> <url>` — test with the browser already running on another profile and choose flags that open in the correct instance; Flatpak via `flatpak run`; snap via `/snap/bin`.
- Failure: on any error, open in the last-used profile and log. A URL is never lost. URLs are logged only at debug level.
- Settings shows whether the picker is still the default (browsers reclaim it) with a Restore button.
- Omarchy prior art is MIT: reuse only if useful, keep the licence notice.

## Prior art and licence (audit A4)

No `seanpk` browser-picker branch exists on the fork checked. The nearest upstream work is omacom/omarchy PR #9679 (Bash, writes `--profile-directory` into generated launchers at web-app install time); it is not a runtime picker, and nothing is copied. Omarchy is MIT; if code is ever reused, add its notice to `THIRD-PARTY.md`.

## CONFLICTs and open points

CONFLICT: "Super+B" — repo search finds no existing Super+B binding in Ostrich's extensions or `docs/DESIGN.md` (its drawer uses Super+Alt+D, Super+Alt+Tab, tiling uses Super+arrows and keypad). On the dev host `gsettings list-recursively` showed no Super+B in the installed schemas and Ubuntu's shortcut help lists only Super, Super+A, Super+D, Super+V. The custom-keybinding path is **not confirmed from upstream for GNOME 50** (the schema page could not be fetched). — RECOMMEND: in the VM (GNOME 50) read the live schema and test before building:
```bash
gsettings describe org.gnome.settings-daemon.plugins.media-keys custom-keybindings
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ostrich-browser/']"
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ostrich-browser/ name 'Ostrich browser'
# … command 'ostrich-browser --new-window', binding '<Super>b'
```
The extension suite already writes keybindings from extensions (`Main.wm.addKeybinding`); prefer that over dconf custom keybindings so the binding appears in the existing shortcut cheat sheet and is released on disable. Also **merge with** existing custom keybindings (append, never overwrite the list) and make the binding a setting (conflicts with the user's own Super+B).

CONFLICT: "Python/PyGObject, cold/warm measured" — a Python + GTK4 + libadwaita cold start is typically several hundred ms (imports, GI typelib loading); Rust is faster and matches the toolchain — RECOMMEND: build in Rust in `tools/browser-picker` (same workspace, gtk4-rs/libadwaita-rs already vendored); Python is acceptable only if the measured cold start is under 400 ms in the VM. **Measure both before choosing**; the plan's budget is cold ≤ 400 ms, warm ≤ 80 ms from keypress to visible window, on the VM. This follows `docs/DESIGN.md` principle 4 (measured budgets).

CONFLICT: "Firefox `-P name <url>` … choose flags that open in the correct instance" — research found no reliable single flag. Mozilla's `-P` selects a profile but a plain second launch may hand the URL to the **already running instance of another profile**; `-no-remote` isolates but then errors if that profile is already running ("already running"); there is **no documented `--profile-group` flag** (Firefox 138+ selectable profiles live in `~/.mozilla/firefox/Profile Groups/<storeID>.sqlite`; the exact filename is unverified). — RECOMMEND: test matrix in the VM (below) and pick per case:
  1. profile not running → `firefox -P <name> -no-remote <url>`;
  2. profile already running → `firefox -P <name> <url>` (remoting finds *that* profile's instance; verify);
  3. other profile running and target not → `-no-remote -P <name> <url>`;
  4. profile-group profiles → `-profile <path-from-sqlite>`; if it misbehaves, fall back to the default profile and log (never lose the URL).
Do not ship a flag combination that was not observed working.

CONFLICT: "list only browsers whose launcher exists" and snaps — Ubuntu's default Firefox is a **snap**; its profile dir is under `~/snap/firefox/common/.mozilla/firefox` and it must be launched as `/snap/bin/firefox` (the confinement does not allow reading arbitrary profile paths, so `-profile <path>` outside the snap's home may fail) — RECOMMEND: for snap Firefox use `-P` names only; test.

CONFLICT: "set via `xdg-settings`" — GNOME's Default Apps UI and browsers' own "make default" prompts reclaim the handler silently; `xdg-settings set default-web-browser` only changes the `http`/`https` handlers, not `text/html` — RECOMMEND: set all three through `xdg-mime default ostrich-browser.desktop x-scheme-handler/http x-scheme-handler/https text/html` and also `xdg-settings set default-web-browser ostrich-browser.desktop`; read back with `xdg-settings get default-web-browser` and `xdg-mime query default …` for the Settings status.

## Design

### Components

- `ostrich-browser` binary: `GtkApplication` id `ostrich.browser` (after rename), `HANDLES_OPEN` flag so GNOME passes URIs through D-Bus activation; no resident daemon. After the picker closes the process exits when idle (`hold` released with a 20 s timeout so a quick second pick is warm; this is a measured timer that stops once idle).
- `ostrich-browser.desktop`: `Exec=ostrich-browser %U`, `MimeType=…`, `NoDisplay=false` only when the option is enabled, `StartupNotify=false`; `DBusActivatable=true` with a D-Bus service file.
- Discovery library (pure, unit-tested against fixtures in `tests/fixtures/browsers/`): returns `Vec<Profile { browser, name, profile_id, launch: Launch }>`.
- Rules library: glob match on host (`*.example.com`, `example.com`); exact host beats wildcard; longest pattern wins.

### Discovery

Run on every open (cheap file reads; no caching between opens, so new profiles show at once).

| Family | Source | Profile name | Launcher |
|---|---|---|---|
| Chromium: Chrome, Chromium (snap), Brave, Edge, Vivaldi, Opera, Flatpak ones | `<root>/Local State` JSON → `profile.info_cache.<dir>.name` (fallback `user_name`, dir) | `name` | `Exec` from the matching `.desktop`; add `--profile-directory=<dir>` |
| Firefox, Zen, LibreWolf | `profiles.ini` in each root (INI: `[ProfileN] Name=,Path=,IsRelative=`; skip `[Install…]`, honour `Default=1` for the default) | `Name` | `Exec` binary; `-P <name>` or `-profile <path>` |
| Firefox profile groups | `<root>/Profile Groups/*.sqlite` (read-only open, `immutable=1`) if present; the schema is unverified, so the first VM spike must dump `.schema` from a real Firefox ≥ 138 before the parser is written | profile name | `-profile <path>` |

Roots: the paths in the spec, plus `$XDG_CONFIG_HOME`/`$XDG_DATA_HOME` equivalents. A browser is listed only if its launcher resolves: parse `/usr/share/applications`, `~/.local/share/applications`, flatpak exports (`/var/lib/flatpak/exports/share/applications`, `~/.local/share/flatpak/exports/share/applications`) and snap (`/var/lib/snapd/desktop/applications`) `.desktop` files, take the `Exec` first word, skip anything that is `ostrich-browser` itself (recursion guard), and check the executable or `flatpak info <id>` exists. Icons come from the `.desktop` `Icon=`; a profile row uses the browser icon only (profile avatars are not shown).

Offer condition: `profiles ≥ 2` across all browsers (so one browser with two profiles qualifies). The option is hidden otherwise (`detect` in the schema, `{"software":"browser-profiles>=2"}`).

### UI

Stock widgets only (plan 05): `AdwWindow` ~480 px wide, `AdwHeaderBar`-less (dialog-style) with `GtkSearchEntry` focused; below it a `GtkListBox` (`boxed-list`) of `AdwActionRow`s: prefix icon, title = profile name, subtitle = browser name; numbers 1–9 as suffix labels. The domain (or "Open a new window" in mode b) is the window title/heading at the top, truncated in the middle, never the full URL (privacy and length; the path is not shown).

Keys: typing filters (case-insensitive substring over profile + browser); ↑/↓ move; Enter opens; 1–9 open the n-th **visible** row; Esc cancels (an explicit user cancel: the URL is not opened, the one case where that is intended); Ctrl+Enter opens and writes a rule `{domain: <host>, profile: <id>}` for this host (the exact host, not a wildcard; a toast "Always using X for example.com" with Undo for 5 s).

CONFLICT: "A URL is never lost" and "Esc cancel" — RECOMMEND: Esc closes without opening, by design, and the spec's rule is read as "never lost on *errors*". Add a one-line note in the summary text of the Settings option.

Accessibility: every row has an accessible label "<profile>, <browser>"; list is a single tab stop with arrow navigation; focus ring is GTK's default.

### Launch

1. Look up rules for the host; a match skips the UI.
2. Otherwise show the picker.
3. Build argv from the chosen profile's `Launch` (table above). Spawn with `GSubprocess` / `Command` with `setsid`, no shell; the URL is passed as a single argv element after `--` where the browser supports it (Chromium: `--`; Firefox: pass as is). **Never** `xdg-open`, `gio open`, or `g_app_info_launch_default_for_uri`.
4. Flatpak: `flatpak run <id> <flags> <url>`. Snap: `/snap/bin/<name> <flags> <url>`.
5. Mode (b) (no URL): `--new-window` → Chromium `--profile-directory=<dir> --new-window`; Firefox `-P <name> -new-window about:blank` (`-new-window` URL arg required).
6. URL validation: only `http`, `https`, `file` (for `text/html` handler) schemes are accepted; others exit 2 without launching (stops argument injection via URLs starting with `-`; a URL that starts with `-` is rejected).

### Failure

Any error (no profiles found, launcher missing, spawn error, rules file unreadable) → open in the **last-used profile** (`~/.local/state/ostrich/browser-last` stores `profile_id` only, never a URL), else the first discovered browser's default profile, else `xdg-settings get default-web-browser`'s previous value saved at install time in `~/.local/state/ostrich/browser-previous-default` (excluding the picker itself). Log with the usual logger: `warn` for the error, URL only at `debug` level (`OSTRICH_LOG=debug`). A rules-file parse error does not drop rules silently: log, ignore the file for this open, keep it on disk.

### Settings page ("Browser")

- **Status row:** "Ostrich browser picker is your default browser" / "Another app took over as default browser" (reads `xdg-settings get default-web-browser` plus `xdg-mime query default` for the three types); **Restore** button (primary when not default) re-runs the module.
- **Rules list:** domain pattern, profile (combo of discovered profiles), delete; "Add rule"; validation: valid host glob, known profile (an unknown profile id turns the row red-subtitled "Profile not found", it is not deleted).
- **Shortcut row:** shows Super+B and lets the user change or clear it.
- Turning the option off runs `revert`: restore the saved previous default and remove the desktop file and keybinding. Never leaves the machine without a default browser.

## Files to touch

`tools/browser-picker/` (new crate: `discover.rs`, `rules.rs`, `launch.rs`, `ui.rs`, `main.rs`), `tools/Cargo.toml`, `modules/apps/` or new `modules/browser-picker/install.sh` (+`revert`, `status`), `share/applications/ostrich-browser.desktop`, `share/dbus-1/services/ostrich.browser.service`, `share/ostrich/options.json` (option + rules page), `tools/welcome/src/main.rs` (Browser page), `modules/gnome/extensions/tweaks/` (Super+B keybinding, if done in an extension), `tests/fixtures/browsers/`, `tests/browser-picker.bats`, `tests/vm/browser-test.sh`, `docs/DESIGN.md`, `docs/DECISIONS.md`.

## Done criteria

1. Discovery returns the right profiles for every fixture (Chrome with 3 profiles, snap Chromium, Brave, Edge, Vivaldi, Flatpak Chrome, Firefox deb + snap + flatpak with `profiles.ini`, Zen, LibreWolf, Firefox ≥138 profile group) with names exactly as the browser shows them.
2. Picker works by keyboard only (type, arrows, Enter, 1–9, Esc, Ctrl+Enter); Ctrl+Enter writes a valid rule and the next open skips the UI.
3. Launch never calls `xdg-open`/`gio open` (grep + `strace -f -e execve` assertion in the VM test shows no such exec).
4. Firefox flag matrix passes (cases 1–4 above), URL opens in the **chosen** profile's window every time.
5. Failure paths: remove the launcher, corrupt `browser-rules.json`, kill the browser mid-launch → URL still opens in last-used profile; log has no URL at default level.
6. Cold ≤ 400 ms and warm ≤ 80 ms in the VM (record in `docs/BASELINE.md`); no resident process after 20 s idle.
7. Settings shows "not default" after a browser steals the handler and **Restore** fixes it.
8. Rejects `-`-prefixed and non-http(s)/file URLs.

## Test method

Unit tests with fixtures (cargo test + bats). Docker `ubuntu:26.04`: discovery against fixture directories, argv construction, URL validation, rules matching, `.desktop` validation (`desktop-file-validate`). VM (GNOME 50, Wayland): install real Firefox (snap + deb), Chrome (deb), Chromium (snap), run `tests/vm/browser-test.sh` which creates two profiles each, opens a URL with browser already running on the other profile, checks which window got the page (use whichever window-inspection method `tests/vm/` already has for Wayland; if none fits, read each browser's session or `about:` state), measures cold/warm with `systemd-analyze`-style timestamps, steals the default and checks Restore. Screenshots via plan 05. Never the live machine.
