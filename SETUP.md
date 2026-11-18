# Project Setup Instructions (for Claude Code)

You are setting up a new project: a **distributable, opinionated Ubuntu desktop setup** (dotfiles + system configuration + an installer that anyone can run with one terminal command). This session is SETUP ONLY. Do not build installer modules or migrate configs yet; that happens after planning.

Follow every phase in order. After each phase, report what you did and what you found. **Stop and ask the user** whenever a step needs `sudo`, a login, a browser, or a decision. **Never run `sudo` yourself**; print the exact command and wait for the user to run it.

**This machine is the user's live daily system. Phases 1–3 are READ-ONLY. Do not change, move, delete, or overwrite any file outside the new project folder.**

## Project facts

- Base OS target: **Ubuntu 26.04 LTS (Resolute Raccoon), GNOME 50, amd64.** Primary dev machine: Dell Precision 5570, NVIDIA RTX A2000 (Optimus hybrid graphics).
- Architecture (two layers):
  1. **System layer**: idempotent, modular Bash scripts (`modules/`) for apt/flatpak/snap packages, GNOME extensions, `gsettings`/`dconf`, services, hardware-specific tweaks. Hardware-specific modules (NVIDIA/Optimus, Dell, TLP) run ONLY when detection confirms the hardware.
  2. **Dotfiles layer**: **chezmoi** (current 2.7x series; confirm exact latest on github.com/twpayne/chezmoi/releases). Source directory lives in `home/` via a `.chezmoiroot` file. Machine differences handled with chezmoi templates, not copies.
- Entry point: `install.sh` at repo root, runnable as `curl -fsSL <url>/install.sh | bash`. It must be safe to re-run (idempotent), must back up anything it would overwrite, and must support `--dry-run`.
- Prompts in the installer use `whiptail` (preinstalled on Ubuntu) unless a decision says otherwise.
- Quality tools: `shellcheck`, `shfmt`, `bats` (tests), `gitleaks` (secret scanning, pre-commit + CI).
- The user works with you from the terminal (Ghostty).

---

## Phase 1: Check the tools (read-only)

Run and report versions of: `git`, `gh`, `claude`, `chezmoi`, `shellcheck`, `shfmt`, `bats`, `gitleaks`, `docker` (or `podman`), `whiptail`, `jq`.

For anything missing, give the exact install command for Ubuntu 26.04 (prefer the Ubuntu archive; if not in the archive, give the official upstream method and say so). Wait for the user to confirm before continuing.

Check `git config --global user.name` and `user.email`. If empty, ask for the values and set them.

## Phase 2: Connect GitHub

1. Run `gh auth status`.
2. If not logged in, tell the user to run `gh auth login` themselves (interactive, opens a browser). SSH auth to GitHub is already set up on this machine; prefer the SSH protocol when gh asks.
3. After they confirm, run `gh auth status` again.

## Phase 3: Audit the current system (READ-ONLY)

Goal: produce `docs/INVENTORY.md`, a complete, factual inventory of the user's current setup so planning can decide what to keep, cut, or add. Do not copy any config into the repo yet.

Collect and summarize (group by category, one line per item, note the source/install method):

1. **Packages**: `apt-mark showmanual` (filter out packages that came with the base install where you can tell, e.g. compare against `/var/log/installer/` manifests if present), `snap list`, `flatpak list --app --columns=application,origin`, anything in `/opt`, AppImages, `~/.local/bin`, `~/bin`, `cargo install --list`, `pipx list`, `npm -g ls --depth=0`, `mise`/`asdf` if present.
2. **APT sources and keys**: list files in `/etc/apt/sources.list.d/` (third-party repos/PPAs).
3. **GNOME**: `gnome-extensions list --enabled` and `--disabled` with versions; `dconf dump /org/gnome/shell/`, `/org/gnome/desktop/`, `/org/gnome/mutter/`, `/org/gnome/settings-daemon/plugins/media-keys/` (custom keybindings). Summarize what is non-default. Do NOT dump all of dconf.
4. **Terminal/shell**: shell in use, `~/.bashrc`/`~/.zshrc`, Ghostty config, Starship config, fonts in `~/.local/share/fonts` and installed Nerd Fonts, colorscheme.
5. **Dotfiles**: list config dirs in `~/.config` and dotfiles in `~` that are user-modified (skip caches and app state).
6. **Services and scheduled jobs**: `systemctl --user list-unit-files --state=enabled`, user units in `~/.config/systemd/user`, `crontab -l`, autostart entries in `~/.config/autostart`.
7. **System-level changes**: TLP config (`/etc/tlp.conf`, `/etc/tlp.d/`), whether `power-profiles-daemon` is installed/masked, `prime-select query`, NVIDIA driver version (`nvidia-smi` or `modinfo nvidia`), any edited files in `/etc` you can detect (e.g. `debsums -ce` if available; otherwise skip and say so).
8. **Claude Code**: describe the structure of `~/.claude/` (settings, CLAUDE.md, agents, commands, skills, hooks, plugins, marketplaces, MCP config). List names only. **Never print the contents of credential or token files.** Note which items are portable config versus machine state/history/caches.
9. **Secrets risk list**: list every file found above that contains or may contain secrets, tokens, keys, hostnames, or personal data (SSH keys, `.credentials.json`, `.netrc`, API keys in rc files, Nextcloud config, browser profiles). These must never be committed.

Write `docs/INVENTORY.md` with these sections and a short "Hardware-specific items" section listing everything that only makes sense on this Dell/NVIDIA machine. Report a summary count per category.

## Phase 4: Create the project skeleton

Create this layout (empty files with a one-line header comment are fine; no real logic yet):

```
install.sh              # bootstrap entry point (stub: prints usage, supports --dry-run)
lib/                    # shared helpers: logging, os/hardware detection, prompts, backup
modules/                # one folder per module, each with install.sh (stubs only)
  core/  terminal/  gnome/  dev/  apps/  claude-code/
  hardware/nvidia-optimus/  hardware/dell/  hardware/power/
home/                   # chezmoi source directory
.chezmoiroot            # contains: home
tests/                  # bats tests + Dockerfile for an ubuntu:26.04 smoke test
docs/DESIGN.md          # title line only. Design source of truth.
docs/DECISIONS.md       # title line only. Log of keep/cut/add decisions.
docs/INVENTORY.md       # from Phase 3
README.md               # title + one-line description + "work in progress"
LICENSE                 # MIT unless the user says otherwise (ask)
```

Write the smallest real working version of `install.sh` only for: `set -euo pipefail`, OS check (refuse to run unless `/etc/os-release` reports Ubuntu 26.04; allow `--force` to override with a warning), refuse to run as root, `--dry-run` flag, and a log file in `~/.local/state/<project>/install.log`. Run `shellcheck` and `bash -n` on it; both must pass.

## Phase 5: Skills and plugins

### 5a. Official skills (primary)
Check whether chezmoi or any other tool in the stack ships official agent skills (a `skills/` folder in its repo or docs for AI agents). If found, copy into `.claude/skills/` and list them. If none exist, say so and skip.

### 5b. Third-party skills/plugins (only with approval)
Do not install any. If you know of a relevant one (e.g. for Bash/shellcheck work), report its repo, what it runs, and any network calls or install scripts, and wait for approval.

### Conflict rule
When a skill or doc written for an older version (older Ubuntu, older GNOME, older chezmoi) conflicts with current official documentation, **the current version wins.** GNOME extensions and gsettings keys change between GNOME versions; always verify against GNOME 50.

## Phase 6: CLAUDE.md

Create `CLAUDE.md` containing: the project facts above, the conflict rule, the folder layout, the commands (`./install.sh --dry-run`, `shellcheck **/*.sh`, `shfmt -d .`, `bats tests/`, the Docker smoke test command), and these rules:

- `docs/DESIGN.md` is the source of truth. Read it before building. Don't invent design decisions; ask.
- This machine is the user's live system. Never apply the installer, chezmoi, or gsettings changes to it unless the user explicitly says so in that session. Test in Docker or a VM.
- Never run `sudo`. Print the command for the user.
- Every module must be idempotent, support `--dry-run`, back up before overwriting, and log what it changed.
- Hardware-specific modules must detect hardware first and no-op cleanly on other machines.
- Never commit secrets, credentials, tokens, SSH keys, hostnames, or personal data. Claude Code: commit portable config only (settings, CLAUDE.md, agents, commands, skills, hooks, plugin/marketplace declarations), never credentials, history, projects, todos, or caches.
- Pin third-party downloads to versions and verify checksums or signing keys where upstream provides them. No `curl | bash` of third-party scripts inside modules without the user's approval.
- Small, focused changes. Explain the plan before large changes. Run shellcheck and tests after changes. Commit after each working change with a clear message. Never force-push.

## Phase 7: Git, secret scanning, CI

1. Create `.gitignore` (OS files, logs, `*.bak`, local state, any secret file patterns from Phase 3).
2. Set up `gitleaks` as a pre-commit hook (plain `.git/hooks/pre-commit` or the `pre-commit` framework; ask the user which). Run a full scan of the repo; it must be clean.
3. `git init`, add, and make the initial commit.
4. Ask the user for the repo name. Recommend **private** until the first full secret audit is done, then flip to public.
5. `gh repo create <name> --private --source=. --push` (or `--public` if the user chooses).
6. Create `.github/workflows/ci.yml`: shellcheck, shfmt check, gitleaks, and bats running inside an `ubuntu:26.04` container. Check whether GitHub currently offers an `ubuntu-26.04` hosted runner; if not confirmed, use `ubuntu-latest` with `container: ubuntu:26.04`. Push and report the Actions result.

## Phase 8: Final report

Give a checklist of every phase (done / skipped / needs action), the tool versions, the inventory summary counts, the secrets risk list (paths only), the repo URL, the CI result, and anything the user must do manually. **Do not start building modules or migrating configs.**
