# 04 — Crash → agent diagnosis

Depends on 01 (names), 02 (options, agent choice in Settings), 05 (consent screen and notification copy).

## Spec (kept as written)

- Classes: (a) process crash including gnome-shell (session logout); (b) whole-system crash, freeze or panic, detected at next login.
- (a) If `core_pattern` → systemd-coredump: follow the journal for the coredump `MESSAGE_ID`. If apport: a `systemd --user` path unit on `/var/crash/*.crash`. Don't replace apport by default; "Use systemd-coredump" is an advanced option only if A3 proves apport keeps working.
- (b) A login-time user service checks the previous boot: `/var/lib/systemd/pstore`, kernel crash files in `/var/crash`, and whether the previous boot's journal lacks a clean shutdown sequence. Define and test the heuristic.
- Notification with actions "Diagnose with <agent>" / "Ignore"; `ostrich crash mute <exe>`; rate limit 1 per exe per 10 min.
- Diagnose opens the user's terminal running the chosen agent CLI with the `diagnose-crash` skill and a local report. Agents detection-gated: `claude`, `codex`, `gemini`, `opencode`; default in `~/.config/ostrich/agent`; none installed → open the report in a text editor with instructions.
- Report (never the raw core): exe, package+version (`dpkg -S`), signal, backtrace (`coredumpctl` / `gdb -batch` with debuginfod), last 200 relevant journal lines, kernel + GPU driver versions (`nvidia-smi` if present), Ostrich version. Redact: `$HOME`→`~`, username, hostname, emails, IPs, MACs; run gitleaks on the bundle and drop flagged lines. First use: consent screen naming the provider the data goes to.
- `diagnose-crash` skill is read-only: classify the component (Ostrich-owned / Ubuntu package / third-party / hardware-driver), explain, propose a fix; no sudo, edits or installs without explicit in-session approval.
- Contribute: Ostrich-owned → `gh issue create --web` prefilled against the Ostrich repo (user reviews, nothing auto-posted); Ubuntu package → suggest `ubuntu-bug <pkg>`; third-party → link their tracker.
- Also ship an `ostrich` skill: system layout, change settings via the options schema/CLI, never hand-edit chezmoi-managed files.
- Check each agent CLI's current official docs for how it loads skills/instructions; plan install paths per agent.

## Evidence this plan rests on

From audit A3 (container) and the web checks (2026-11-21):

- Stock Ubuntu sets `kernel.core_pattern` at boot from `apport.service` (package `apport-core-dump-handler`); there is **no** sysctl.d file for it on stock Ubuntu. `systemd-coredump` (universe, 259.9) installs `50-coredump.conf` setting `kernel.core_pattern=|/usr/lib/systemd/systemd-coredump …`, which sorts after Debian's `10-coredump-debian.conf` (`core`), so it wins; it **Conflicts** with `apport-core-dump-handler` (apt removes it).
- With `systemd-coredump` active, `apport` still gets crashes through the drop-in `systemd-coredump@.service.d/apport-coredump-hook.conf` (`OnSuccess=apport-coredump-hook@%i.service` → `apport --from-systemd-coredump`, writes `/var/crash/*.crash`). That is apport ≥ 2.28 (Launchpad #2048136, Fix Released). Open risk: Launchpad #2139266 (Jan 2026) reports the hook needs `python3-systemd` on 26.04; unverified for apport 2.34.1.
- Coredump journal `MESSAGE_ID`: `fc2e22bc6ee647b6b90729ab34a250b1` (systemd catalog, https://systemd.io/CATALOG/; subject "Process @COREDUMP_PID@ (@COREDUMP_COMM@) dumped core"). systemd docs name **no** `MESSAGE_ID` for pstore; match `_SYSTEMD_UNIT=systemd-pstore.service` instead.
- Archive versions available: `gdb 17.1`, `debuginfod 0.194`, `libnotify-bin 0.8.8`, `gh 2.46.0`, `gitleaks 8.16.0`, `xdg-terminal-exec 0.14.0`, `jq 1.8.1`.

## CONFLICTs and open points

CONFLICT: "follow the journal for the coredump `MESSAGE_ID`" **or** apport path unit — which one is active depends on the machine, and stock Ubuntu desktop uses apport (the dev host showed `apport-core-dump-handler` installed, `systemd-coredump` not) — RECOMMEND: the watcher reads `/proc/sys/kernel/core_pattern` at start and again on a `core_pattern` change (re-read at each login) and starts **one** source: starts the apport path unit if the pattern starts with `|/usr/share/apport/apport`, the journal follower if it starts with `|/usr/lib/systemd/systemd-coredump`, and neither (with a one-line log) otherwise. On systemd-coredump machines with apport's drop-in both fire for one crash; dedupe by crash PID+timestamp key.

CONFLICT: "Use systemd-coredump = advanced option only if A3 proves apport keeps working" — A3 shows the drop-in exists, but **a real kernel crash was not produced** in a container, and #2139266 is unresolved in evidence — RECOMMEND: ship the option **disabled and hidden** until a VM test passes: install `systemd-coredump` (needs root, one polkit action; also pulls the package removal of `apport-core-dump-handler`, shown to the user in Review), run `sleep 100 & kill -SEGV $!`, assert `/var/crash/*.crash` appears **and** `coredumpctl list` has the entry **and** `ubuntu-bug`/Apport's own dialog still works. Only then set `detect` to visible. Revert = `apt install apport-core-dump-handler` (removes `systemd-coredump`).

CONFLICT: "notification with actions via libnotify (`notify-send --action`)" — the binary supports `--action`/`--wait` (confirmed, `--help` output in audit A3) but the repo records that GNOME 50 dropped actions from `notify-send` (CONTEXT 2026-11-18); upstream sources found no explanation, so that note is **unverified** — RECOMMEND: follow the repo: send notifications from a small app that owns an app ID, through `GApplication`/`g_notification_send` (what `drawer-host` and the Store already use, `org.gtk.Notifications.AddNotification`) with `GNotification` buttons that map to `app.diagnose`/`app.ignore` actions. This also gives a proper "Ostrich" entry in Settings → Notifications. Test `notify-send --action` in the VM once and record the result in `docs/DECISIONS.md`.

CONFLICT: "Agents: `claude`, `codex`, `gemini`, `opencode`" — Gemini's own docs say Gemini CLI was **replaced by Antigravity CLI on 2026-06-18 for unpaid-tier and Google One users** (one source, unverified), so `gemini` may be absent or limited — RECOMMEND: keep `gemini` in the detection list (harmless if absent), add an `agents.d/` drop-in format (below) so a new CLI is data, not code, and re-check the Gemini/Antigravity situation before release.

CONFLICT: "run gitleaks on the bundle" — the archive has **gitleaks 8.16.0**; its CLI is `gitleaks detect --no-git --source <dir> --report-format json` (8.19+ renamed this to `gitleaks dir`). The repo's own scripts use a newer gitleaks installed at `~/.local/bin` on the dev machine, which a user does not have — RECOMMEND: detect version (`gitleaks version`) and pick the syntax; the **built-in redaction pass is the primary protection** (always on), gitleaks is a second pass when present, and if it is absent the consent screen says "no secret scan available" instead of claiming one ran. Add `gitleaks` to the `recommends` of the crash module (archive package, not a download).

CONFLICT: "`gh issue create --web`" — archive `gh 2.46.0`; `--web` needs a browser and (for repo targets) works without login but cannot prefill long bodies reliably — RECOMMEND: build a `https://github.com/<repo>/issues/new?title=…&body=…` URL with the title and a short body plus "paste the attached report" and put the (redacted) report path in the clipboard; use `gh issue create --web -R <repo> --title … --body …` when `gh` exists, else `xdg-open` on the URL (this is not the picker recursion: it is a fixed github.com URL, but if the picker is the default it will still show the picker; fine). The URL is built by Ostrich, shown to the user in the report first, never posted.

CONFLICT: "default agent in `~/.config/ostrich/agent`" vs plan 02 "all settings in the options schema" — RECOMMEND: add option `crash.agent` (type `choice`, values from detection) whose storage is that file (`target.file`), so Settings can change it.

## Architecture

```
ostrich-crash-watch (user service, Type=simple, started from graphical-session.target)
   ├─ source A1: journalctl -f -o json MESSAGE_ID=fc2e22bc6ee647b6b90729ab34a250b1 (if core_pattern = systemd-coredump)
   ├─ source A2: ostrich-crash-apport.path  PathChanged=/var/crash  → ostrich-crash-apport.service (if apport)
   └─ source B : ostrich-crash-boot.service (oneshot at login; the previous-boot check)
         ↓ event {kind, exe, pid, signal, time, source_ref}
   ostrich crash notify  → GNotification  [Diagnose with <agent>] [Ignore]
         ↓ Diagnose
   ostrich crash diagnose <event-id>  → report builder → consent (first use) → terminal + agent
```

No resident polling: A1 is a blocking `journalctl -f` (event-driven), A2 is a `.path` unit, B runs once per login. `docs/DESIGN.md` principle 1 says "no resident daemons", so the A1 follower must be the only long-running process; it is only started when `core_pattern` says systemd-coredump, and measured (budget: 0 wakeups when nothing crashes, RSS < 5 MB). If that budget is missed, switch A1 to a `.socket`/`journal` triggered unit.

### (a) Process crashes

- **A1 (systemd-coredump):** parse JSON fields `COREDUMP_EXE`, `COREDUMP_COMM`, `COREDUMP_PID`, `COREDUMP_SIGNAL_NAME`, `COREDUMP_UID`, `COREDUMP_TIMESTAMP`. Only the current user's crashes (`COREDUMP_UID == $UID`) are notified, but gnome-shell is the user's. System-service crashes (UID 0 / system units) are only reported if the user opts into "Also report system services" (default off).
- **A2 (apport):** the path unit fires on `/var/crash/*.crash`; the handler reads only the header keys needed (`ExecutablePath`, `Package`, `Signal`, `Date`, `ProcCmdline` redacted) from the `.crash` file (it is an RFC-822-ish file with a binary core blob; **parse the headers only, never load the CoreDump field**). Files not owned by the user (`stat -c %u`) are ignored (apport writes them root-owned with `0640`; if the user cannot read it, notify without details and offer `ubuntu-bug`).
- **gnome-shell crash / session logout:** gnome-shell's death ends the Wayland session, so the watcher itself dies. The crash is therefore found at the **next login** by source B (not live): the A1/A2 source plus the stored journal still contain the entry, so B also queries `coredumpctl list --since=<last-seen>` / `/var/crash` for crashes since the last recorded `~/.local/state/ostrich/crash-last-seen` timestamp. Single code path: `ostrich crash scan --since`, run by B and by A on start, deduped by event key.
- Dedup/rate-limit: key = `(exe, signal)`; at most one notification per key per **10 min** (state in `~/.local/state/ostrich/crash-ratelimit.json`, written atomically); suppressed events are counted and reported on the next one ("3 more in the last 10 minutes"). Muted exes (`ostrich crash mute <exe>` → `~/.config/ostrich/crash-muted`, one absolute path per line, `unmute` and `list` verbs) are skipped but still listed in `ostrich crash list`.

### (b) Whole-system crash, freeze, panic — heuristic

Run once per login by `ostrich-crash-boot.service` (`ConditionUser=!root`, `After=graphical-session.target`), only for the first login after a boot (guard file in `$XDG_RUNTIME_DIR`).

Inputs about the **previous boot** (`journalctl -b -1`; requires persistent journal, i.e. `/var/log/journal` exists — if not, say so in the report and fall back to pstore/kdump only; Ubuntu desktop has persistent journals disabled by default in some configurations: verify on 26.04 in the VM and have the module enable `Storage=persistent` via a drop-in if the user opts in):

1. **pstore** present: any file in `/var/lib/systemd/pstore/*` newer than last boot's start → strong signal (kernel oops/panic saved by `systemd-pstore.service`). Read-only; may need group access, so the report builder uses `ostrich-crash-boot`'s polkit-free read only if readable, else points to the path.
2. **Kernel crash dump** files: `/var/crash/linux-image-*` or `/var/crash/*/vmcore*`, `dmesg.*`, newer than the previous boot start → strong signal (kdump/`linux-crashdump`).
3. **No clean shutdown:** previous boot's journal tail does **not** contain, in its last 30 s, any of: `Reached target Shutdown`, `Reached target Reboot`, `Reached target Power-Off`, `Journal stopped`, `systemd-shutdown`, `Shutting down.` → "unclean". Because the previous boot's last journal line is also what a power cut leaves, this alone means *loss of power or crash*, not "crash".
4. **Kernel messages** in the previous boot's last 200 lines: `Kernel panic`, `BUG:`, `Oops:`, `general protection fault`, `Machine check`, `NVRM: Xid`, `amdgpu ... timeout`, `i915 ... GPU HANG`, `watchdog: BUG: soft lockup`, `blocked for more than 120 seconds`, `hung_task` → "kernel fault" signal.

Classification (first match wins):

| Class | Rule |
|---|---|
| `panic` | (1 or 2) **or** (4 with a `Kernel panic`/`Oops`/`BUG:` line) |
| `freeze` | 3 unclean **and** (4 with `soft lockup`/`hung_task`/`GPU HANG`/`Xid`/`amdgpu timeout`) |
| `unclean` | 3 unclean and nothing from 4 (could be power loss, long-press power button, battery empty; if the previous boot's last journal line shows `Battery`/`UPower` critical or `Power key pressed`, classify `power-loss`, which is **not** notified) |
| none | clean shutdown |

Only `panic`, `freeze` and `unclean` notify. `unclean` uses softer copy: "The computer shut down without saving its logs last time. Want help working out why?". A manual user hard-reset leaves the same trace; the user can mute that class (`ostrich crash mute --class unclean`). Boot-time clock jumps are ignored by using the boot IDs from `journalctl --list-boots`.

**Test the heuristic** (VM only): scripted scenarios in `tests/vm/crash-test.sh`, each from a snapshot: (i) clean reboot → none; (ii) `echo c > /proc/sysrq-trigger` → panic (needs `kernel.sysrq` allowed in the VM, pstore with `efi`/`ramoops` configured in the VM; if the VM cannot keep pstore, expect `unclean` plus the `Kernel panic` line from the serial log; document which); (iii) `echo b > /proc/sysrq-trigger` (instant reboot, no sync) → `unclean`; (iv) QEMU `system_reset` → `unclean`; (v) QEMU `system_powerdown` (ACPI) → none; (vi) forced power off via `quit` → `unclean`; (vii) GPU hang fixture: inject lines into a **fixture journal** (`SYSTEMD_JOURNAL`-style test dir via `systemd-journal-remote`/`journalctl --directory`) → `freeze`. Unit-test the classifier on fixtures in `tests/fixtures/crash/*.json` (a pure function: previous-boot facts in, class out) so most cases run in Docker.

## Notification

`GNotification` via a small `ostrich-crash` GApplication (id `ostrich.crash`, `.desktop` file for attribution). Title: "<App name> stopped unexpectedly" (app name from the `.desktop` matching the exe, else the exe basename); body: "Ostrich can look into why." Buttons: **Diagnose with Claude** (agent display name) and **Ignore**. If no agent is installed, the button is "Open report". Priority `normal`; `urgent` only for panics. Suppressed in Do Not Disturb and focus mode (reuse the check from the drawer host), but the event is queued and shown when DND ends.

## Report

Built by `ostrich crash report <event-id> [--out DIR]` into `$XDG_STATE_HOME/ostrich/crash/<id>/report.md` (mode 0600, the dir 0700). Never includes the raw core.

| Section | Source |
|---|---|
| Summary | exe path, signal name + number, time, class (a/b) |
| Package | `dpkg -S <exe>` → package; `dpkg-query -W -f='${Version}'`; if no package (not found) mark **third-party/unpackaged**; flatpak/snap: `flatpak info`/`snap list` entry |
| Backtrace | A1: `coredumpctl info <pid>` (it prints a stack trace when systemd was built with elfutils support; check in the VM) and `gdb -batch -ex 'bt full 30' -ex 'info sharedlibrary' <exe> <core>` with `DEBUGINFOD_URLS=https://debuginfod.ubuntu.com` (needs consent: it sends build-ids to Canonical's server; the consent screen says so) and a 60 s timeout; the core is read from the coredump store and **deleted from any temp dir after**; A2: apport's `Stacktrace`/`ThreadStacktrace` fields if present |
| Journal | last 200 lines, filtered: `journalctl --user -n 400 --no-pager` plus system journal lines for the PID or `_COMM`, then drop lines not within ±60 s of the crash time and not matching the exe/unit/`kernel`/`gnome-shell`/`NVRM`; hard cap 200 lines |
| Versions | `uname -r`; GPU driver: `nvidia-smi --query-gpu=driver_version,name --format=csv,noheader` if present, else `modinfo`/`/sys/module/{i915,amdgpu,nouveau}/version`/`glxinfo`-free: `lspci -nnk` display lines; `gnome-shell --version`; Ubuntu `VERSION_ID`; Ostrich `VERSION` and installed extension versions |
| Class (b) extras | previous-boot facts (which rule fired), pstore file list with sizes (contents only if ≤64 KB and redacted), the matching kernel lines |

### Redaction (runs on the whole bundle before the agent or any file sees it)

Order matters; each is a unit-tested regex pass in one function `redact(text, ctx)` (`ctx` = username, hostname, home, machine-id):

1. `$HOME` → `~` (also `/home/<user>` and `/root`-not: only the current user's home), then bare username as a whole word → `<user>`.
2. Hostname (`/etc/hostname`, `hostnamectl --static`, FQDN) → `<host>`.
3. Emails → `<email>`; IPv4/IPv6 (keep `127.0.0.1`/`::1`) → `<ip>`; MAC addresses `xx:xx:xx:xx:xx:xx` and `xx-xx-…` → `<mac>`; `machine-id`/boot ids → `<id>`.
4. Common token shapes (`ghp_…`, `github_pat_…`, `AKIA…`, `sk-…`, `xox[bap]-…`, `Bearer …`, `eyJ…` JWTs, `-----BEGIN … PRIVATE KEY-----` blocks, `password=`, `token=`, `Authorization:` header lines) → lines dropped.
5. **gitleaks pass** (if installed): `gitleaks detect --no-git --source <bundle-dir> --report-format json --report-path …` (8.16 syntax; `gitleaks dir …` on ≥8.19), then **delete every flagged line** from the report (by file+line) and note "N lines removed by the secret scan" in the footer. gitleaks exit code 1 = findings; other non-zero = scan failed → treat as "no scan available" in the footer, never as "clean".
6. Paths of other users are kept; command lines (`ProcCmdline`) are run through the same filters and are truncated at 300 chars.

Tests: fixtures with planted secrets/PII must come out clean (`tests/crash-redact.bats`); a property test that `redact(redact(x)) == redact(x)`.

### Consent

First use of Diagnose shows an `AdwAlertDialog`: "Send this report to <Provider>?" Provider and what it receives are named from the agent definition (`claude` → Anthropic, `codex` → OpenAI, `gemini` → Google, `opencode` → whichever model provider is configured (the screen says "the provider you configured in opencode", read from its config if possible; otherwise it says it cannot tell)). Body: "The report has your username, hostname, emails and IP addresses removed. It may still contain names of files and programs you use." Buttons: **Show report** (opens it first; secondary), **Send** (primary), **Cancel**. Consent is stored per agent in `~/.config/ostrich/crash-consent.json` with the report format version; a new format version asks again. No agent is ever started without it. The debuginfod fetch has its own checkbox on the same screen.

## Agents

Defined as data in `/usr/share/ostrich/agents.d/<id>.toml` (and user overrides in `~/.config/ostrich/agents.d/`):

```toml
id = "claude"
name = "Claude Code"
provider = "Anthropic"
detect = "claude"                         # command in PATH (also ~/.local/bin, ~/.claude/local)
skills_dir = "~/.claude/skills"           # where the skill is installed
launch = ["claude", "{prompt}"]           # interactive with an initial prompt
```

Researched 2026-11-21 from the vendors' docs (links under Sources). **Verify each with `--help` in the VM**; items marked ? were not confirmed.

| Agent | Skills / instruction install path (user level) | Launch with initial prompt |
|---|---|---|
| Claude Code | `~/.claude/skills/<name>/SKILL.md`; project `.claude/skills/<name>/SKILL.md`; memory `~/.claude/CLAUDE.md` | `claude "<prompt>"` (interactive with initial prompt); `claude -p` is non-interactive |
| Codex CLI | skills `~/.agents/skills/<name>/SKILL.md` (`$HOME/.agents/skills`; `SKILL.md` needs `name`, `description`); instructions `~/.codex/AGENTS.md` | `codex exec` is non-interactive (confirmed); `codex "<prompt>"` interactive **?** not confirmed in docs |
| Gemini CLI | skills `~/.gemini/skills/` or `~/.agents/skills/`; instructions `~/.gemini/GEMINI.md` | `gemini -i "<prompt>"` (run prompt then stay interactive); `-p` is non-interactive; status of the CLI itself see CONFLICT above |
| opencode | skills `~/.config/opencode/skills`; it also reads `~/.claude/skills` and `~/.agents/skills`; instructions `~/.config/opencode/AGENTS.md` (falls back to `~/.claude/CLAUDE.md`) | TUI: `opencode --prompt "<prompt>"` **?** (flag from third-party sources); non-interactive `opencode run "<prompt>"` |

Because opencode reads `~/.claude/skills` and `~/.agents/skills`, and Codex and Gemini both read `~/.agents/skills`, installing once to `~/.claude/skills/` **and** `~/.agents/skills/` covers all four with two copies (symlink `~/.agents/skills/<name>` → the same files is allowed only if each CLI follows symlinks; test, else copy). Install only into directories of CLIs that are detected, plus `~/.agents/skills` when any of Codex/Gemini/opencode is. Never overwrite a user's existing skill of the same name; back up (`.before-ostrich`) and log. Removal on revert deletes only files whose content hash matches the shipped one.

The launch prompt is a fixed string with the report **path** only (never the report body on the command line, which would be visible in `ps`): *"Use the diagnose-crash skill on the crash report at /path/report.md. Do not run sudo, edit files or install anything without asking me first."* Launch in the user's terminal: `xdg-terminal-exec <cmd…>` (archive 0.14.0, already used by the repo's `xdg-terminals.list`/Ghostty setup); fallback `gnome-terminal --`, then `x-terminal-emulator -e`. No agent → `xdg-open report.md` (default text editor) with a header comment "How to use this report" (paste into your assistant; what it contains).

### Skills shipped (`share/ostrich/skills/`)

- `diagnose-crash/SKILL.md` — **read-only**. Steps: read the report; classify the component (Ostrich-owned: path under `~/.local/libexec/ostrich`, `/usr/libexec/ostrich`, `*@ostrich` extension, `ostrich-*` binary; Ubuntu package: `dpkg -S` owner with Ubuntu maintainer; third-party: no owner / flatpak / snap / AppImage / unpackaged; hardware-driver: `nvidia`, `amdgpu`, `i915`, `NVRM`, firmware); explain in plain words; propose a fix as text; offer the contribute route. Allowed tools: read-only (`Read`, `Grep`, `Bash` for read-only commands such as `dpkg -S`, `apt-cache policy`, `journalctl`, `coredumpctl info`). Explicit rules in the skill: never `sudo`, never write, edit or install without the user saying yes in this session, never upload the report anywhere, never run the crashing program. Front matter limits tools where the agent supports it (`allowed-tools` for Claude Code).
- `ostrich/SKILL.md` — system layout (paths from plan 01), where options live (`/usr/share/ostrich/options.json`), how to change a setting (`ostrich settings get|set <option-id>`, which applies the option's target; **requires the CLI from plan 02, which does not exist yet**), the rule "never hand-edit chezmoi-managed files (`chezmoi managed`); change the source with `chezmoi edit` or use the options CLI", how to run `ostrich uninstall`/`update`, and the test-in-VM rule for contributors. Read-only by default.

### Contribute

Report footer and the skill both end with: Ostrich-owned → URL for the Ostrich repo's new-issue page prefilled (title, a short body, a note to attach the redacted report); Ubuntu package → "run `ubuntu-bug <package>`" (command shown, not executed); third-party → the project's tracker if known from package metadata (`Homepage`/`Bugs` fields of `dpkg -s`, or the Flathub/snap page) else the vendor's site. Nothing is posted automatically; the user reviews.

## Settings page ("Crashes")

Switch "Offer help after a crash" (on by default; off stops both watchers), agent combo (detected agents only, plus "Open report in editor"), list of muted programs with Unmute, "Forget consent" button, and (hidden until proven) "Use systemd-coredump" with its reboot-free-but-reversible description. Copy lives in `options.json` (plan 02).

## Files to touch

`tools/crash/` (new crate `ostrich-crash`: `watch.rs`, `scan.rs`, `classify.rs`, `report.rs`, `redact.rs`, `notify.rs`), `tools/ostrich/src/main.rs` (`ostrich crash {list,mute,unmute,diagnose,report,scan}`), `modules/crash/install.sh` (+`status`,`revert`): units `ostrich-crash-watch.service`, `ostrich-crash-apport.{path,service}`, `ostrich-crash-boot.service`, `ostrich-crash.desktop`, `share/ostrich/skills/{diagnose-crash,ostrich}/`, `share/ostrich/agents.d/*.toml`, `share/ostrich/options.json`, `tests/fixtures/crash/*`, `tests/crash-redact.bats`, `tests/crash-classify.bats`, `tests/vm/crash-test.sh`, `docs/DESIGN.md`.

## Done criteria

1. Segfaulting test program (`sleep` + SIGSEGV) on apport and (VM option) systemd-coredump machines produces exactly one notification with both buttons; a second crash within 10 min does not; after 10 min it does and mentions the count.
2. gnome-shell crash in the VM (`kill -SEGV $(pidof gnome-shell)`) → after re-login a notification names `gnome-shell`.
3. Heuristic scenarios (i)–(vii) classify as listed; classifier fixtures pass in Docker.
4. Report for each scenario contains every spec section; **fixture secrets and PII never appear** (bats); no core file persists anywhere after report build (`find` check).
5. First-use consent screen appears before any agent starts, names the right provider for each agent, **Cancel** starts nothing.
6. `diagnose-crash` run under Claude Code in the VM does not call a write tool or `sudo` (check the agent's tool log) and classifies four fixtures (Ostrich, Ubuntu package, third-party, driver) correctly.
7. Skills install into the right dirs per detected agent, back up conflicts, and revert removes only what was shipped.
8. Watcher idle cost within budget (0 wakeups/s idle; RSS < 5 MB); stops on `Offer help after a crash` off.
9. `ostrich crash mute <exe>` stops notifications; `list` still shows them.

## Test method

Docker `ubuntu:26.04`: classifier, redaction, report builder on fixtures, agent `.toml` parsing, skill file lint, unit file lint (`systemd-analyze verify`). VM (snapshot per case, GNOME 50): real crashes with apport (default) and with `systemd-coredump` (option test), sysrq/QEMU reset scenarios, notification action click (via D-Bus `ActivateAction`), terminal launch with a **fake agent** script that records its argv (so no data leaves the VM), one real-agent run with a dummy crash and a throwaway account. Never the live machine; never a real user report in tests.

## Sources

Claude Code: https://code.claude.com/docs/en/skills · Codex: https://learn.chatgpt.com/docs/build-skills · Gemini CLI: https://geminicli.com/docs/cli/skills/ · opencode: https://opencode.ai/docs/skills/ · systemd catalog: https://systemd.io/CATALOG/ · systemd-pstore: https://www.freedesktop.org/software/systemd/man/latest/systemd-pstore.service.html · Apport/systemd-coredump: https://discourse.ubuntu.com/t/apport-2-28-0-gained-systemd-coredump-integration/44910
