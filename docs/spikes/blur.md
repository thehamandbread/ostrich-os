# Spike: blur cost (2026-10-20)

Benchmark: `tests/vm/shell-bench.sh` runs in the `pre` snapshot (a replica of the original setup). It measures gnome-shell CPU as a % of one core, median of 3 runs of 60 s. Workloads: idle, and opening/closing the overview every 1.5 s. The guest renders with llvmpipe, so compositing and blur work show up as CPU time. Values are relative, not watts.

| Scenario | Idle | Overview |
|---|---|---|
| C: no blur (blur-my-shell disabled) | 0.66 % | 5.17 % |
| A: blur-my-shell, original settings (static panel/dock blur) | 0.71 % | 10.09 % |
| B: blur-my-shell, live blur on panel, dock, overview, app folders | 4.07 % | 26.90 % |
| B′: blur-my-shell, live blur on the panel only (rest static) | 3.42 % | 13.55 % |
| **D: our prototype, live blur on the panel only** | **0.66 %** | **6.64 %** |

## Findings

- **Static blur is cheap at idle but doubles animation cost.** A against C: 10.09 against 5.17 % in the overview.
- **blur-my-shell's live blur re-blurs whenever the panel repaints.** That includes its own content: Vitals every 2 s, the clock, the workspace bar. This is why it costs 5–6× the idle CPU even when nothing behind the panel moves.
- **The prototype is free at idle.** It blurs a clone of `global.window_group` (wallpaper and windows, never the panel itself) in a panel-sized, clipped container with `Shell.BlurEffect` in ACTOR mode, so it only re-renders when something *behind* the panel changes. Idle cost equals no blur (0.66 %).
- **The prototype is about 2.3× cheaper during animations.** It adds about 1.5 points over no blur, against about 3.5 points for blur-my-shell's live panel blur over its static setup. (B′ also carried static dock/overview blur, so this is approximate; the idle result is exact.)
- **Stability lesson.** The first prototype version put the blur widget inside the panel's box layout and **crashed gnome-shell (SIGSEGV)**. GNOME then set `disable-user-extensions=true`, which turned off *every* user extension. Lessons:
  - only add actors to fixed-layout parents;
  - keep the extensions small and defensive;
  - the installer and wizard should detect `disable-user-extensions=true` and tell the user, instead of leaving the desktop silently stripped.

## Design consequences

- The blur extension uses the prototype's approach (a window-group clone, a clipped container, decoupled from panel repaints) for the panel and dock, and static blur for the overview background.
- Still to build, measured the same way:
  - rate-capping re-blur on battery (about 15 Hz);
  - skipping blur under fullscreen windows and hidden actors;
  - static blur only in power saver.
- Real watt numbers come from the external-SSD hardware test.
