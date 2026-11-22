# 01 — Rename to Ostrich OS

Spec (kept as written):

- Product **Ostrich OS**; repo slug `ostrich-os`; CLI `ostrich`; config `~/.config/ostrich`; data `~/.local/share/ostrich`.
- "Ubuntu" only descriptively ("for Ubuntu 26.04 LTS"). No Ubuntu/Canonical logos. README notice: "Ubuntu is a registered trademark of Canonical Ltd. Ostrich OS is not affiliated with or endorsed by Canonical."
- Updater migration for every persisted identifier from audit A2: rename/move, re-enable extensions under new UUIDs, remove old, idempotent, logged.
- Update every URL; the GitHub redirect is a safety net only. Verify the old installer URL still resolves after the rename with `curl -IL`. Never recreate a repo at the old name.

CONFLICT: the spec names config and data dirs but not the **state** dir (`~/.local/state/ubuntu-ostrich/`: restore points, `install.log`, `source`) — RECOMMEND: add `~/.local/state/ostrich/`; uninstall depends on the restore points in it.

CONFLICT: the CLI is already `ostrich` (and `ostrich-setup`, `ostrich-drawer`, `ostrich-store-*`); only the *directories, IDs and UUIDs* carry "ubuntu-ostrich" — RECOMMEND: treat "CLI `ostrich`" as already done; no binary rename, only `ostrich update` / `ostrich uninstall` need the new slug and new paths.

CONFLICT: the name "Ostrich **OS**" says "operating system", but this project is an installer plus desktop layer on stock Ubuntu; `image/` builds an ISO (`image/build-iso.sh`), which is redistribution of a modified Ubuntu — RECOMMEND: keep the name if wanted, but treat the ISO as separate: Canonical's policy requires approval for modified redistribution regardless of the product name (quoted below); do not publish an ISO under any name until Canonical's terms are read for that case.

## Trademark policy (checked 2026-11-21)

Source: https://ubuntu.com/legal/intellectual-property-policy (302 → https://canonical.com/legal/intellectual-property-policy). Headings: 1 Summary; 2 Relationship to other licences; 3 Your use of Ubuntu; 4 Your use of our trademarks; 5 Your use of our copyright, patent and design materials; 6 Logo use guidelines; 7 Use of Canonical IP by the Ubuntu community; 8 Contact us; 9 Changes.

The fragments below came from a page fetch that summarised the page, so they are fragments. **Re-read the full page and paste exact quotes before README text is finalised.** Not legal advice.

| Question | Relevant clause (heading) | Effect on us |
|---|---|---|
| "For Ubuntu 26.04 LTS" | §4: "If you are producing software for use with or on Ubuntu you may reference Ubuntu"; "You can use the Trademarks in discussion, commentary, criticism or parody, provided that you do not imply endorsement" | Descriptive use is allowed if it does not imply endorsement. This is why the README needs the disclaimer. |
| "Ubuntu" inside the product name | §4: "You will require Canonical's permission to use: (i) any mark ending with the letters UBUNTU or BUNTU … (ii) any Trademark in a domain name or URL or for merchandising purposes." and "You cannot use the Trademarks in software titles." | **"Ubuntu Ostrich" is a trademark inside a software title, and the repo URL `…/ubuntu-ostrich` contains it.** The rename removes both. Domain names containing "ubuntu" would need permission. |
| Logos | §6: "Canonical's logos are presented in multiple colours and it is important that their visual integrity be maintained."; §4: "…with Canonical's permission in writing." | Use no Ubuntu or Canonical logo or the circle-of-friends. The existing app icons are original (`tools/icons`). |
| Modified redistribution (ISO, remix) | §3: "You can redistribute Ubuntu, but only where there has been no modification to it."; "Any redistribution of modified versions of Ubuntu must be approved, certified or provided by Canonical" | The installer script on stock Ubuntu is fine. `image/` ISOs are not, without approval or a rename plus mark removal. |

README notice (verbatim from spec): "Ubuntu is a registered trademark of Canonical Ltd. Ostrich OS is not affiliated with or endorsed by Canonical."

## Name availability (see A5 in `00-audit.md`)

Free on GitHub (`thehamandbread/ostrich-os`), PyPI, npm, crates.io, Flathub, Snap Store; one minor "OstrichOS" Google Sites page. No trademark-office search was done — do one before a public launch.

## What changes

### Renamed values

| Old | New |
|---|---|
| Product text "Ubuntu Ostrich" | "Ostrich OS" |
| `PROJECT=ubuntu-ostrich` | `PROJECT=ostrich` |
| `~/.config/ubuntu-ostrich/` | `~/.config/ostrich/` |
| `~/.local/share/ubuntu-ostrich/` | `~/.local/share/ostrich/` |
| `~/.local/state/ubuntu-ostrich/` | `~/.local/state/ostrich/` |
| `~/.local/libexec/ubuntu-ostrich/` | `~/.local/libexec/ostrich/` |
| `/usr/libexec/ubuntu-ostrich/system-helper` | `/usr/libexec/ostrich/system-helper` |
| `/var/lib/ubuntu-ostrich/`, `/run/ubuntu-ostrich` | `/var/lib/ostrich/`, `/run/ostrich` |
| `ubuntu-ostrich-power.service` | `ostrich-power.service` |
| `90-ubuntu-ostrich-touchscreen.rules` | `90-ostrich-touchscreen.rules` |
| polkit `org.ubuntu-ostrich.system-helper.*` | `org.ostrich.system-helper.*` |
| gsettings `org.gnome.shell.extensions.ubuntu-ostrich.<ext>` | `org.gnome.shell.extensions.ostrich.<ext>` |
| dconf `/org/gnome/shell/extensions/ubuntu-ostrich/` | `/org/gnome/shell/extensions/ostrich/` |
| UUID `<ext>@ubuntu-ostrich` (×11) | `<ext>@ostrich` |
| zip `<uuid>.shell-extension.zip` | follows the new UUID |
| GApplication `ubuntu-ostrich.drawer`, path `/ubuntu_ostrich/drawer`, `ubuntu-ostrich.drawer.<service>` | `ostrich.drawer`, `/ostrich/drawer`, `ostrich.drawer.<service>` |
| `.desktop`: `ubuntu-ostrich.{store,setup,drawer}.desktop` | `ostrich.{store,setup,drawer}.desktop` |
| `ghostty/themes/ubuntu-ostrich` | `ghostty/themes/ostrich` |
| chezmoi `home/dot_config/ubuntu-ostrich/` | `home/dot_config/ostrich/` (+ update the `settings.dconf` path and hash line in `run_onchange_after_ostrich-settings.sh.tmpl`) |
| Repo `thehamandbread/ubuntu-ostrich` | `thehamandbread/ostrich-os` |

CONFLICT: the spec's ISO/image and VM-test paths (`~/.local/share/ubuntu-ostrich/vm`, `/opt/ubuntu-ostrich`) are dev/image-only, not user machines — RECOMMEND: rename them too in the same commit, but they need no migration.

CONFLICT: "re-enable extensions under new UUIDs" cannot take effect in the running Wayland session — GNOME Shell discovers new extension directories only at session start — RECOMMEND: the migration installs the new UUIDs, writes them to `enabled-extensions` (and removes the old), then tells the user to log out; do not try `gnome-extensions enable` and report success.

### Migration (one idempotent step in `lib/migrate.sh`, run first by `install.sh` and `install.sh --update`)

Idempotency rule: each step checks "old exists and new does not"; if both exist, keep new, rename old to `<old>.migrated-<date>` and log. Every step logs `migrate: <what>` to the install log. `--dry-run` prints without acting. Back up first through the existing restore point (`take_restore_point` already runs before modules; migration must run **after** it so uninstall can undo).

1. **User directories** (config, data, state, libexec): `mv` old → new if new absent. Data includes `drawer/<service>/` with logins and cookies: moving the directory keeps the sessions. State includes `backups/`: any restore point records absolute paths, so rewrite the `source` file and verify `restore.sh` still finds its files (test below).
2. **dconf:** `dconf dump /org/gnome/shell/extensions/ubuntu-ostrich/ | dconf load /org/gnome/shell/extensions/ostrich/`, then `dconf reset -f` the old path. Per-extension schema ID changes only take effect once the new extension version is installed; migrate settings only when the new schema is present (`gsettings list-schemas | grep …ostrich`), else defer to the next run.
3. **Extensions:** install new-UUID zips; read `org.gnome.shell enabled-extensions` and `disabled-extensions`, map every `*@ubuntu-ostrich` to `*@ostrich`, write back; delete `~/.local/share/gnome-shell/extensions/*@ubuntu-ostrich` after the new ones are in place; the extension's own pinned/ordered lists (e.g. `favorite-apps`, drawer `pinned-apps`, dock) do not reference UUIDs and need no change (verify with `rg '@ubuntu-ostrich' $(dconf dump /)`).
4. **Desktop files and icons:** regenerate `ostrich.*.desktop`; delete `~/.local/share/applications/ubuntu-ostrich.*.desktop` and the generated per-site `ubuntu-ostrich.drawer.<service>.desktop`. **Notification permissions in GNOME are keyed by app ID**, so each drawer site will ask/reset once; document it in the release notes. Move `autostart/ostrich-setup.desktop` only if the wizard is unfinished.
5. **User units:** disable `ostrich-store-updates.timer` (name unchanged), reload; nothing to rename.
6. **Root-owned items** (need the existing password prompt through the installer's `sudo_install`; this plan never runs sudo itself): install the new helper at `/usr/libexec/ostrich/system-helper` and polkit policy `org.ostrich.system-helper.policy`, `ostrich-power.service`, `90-ostrich-touchscreen.rules`, move `/var/lib/ubuntu-ostrich/touchscreen.state`, then remove the old files, `systemctl disable --now ubuntu-ostrich-power.service`, `systemctl daemon-reload`, `udevadm control --reload`. Old callers (an old extension still loaded in the session) would invoke the old polkit action; keep the **old policy and helper until the next login** and remove them in the following run (two-phase), logged.
7. **chezmoi:** chezmoi tracks source paths in `~/.local/share/chezmoi`/its state; changing `home/dot_config/ubuntu-ostrich` to `home/dot_config/ostrich` makes `chezmoi apply` create the new files and leave the old ones. Migration moves the old dir first (step 1), then `chezmoi apply`; verify `chezmoi managed` lists only new paths and `chezmoi verify` passes.
8. **Old `ostrich` CLI state:** `ostrich update` reads `…/state/<old>/source`; migrate it in step 1.

### Bootstrapping the first update (the chicken-and-egg)

The installed 0.5.0 binaries have the old slug and the old paths baked in. `install.sh --update` and the Store's Updates tab fetch `https://api.github.com/repos/thehamandbread/ubuntu-ostrich/releases/latest`. GitHub redirects renamed repos (HTTP 301 for `api.github.com/repos/<old>` and for `github.com/<old>`; this needs `-L`), so old installs still find the new release and its `install.sh`. The new `install.sh` then runs the migration. The redirect is the *only* path for existing installs, so:

- **Never create a new repo named `ubuntu-ostrich`** (it would take over the redirect and strand every old install). Add this as a rule in `docs/DECISIONS.md` and the release checklist.
- Ship one release (0.6.0) that is the rename + migration and nothing else.

### URLs to update (all of them)

README (`wget` one-liner), `docs/INSTALLING.md`, `docs/DESIGN.md`, `tools/ostrich/src/main.rs:142`, `install.sh` (`REPO_SLUG`, `REPO_REF` lookup line 122), `tools/store-core/src/github.rs` and Store's "Ostrich updates" row, `tools/welcome` About text, 11 × `metadata.json` `url`, `.github/workflows/{ci,release}.yml`, `docs/RELEASING.md`. Search `rg "ubuntu-ostrich|Ubuntu Ostrich"` after; the only allowed leftovers are `docs/council/*`, `docs/DECISIONS.md` history lines and the migration code itself.

## Test plan

Never on the live machine. Docker smoke test and VM (`tests/vm/`):

1. **Unit (bats)** `tests/migrate.bats`: fixture `$HOME` with old dirs, a fake `dconf`/`gsettings`, both-exist and only-old and only-new cases; run twice, assert the second run changes nothing.
2. **VM upgrade test** (`tests/vm/rename-test.sh`): restore snapshot with 0.5.0 installed and a signed-in drawer site, run the new `install.sh --update` via the **old** URL; assert: old dirs gone, logins kept, `enabled-extensions` has only `@ostrich` UUIDs after re-login, `ext-test.sh` passes, `ostrich uninstall` restores a pre-migration restore point, polkit actions answer (`tests/vm/polkit-test.sh`).
3. **Redirect check, before and after the GitHub rename** (run by the owner, nothing is created):
   ```bash
   curl -sIL https://raw.githubusercontent.com/thehamandbread/ubuntu-ostrich/main/install.sh | grep -iE '^(HTTP|location)'
   curl -sIL https://api.github.com/repos/thehamandbread/ubuntu-ostrich/releases/latest | grep -iE '^(HTTP|location)'
   curl -sIL https://github.com/thehamandbread/ubuntu-ostrich/releases/download/v0.5.0/SHA256SUMS | grep -iE '^(HTTP|location)'
   ```
   Pass = each ends in `200` for the new slug. Record the outputs in the release notes. Also run `wget -qO- <old url> | bash -s -- --dry-run` in the Docker image.
   Unverified until run: that `raw.githubusercontent.com` follows the repo rename the same way `github.com` does. If it does not, the old one-liner breaks for people who copied it, and the README must say so.
4. **Docker smoke** (`tests/Dockerfile`, tag renamed): dry run, then two real runs, still idempotent.
5. `rg -i "ubuntu.?ostrich"` returns only the allowed leftovers.
