# 01 — Rename to Ostrich OS

Amended 2026-11-21 (owner): `ostrich-os` for paths, extension UUIDs and gschema ids; `ostrich_os` for GApplication ids, `.desktop` ids and D-Bus names; the installer one-liner is `wget`; one migration table for all three earlier slugs; drawer logins must survive; per-app notification settings must follow the new ids.

Spec, kept: product **Ostrich OS**; repo slug `ostrich-os`; CLI `ostrich` (already the CLI); "Ubuntu" only descriptively ("for Ubuntu 26.04 LTS"), no Ubuntu/Canonical logos; README notice "Ubuntu is a registered trademark of Canonical Ltd. Ostrich OS is not affiliated with or endorsed by Canonical."; update every URL (the GitHub redirect is a safety net only); never recreate a repo at the old name.

## Why two slugs: the portal's dash rule

`docs/DECISIONS.md` 2026-10-31: WebKit writes the app's id into its sandbox's `/.flatpak-info`; xdg-desktop-portal accepts a dash only in the **last part** of an id, and a dash elsewhere made its Flatpak lookup fail without an error, which the next line dereferenced, so the portal crashed on every call from a drawer page. The fix was `ubuntu-ostrich.drawer` → `ubuntu_ostrich.drawer`. Hence:

| Kind | Form | Examples |
|---|---|---|
| Paths, extension UUIDs, gschema ids, dconf paths, systemd units, polkit actions, udev rules, libexec dirs | `ostrich-os` | `~/.config/ostrich-os/`, `dock@ostrich-os`, `org.gnome.shell.extensions.ostrich-os.dock`, `/org/gnome/shell/extensions/ostrich-os/`, `ostrich-os-power.service`, `org.ostrich-os.system-helper.power` |
| GApplication ids, `.desktop` ids, D-Bus names and their object paths | `ostrich_os` (no dash before the last part) | `ostrich_os.drawer`, `/ostrich_os/drawer`, `ostrich_os.store.desktop`, `ostrich_os.setup.desktop`, per-site `ostrich_os.drawer.<service>` |

Rule to enforce with a bats test (`tests/appid-lint.sh`): any id that is an app id, `.desktop` id, `Gio.Application` id or D-Bus name contains **no `-` in any part but the last** (a service name such as `google-chat` is the last part, which the portal accepts). The slug `ostrich-os` must never appear in one. CI fails otherwise. A polkit action id is not an app id, so `org.ostrich-os.system-helper.*` is fine; keep the dashed slug there for consistency (choice to confirm).

## One migration table for all three earlier slugs

Earlier names (from `docs/DECISIONS.md` 2026-10-20/21): **`cleanest-ubuntu-setup`** (The Cleanest Ubuntu Setup) → **`ostrich-ubuntu`** (2026-10-20) → **`ubuntu-ostrich`** (2026-10-21, current, released as 0.4.0/0.5.0). The installer already switches off extensions under the first two UUID suffixes (`OLD_SUFFIXES` in `modules/gnome/install.sh:32`) but moved no directories or settings for them, so a machine that ran a build from before 2026-10-21 may hold data under any of the three. The project was private then (the public repo starts at 0.4.0), so this is expected only on the owner's machines and VM snapshots, but the loop costs nothing: **one table, one loop over `S ∈ {cleanest-ubuntu-setup, ostrich-ubuntu, ubuntu-ostrich}`**; for each row, move from the newest slug that has the thing. If several exist, take the newest and rename the older ones to `<name>.migrated-<date>`; never merge two trees.

| What | From (each slug `S`) | To |
|---|---|---|
| Config dir | `~/.config/S/` | `~/.config/ostrich-os/` |
| Data dir | `~/.local/share/S/` (includes `drawer/<site>/data/cookies.sqlite`, `src/`) | `~/.local/share/ostrich-os/` |
| State dir (restore points, `install.log`, `source`) | `~/.local/state/S/` | `~/.local/state/ostrich-os/` |
| Tool binaries | `~/.local/libexec/S/` | `~/.local/libexec/ostrich-os/` |
| dconf | `/org/gnome/shell/extensions/S/` | `/org/gnome/shell/extensions/ostrich-os/` |
| Extension dirs and UUIDs (11) | `~/.local/share/gnome-shell/extensions/<ext>@S`; entries in `enabled-extensions`/`disabled-extensions` | `<ext>@ostrich-os` |
| Extension gschema ids | `org.gnome.shell.extensions.S.<ext>` | `org.gnome.shell.extensions.ostrich-os.<ext>` |
| GApplication / `.desktop` / D-Bus ids | the dash form `S.drawer` used before 2026-10-31 (`lib/uninstall.sh:195` already cleans its launchers); the current `ubuntu_ostrich.drawer`, `.store`, `.setup`; per-site `ubuntu_ostrich.drawer.<service>.desktop` in `~/.local/share/applications/` | `ostrich_os.drawer`, `ostrich_os.store`, `ostrich_os.setup`, `ostrich_os.drawer.<service>.desktop`; object path `/ostrich_os/drawer` |
| GNOME per-app notification settings | `/org/gnome/desktop/notifications/application/<child>/` whose `application-id` is an old drawer, Store or setup id | the same values under the new ids (see below) |
| Dock/favourites that name the drawer | `org.gnome.shell favorite-apps` and the dock's `favorite-apps`-style key (default `['ubuntu_ostrich.drawer']` in the dock schema) | new id |
| Autostart | `~/.config/autostart/*ostrich*` (setup tour, drawer) | new file names; old removed |
| User units | `ostrich-store-updates.{service,timer}` (name has no slug) | unchanged; reload |
| chezmoi source | `home/dot_config/S/` and `~/.config/S/settings.dconf` | `home/dot_config/ostrich-os/`; script `run_onchange_after_ostrich-settings.sh.tmpl` reads the new path and its hash line moves |
| Ghostty theme | `~/.config/ghostty/themes/S` | `…/ostrich-os` |
| Root: helper | `/usr/libexec/S/system-helper` | `/usr/libexec/ostrich-os/system-helper` |
| Root: polkit | `/usr/share/polkit-1/actions/org.S.system-helper.policy`, actions `org.S.system-helper.{graphics,touchscreen,power}` | `org.ostrich-os.system-helper.*` |
| Root: units, udev, state | `S-power.service`, `/etc/udev/rules.d/90-S-touchscreen.rules`, `/var/lib/S/touchscreen.state`, `/run/S` | `ostrich-os-power.service`, `90-ostrich-os-touchscreen.rules`, `/var/lib/ostrich-os/`, `/run/ostrich-os` |
| Image only (not user machines) | `/opt/S`, `/usr/local/sbin/S-portable-esp`, VM dirs `~/.local/share/S/vm` | rename in the same commit; no migration |

Code that names the old ids must change with it: `drawer/extension.js` (`APP_ID`, `APP_PATH`), `focus/{extension,envmanager}.js` (`DRAWER_APP`, `DRAWER_PATH`), `tiling/extension.js` (`HIDDEN_APP_PREFIX`), `monitor/nvidia.js` (the regex `^(ostrich-|ubuntu_ostrich[.-])` decides which apps are "ours"; make it `^(ostrich-|ostrich_os[.-])`), `tools/drawer-host` (data dir at main.rs:48, app id, notification app ids), `tools/ostrich/src/config.rs` (`BASE`), `lib/uninstall.sh`, `install.sh` (`PROJECT`), every `metadata.json`. `rg -i "ubuntu.?ostrich|ostrich.ubuntu|cleanest"` afterwards may only hit this migration code, `docs/council/*` and dated history in `docs/DECISIONS.md`.

CONFLICT: the dock's drawer favourite default and any `favorite-apps` entry reference the drawer's *app id*, so after the id changes they point at nothing and the dock silently loses the drawer icon — RECOMMEND: migrate any `favorite-apps` entry equal to an old drawer/store/setup `.desktop` id in the same step (it is in the table above), and add it to the VM check.

CONFLICT: "re-enable extensions under new UUIDs" cannot finish in the running Wayland session: GNOME Shell discovers new extension directories only at session start — RECOMMEND: the migration installs the new UUIDs, rewrites `enabled-extensions`/`disabled-extensions`, removes the old, and tells the user to log out; it must not claim the extensions are running.

## How the migration runs (idempotent, logged, undoable)

One function set in `lib/migrate.sh`, called by `install.sh` after `take_restore_point` (so the restore point can undo it) and before the modules. Each step: check "old exists and new does not", act, log `migrate: <what> S→ostrich-os`. If both exist, keep the new, rename the old to `<old>.migrated-<date>`, log a warning. `--dry-run` prints the list and changes nothing. Running twice changes nothing the second time. Root-owned items use the installer's existing password prompt (`sudo_install` in `lib/helper.sh`); the migration never runs sudo on its own. Old root files stay until the **next** login so an old extension still loaded in the session can still reach the helper, then a later `--update` removes them (two-phase).

Order matters:

1. **Stop the drawer** (it holds its SQLite files open): ask it to quit over its D-Bus action, wait for the name to drop, `pkill` only as a last resort after 5 s. Never migrate `drawer/` while it runs.
2. **Move the user dirs** (config, data, state, libexec) with `mv` on the same filesystem (an atomic rename); if the target is on another filesystem, copy then verify sizes and `sqlite3 PRAGMA integrity_check` on every `cookies.sqlite` before deleting the source. Moving the directory takes `cookies.sqlite`, its `-wal` and `-shm` files and the WebKit cache with it.
3. **dconf:** `dconf dump` the old path, `dconf load` the new one only when the **new schema is installed** (else defer to the next run), then `dconf reset -f` the old path.
4. **Extensions:** install the new zips, map old UUIDs to new in both GNOME lists, delete old extension dirs.
5. **Desktop files and icons:** regenerate `ostrich_os.*.desktop` (the drawer host writes the per-site files itself at startup, `tools/drawer-host/src/main.rs:150`; verify it does so for every site, not only newly added ones), delete the old `*.desktop` for each slug.
6. **Notification settings** (next section).
7. **Root items** through the helper installer, then `systemctl daemon-reload`, `udevadm control --reload`, polkit is picked up automatically.
8. **chezmoi:** run after the user dirs moved; `chezmoi apply`, then `chezmoi verify` must pass and `chezmoi managed` must list only new paths. Users who exported settings into their **own** dotfiles repo with `ostrich config export …/dot_config/ubuntu-ostrich/settings.dconf` keep that file where it is; the release notes tell them to move it (the migration can't edit their repo).
9. **Restore points:** each existing restore point records absolute paths; rewrite the `source` file and verify `restore.sh` still lists them (test below), or leave old restore points readable under the old name and note it.

## Per-site notification settings

GNOME stores per-app notification choices as relocatable children of `org.gnome.desktop.notifications.application`, at `/org/gnome/desktop/notifications/application/<child>/` with keys `application-id` (the `.desktop` file name), `enable`, `show-banners`, `enable-sound-alerts`, `force-expanded`, `show-in-lock-screen`, `details-in-lock-screen`; the children are listed in `org.gnome.desktop.notifications application-children`. The drawer sends each site's notifications under that site's own app id (`ubuntu_ostrich.drawer.<service>`; `docs/DESIGN.md` drawer section), so each site has its own child. A new id means a **new, empty child**: every site would revert to defaults and users would lose, for example, "banners off" for a noisy chat.

CONFLICT: how a child's name is derived from the app id (dots, case, `.desktop` suffix) and the exact key set were not verified in this session — RECOMMEND: read them from a VM first (`dconf dump /org/gnome/desktop/notifications/` after a drawer site has sent a notification), write the rule down in this file, then implement.

### Notification settings: verified rule

Verified 2026-11-22 in a throwaway lab VM (GNOME Shell 50.1); raw dumps in `docs/plans/evidence/notification-children-dconf.txt`. This replaces the unverified CONFLICT above.

- **Child name** = the app id with `.desktop` removed and every `.` and `_` turned into `-`. `ubuntu_ostrich.drawer.chat.desktop` → child `ubuntu-ostrich-drawer-chat`, at `/org/gnome/desktop/notifications/application/ubuntu-ostrich-drawer-chat/`. The new id `ostrich_os.drawer.chat.desktop` → `ostrich-os-drawer-chat`. (Lower-casing was not exercised: our ids are lower case. The migration lower-cases anyway.) The dash and underscore spellings of one id share a child name; only `application-id` tells them apart, so match on that key, never on the name.
- **Who creates it:** the Shell, on the first notification from an app whose `.desktop` file exists (`desktop-entry` hint); it writes `application-id` and appends the child to `application-children`. A notification from an id with no `.desktop` file creates nothing. So the new `.desktop` files must exist before the new children can appear.
- **Keys:** dconf stores only non-default keys. After switching things off in Settings the child held `enable=false`; later `enable-sound-alerts=false`, `show-banners=false`, `show-in-lock-screen=false`. Full set (`gsettings list-keys`): `application-id`, `details-in-lock-screen`, `enable`, `enable-sound-alerts`, `force-expanded`, `show-banners`, `show-in-lock-screen`. Copying the child with `dconf dump`/`dconf load` and rewriting `application-id` carries all of them, set or not.
- **Settings' own writes** go to the same child, with the master switch as `enable` and Show Banners as `show-banners`.

Migration step: list `application-children`; for every child whose `application-id` matches an old id (`ubuntu_ostrich.drawer*.desktop`, `ubuntu-ostrich.drawer*.desktop`, `ostrich-ubuntu…`, `cleanest…`, and the Store/setup ids), compute the new id (`ostrich_os.drawer.<service>.desktop` etc.), create the new child with a copy of **every key**, append it to `application-children`, then reset the old child and remove it from the list. Skip if the new child already exists (user changed it after upgrade: keep theirs). Log each one. Also move the drawer's own per-site `muted` flag (in `drawer.toml`, which moves with the config dir; nothing to do).

## Drawer logins must survive: VM proof

The risk: if the WebKit data directory is not found at the new path, each site comes back signed out. The proof, `tests/vm/rename-test.sh`, runs from a snapshot with **0.5.0 installed** (the `post-…`/try-me snapshots; the test names the one it uses):

1. Start a tiny local HTTP server in the VM (a stand-in site, no real account): `GET /login` sets a persistent cookie (`Max-Age` one year, `Secure` not set because it is `http://localhost`) and `GET /` answers "signed in as test" when the cookie is present, else "signed out".
2. Add it to the drawer as a site (`ostrich-drawer --add http://localhost:PORT`), open it, visit `/login`, check `/` says "signed in" (read the page text through the drawer's `state` action or a `webkit` screenshot compared by the existing `tests/vm` helpers). Quit the drawer cleanly and confirm `~/.local/share/ubuntu-ostrich/drawer/<site>/data/cookies.sqlite` exists and contains the cookie (`sqlite3 … 'select name from moz_cookies'` or the WebKit schema's table).
3. Run the new `install.sh --update` through the **old** one-liner URL. Assert: the old `drawer/` directory is gone, `~/.local/share/ostrich-os/drawer/<site>/data/cookies.sqlite` exists and has the same cookie row and the same SHA-256 as before.
4. Log out and in (new extensions), open the drawer on that site, and assert `/` still says **"signed in as test"** with no visit to `/login`. This is the pass/fail line: **a signed-in site stays signed in.**
5. Repeat once with a second site and with `drawer.toml`'s per-site `muted=true` to prove the config moved.
6. Negative control: run the test with the migration's move step disabled; assert the site then says "signed out". It proves the test can fail.

Real sites (Google, Slack) are not used: no accounts in test VMs. The stand-in exercises the same cookie store.

## Trademark policy (checked 2026-11-21)

Source: https://ubuntu.com/legal/intellectual-property-policy (302 → https://canonical.com/legal/intellectual-property-policy). Headings: 1 Summary; 2 Relationship to other licences; 3 Your use of Ubuntu; 4 Your use of our trademarks; 5 Your use of our copyright, patent and design materials; 6 Logo use guidelines; 7 Use of Canonical IP by the Ubuntu community; 8 Contact us; 9 Changes.

The fragments below came from a page fetch that summarised the page. **Re-read the full page and paste exact quotes before the README text is final.** Not legal advice.

| Question | Clause (heading) | Effect |
|---|---|---|
| "For Ubuntu 26.04 LTS" | §4: "If you are producing software for use with or on Ubuntu you may reference Ubuntu"; "…provided that you do not imply endorsement" | Descriptive use allowed if endorsement is not implied. This is why the README needs the disclaimer. |
| "Ubuntu" in the name | §4: "You will require Canonical's permission to use: (i) any mark ending with the letters UBUNTU or BUNTU … (ii) any Trademark in a domain name or URL or for merchandising purposes." and "You cannot use the Trademarks in software titles." | "Ubuntu Ostrich" is a trademark in a software title and the repo URL contains it. The rename removes both. A domain with "ubuntu" in it would need permission. |
| Logos | §6: "Canonical's logos are presented in multiple colours and it is important that their visual integrity be maintained."; §4: "…with Canonical's permission in writing." | Use no Ubuntu or Canonical logo. The app icons are original (`tools/icons`). |
| Modified redistribution | §3: "You can redistribute Ubuntu, but only where there has been no modification to it."; "Any redistribution of modified versions of Ubuntu must be approved, certified or provided by Canonical" | The installer script on stock Ubuntu is fine. `image/` ISOs are not, without approval. |

CONFLICT: the name "Ostrich **OS**" says "operating system", but this project is an installer and desktop layer on stock Ubuntu, and `image/build-iso.sh` builds a modified-Ubuntu ISO — RECOMMEND: keep the name if the owner wants it, but publish no ISO until Canonical's terms are cleared for that case.

## Name availability (audit A5)

Free on GitHub (`thehamandbread/ostrich-os`), PyPI, npm, crates.io, Flathub and the Snap Store; one minor "OstrichOS" Google Sites page. No trademark-register search was done; do one before a public launch.

## URLs, and the installer one-liner

The documented install command is **wget** (a fresh Ubuntu 26.04 desktop has wget but neither curl nor git; `docs/DECISIONS.md` 2026-10-20):

```bash
wget -qO- https://raw.githubusercontent.com/thehamandbread/ostrich-os/main/install.sh | bash
```

Update: README, `docs/INSTALLING.md`, `tools/ostrich/src/main.rs:142`, `install.sh` (`REPO_SLUG`, and the `releases/latest` lookup at line 122), `tools/store-core/src/github.rs:201` and the Store's own-update row, `tools/welcome` About text, 11 × `metadata.json` `url`, `.github/workflows/{ci,release}.yml`, `docs/RELEASING.md`. `install.sh` itself uses curl for the API after it has installed it; that is unchanged.

**Existing installs reach the new release only through GitHub's redirect.** Installed 0.5.0 binaries and `ostrich update` carry `thehamandbread/ubuntu-ostrich`. GitHub redirects a renamed repo (web, git, API), and `wget` and `curl -L` follow it. So: **never create a repository named `ubuntu-ostrich`** (it would take over the redirect and strand every old install). Record the rule in `docs/DECISIONS.md` and `docs/RELEASING.md`. Ship the rename plus migration as one release with nothing else in it.

## Test plan (never the live machine)

1. `tests/migrate.bats`: fixture `$HOME` with trees under each of the three slugs (and mixed), fake `dconf`/`gsettings`/`systemctl`; cases: only-old, only-new, both, oldest-and-newest; run twice and assert the second run changes nothing; `--dry-run` changes nothing.
2. `tests/appid-lint.sh` (bats): the dash rule above, over `*.desktop`, Rust app ids, extension constants, D-Bus names.
3. `tests/vm/rename-test.sh`: the drawer login proof above, plus extension re-enable after log-out (`ext-test.sh` on all 11), a drawer notification keeps its per-site choice (set `show-banners=false` for one site under the old id, migrate, send a test notification as the new id, assert no banner and the dconf child matches), dock keeps the drawer icon, `polkit-test.sh` passes, `ostrich uninstall` restores a pre-migration restore point.
4. Old-URL check with wget, before and after the GitHub rename (the owner runs the after-rename one; nothing is created):
   ```bash
   wget --spider -S https://raw.githubusercontent.com/thehamandbread/ubuntu-ostrich/main/install.sh 2>&1 | grep -E 'HTTP/|Location:'
   wget -qO- -S https://api.github.com/repos/thehamandbread/ubuntu-ostrich/releases/latest 2>&1 >/dev/null | grep -E 'HTTP/|Location:'
   wget --spider -S https://github.com/thehamandbread/ubuntu-ostrich/releases/download/v0.5.0/SHA256SUMS 2>&1 | grep -E 'HTTP/|Location:'
   ```
   Pass = each chain ends in `200 OK` at the `ostrich-os` slug. Also run the old one-liner with `-- --dry-run` in the Docker image. Unverified until run: that `raw.githubusercontent.com` follows the rename the same way `github.com` does.
5. Docker smoke (`tests/Dockerfile`, tag renamed): dry run, then two real runs, idempotent.
6. `rg -i "ubuntu.?ostrich|ostrich.ubuntu|cleanest"` returns only the allowed leftovers.
