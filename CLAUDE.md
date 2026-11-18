# CLAUDE.md

A distributable, opinionated Ubuntu desktop setup: dotfiles + system configuration + an installer anyone can run with one terminal command.

## Project facts

- Base OS target: **Ubuntu 26.04 LTS (Resolute Raccoon), GNOME 50, amd64.** Primary dev machine: Dell Precision 5570, NVIDIA RTX A2000 (Optimus hybrid graphics).
- Two layers:
  1. **System layer**: idempotent, modular Bash scripts (`modules/`) for apt/flatpak/snap packages, GNOME extensions, `gsettings`/`dconf`, services, and hardware-specific tweaks. Hardware modules (NVIDIA/Optimus, Dell, power) run ONLY when detection confirms the hardware.
  2. **Dotfiles layer**: **chezmoi** (2.7x series; 2.73.2 at setup). The source directory is `home/` via `.chezmoiroot`. Machine differences are handled with chezmoi templates, not copies.
- Entry point: `install.sh` at the repo root, runnable as `wget -qO- <url>/install.sh | bash` (stock Ubuntu has no curl or git). It must be idempotent, back up anything it would overwrite, and support `--dry-run`.
- Installer choices are made in the GTK4 welcome wizard after install; `whiptail` is only the no-GUI fallback (see `docs/DECISIONS.md`).
- Quality tools: `shellcheck`, `shfmt`, `bats`, `gitleaks` (pre-commit hook + CI).
- The user works from the terminal (Ghostty).
- Licensing: MIT, except `modules/gnome/extensions/` which is GPL-2.0-or-later.

## Conflict rule

When a skill or doc written for an older version (older Ubuntu, older GNOME, older chezmoi) conflicts with current official documentation, **the current version wins.** GNOME extensions and gsettings keys change between GNOME versions; always verify against GNOME 50.

## Layout

```
install.sh              bootstrap entry point
lib/                    shared helpers: logging, os/hardware detection, prompts, backup
modules/                one folder per module, each with install.sh
  core/ terminal/ tools/ gnome/ dev/ apps/ claude-code/
  gnome/extensions/     user-authored GNOME Shell extensions (GPL-2.0-or-later)
  hardware/nvidia-optimus/ hardware/dell/ hardware/power/
home/                   chezmoi source directory (.chezmoiroot = home)
tests/                  bats tests + Dockerfile (ubuntu:26.04 smoke test)
docs/DESIGN.md          design source of truth
docs/DECISIONS.md       log of keep/cut/add decisions
docs/INVENTORY.md       audit of the original machine (private: gitignored, kept on disk)
.githooks/pre-commit    gitleaks hook (enabled with core.hooksPath)
.github/workflows/      CI
```

## Commands

```bash
./install.sh --dry-run
shellcheck install.sh lib/*.sh modules/*/install.sh modules/hardware/*/install.sh modules/gnome/extensions/build.sh modules/gnome/extensions/*/*.sh tests/*.sh tests/vm/*.sh modules/tools/ostrich-icon-style tools/package.sh tools/icons/export.sh .claude/skills/ostrich-design/scripts/*.sh image/*.sh image/firstboot/*.sh .githooks/pre-commit
tests/lint-js.sh                     # ESLint for extensions, in Docker
modules/gnome/extensions/build.sh    # build extension zips into dist/
tools/icons/export.sh                # remake the app icons from tools/icons/ (see its README)
tests/vm/ext-test.sh <name>...       # install in the VM, check ACTIVE / no JS errors / 20 enable-disable cycles
tests/look-check.sh [--vm SNAP]      # the look's lint (CI runs it) and, with --vm, the VM look tests: focus rings, widths, text scale, alert, a11y
.claude/skills/ostrich-design/scripts/token-lint.sh   # sizes with tokens, fixed colours, :focus rules, dim-label (exceptions: token-lint: allow <why>)
shfmt -d .
bats tests/
tests/vm/vm.sh check                 # VM harness prerequisites (see tests/vm/README.md)
tests/vm/critique.sh list            # the user's critiques from the VM (Super+Alt+C); /critiques plans fixes
tests/vm/evidence.sh DIR              # the design council's evidence pack (measurements, side-by-sides, notes)
tests/vm/contrast.sh IMG X0,Y0,X1,Y1  # text contrast per line in a screenshot (4.5:1 floor)
tests/vm/polkit-test.sh              # the helper's polkit actions: which ask for a password
tests/vm/dconf-test.sh               # settings survive dump/reset/load; ostrich config end to end
tests/vm/lab.sh book SEAT            # a throwaway copy of try-me for council seats (2 slots; see its header)
# /council [--panel ...] AGENDA      the design council: 12 advocates debate, a judge rules (docs/council/)
docker build -f tests/Dockerfile -t ubuntu-ostrich-test . && docker run --rm ubuntu-ostrich-test
gitleaks git --redact          # full-history secret scan
git config core.hooksPath .githooks   # once per clone, enables the pre-commit hook
```

## Rules

- `docs/DESIGN.md` is the source of truth. Read it before building. Don't invent design decisions; ask.
- This machine is the user's live system. Never apply the installer, chezmoi, or gsettings changes to it unless the user explicitly says so in that session. Test in Docker or a VM.
- Never run `sudo`. Print the command for the user and wait for them to run it.
- Every module must be idempotent, support `--dry-run`, back up before overwriting, and log what it changed.
- Hardware-specific modules must detect hardware first and no-op cleanly on other machines.
- Never commit secrets, credentials, tokens, SSH keys, hostnames, or personal data. Claude Code: commit portable config only (settings, CLAUDE.md, agents, commands, skills, hooks, plugin/marketplace declarations), never credentials, history, projects, todos, or caches.
- Never commit third-party assets (wallpapers, fonts, icon/GTK themes); the installer downloads them from upstream at install time, pinned to versions.
- Pin third-party downloads to versions and verify checksums or signing keys where upstream provides them. No `curl | bash` of third-party scripts inside modules without the user's approval.
- Small, focused changes. Explain the plan before large changes. Run shellcheck and tests after changes. Commit after each working change with a clear message. Never force-push.
