# Monitor (part of Ostrich OS)

CPU, memory, temperature and GPU in the top bar, with a popup of every reading. Pin any value to the
top bar with its star. It reads only `/proc` and sysfs, slows down on battery, shows nothing in power
saver, and never wakes an NVIDIA GPU that is asleep.

- **GNOME 50.** Works on its own; no other Ostrich OS part is needed.
- **The popup** starts with your pinned values, then Processor, Memory, Network and Storage (Battery on
  a laptop) open; what you leave open or folded stays that way.
- **Settings:** the *Monitor settings* button in the popup opens the extension's preferences window
  (or Ostrich Settings when that is installed), or use `gsettings` under
  `org.gnome.shell.extensions.ostrich-os.monitor`.
- **Low-battery rule:** on battery at or below the chosen charge (20 % by default; 0 turns it off) it
  switches to power saver, and back to the previous mode when you plug in. A saver you or GNOME already
  chose is left alone, so GNOME's own automatic power saver does not clash with it.
- **Memory warning:** once, when memory and swap are 85 % full, naming the app using the most.
- Power-mode knobs beyond the profile (PCIe, audio, USB) need Ostrich OS's system helper; without it
  the extension only dims the screen sooner in power saver and runs the low-battery rule, which uses
  GNOME's own power profile.

Part of [Ostrich OS](https://github.com/thehamandbread/ostrich-os). Licence: GPL-2.0-or-later.
