# Baseline

Idle resource use measured in the test VM (`tests/vm/`). This is the reference every component has to beat.

- **pre:** a replica of the original desktop (11 extensions, settings from INVENTORY), built by `replicate-current.sh`.
- **stock:** plain Ubuntu 26.04.1 desktop, for reference.
- **post:** this project; rows get added as phases land.

## Method

- VM: QEMU/KVM, 4 vCPU, 6 GB RAM, 1920×1080 headless. The guest renders with llvmpipe (software), so GPU work such as blur shows up as gnome-shell CPU time.
- Host: Intel i7-12800H on AC, load average about 0.6 at the start.
- Each run: boot from the snapshot, wait 2 minutes, then measure a 5-minute idle window. Three runs per state; the tables below show the median.
- gnome-shell CPU is the process's own CPU time divided by the window, as a percentage of one core. Wakeups come from powertop inside the VM.

## Results (2026-10-20)

| Metric | stock | pre (original setup) | pre vs stock |
|---|---|---|---|
| gnome-shell CPU, % of one core | 0.037 | **0.420** | +1035% |
| gnome-shell wakeups/s | 0.9 | **5.0** | +456% |
| gnome-shell RSS, MB | 344.0 | 370.7 | +8% |
| gnome-shell PSS, MB | 299.1 | 325.0 | +9% |
| Used memory after login, MB | 995 | 1023 | +3% |
| System wakeups/s | 66.1 | 64.4 | −3% (noise) |
| Processes | 215 | 212 | — |
| Running system / user services | 31 / 47 | 31 / 47 | — |
| squashfs (snap) mounts | 13 | 13 | — |
| Extensions enabled | 7 (Ubuntu defaults) | 11 | — |
| Boot to login, s | 5.18 | 6.04 | +16% |

Notes:

- The three `pre` runs agree within 3 % (CPU 0.413–0.423 %, shell wakeups 4.8–5.1/s).
- The first `stock` run was higher (0.20 % CPU), likely leftover first-boot work. The median uses the two settled runs.
- The extra idle cost in `pre` is in gnome-shell itself: about 10× the CPU and 5× the wakeups of stock. That is consistent with periodic work in extensions (Vitals refreshes every 2 s). It will be broken down per extension when the `monitor` extension is built.
- The replica doesn't include snaps/flatpak apps or autostart apps (Nextcloud, ActivityWatch), so the original machine's real idle cost is higher than `pre`.

## Targets for post

- gnome-shell idle CPU and wakeups at or below `pre` while showing the same information, aiming for close to `stock`.
- gnome-shell memory no higher than `pre`.
- Fewer snap mounts and services wherever the user opts out of snap.

## What this can't show

This VM has no battery, NVIDIA GPU, Dell firmware, touchscreen or speakers. Watts, battery life, graphics and power modes, calibration and speaker tuning are measured on real hardware booted from the external SSD (see DESIGN.md → Testing).

## Monitor extension vs Vitals + nvidia-power (2026-10-20)

Quiet mode (the VM's background update jobs paused for the measured boot), 3 runs, medians. `pre` is the original setup. `pre-monitor` is the same setup with Vitals and nvidia-power replaced by our `monitor` extension. All 10 extensions were confirmed ACTIVE in every run.

| Metric (gnome-shell) | pre | pre-monitor | Change |
|---|---|---|---|
| CPU, % of one core | 0.657 | **0.113** | −83% |
| Context switches/s, all shell threads | 15.42 | **4.24** | −73% |
| Wakeups/s (powertop) | 4.7 | **2.4** | −49% |
| PSS, MB | 327.0 | 314.0 | −4% |

What made the difference:

- **Per-tick reads are synchronous.** `/proc` and coretemp files are generated in memory, while async GFile reads cost several thread-pool wakeups each. That alone took the first monitor version from about 12 to about 2 shell wakeups/s above the no-monitor level.
- **Panel values only redraw when they change by a step.**
- **The popup-only sensors are read only while the popup is open.**

A first quiet-mode run of `pre-monitor` showed −94%. **That run was discarded.** The snapshot had `disable-user-extensions=true`, so it had measured a bare desktop. `measure.sh` now refuses to measure in that state and records `extensions_active`.
