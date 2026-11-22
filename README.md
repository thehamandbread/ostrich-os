# Ostrich OS

An opinionated desktop for Ubuntu 26.04 LTS that anyone can use, whatever they know about computers, and that a power user still gets a lot out of. It's built on GNOME 50, and is light on battery, memory and CPU.

**Status:** pre-release. Tested end to end in a virtual machine; real-hardware testing is next.

## Get it

**On a machine already running Ubuntu 26.04:**

```bash
wget -qO- https://raw.githubusercontent.com/thehamandbread/ostrich-os/main/install.sh | bash
```

Then log out and back in. The setup tour opens and walks you through everything. It's safe to run the command again; `ostrich update` does the same.

Already customised your desktop? The installer asks whether to keep your other extensions or start clean, and it takes a restore point first: **`ostrich uninstall` puts your computer back the way it was.** See [docs/DEFAULTS.md](docs/DEFAULTS.md#undo). On a machine you rely on, follow [docs/INSTALLING.md](docs/INSTALLING.md).

**On a new machine (USB installer):** `image/build-iso.sh` builds `ostrich-os-26.04-amd64.iso`. Write it to a USB stick with Startup Disk Creator, boot from it, and install as you would Ubuntu. **You choose the disk**, so pick the right one: everything on the disk you choose is replaced. At the first login a window finishes the setup and asks for your password once.

## What it changes

See [docs/DEFAULTS.md](docs/DEFAULTS.md). In short:
- a system monitor and workspace bar in the top bar;
- an auto-hiding dock;
- live blur, each surface switchable to solid;
- Ostrich Drawer: your web apps in the top bar, opened by a click or a hover (Super+Alt+D);
- focus mode (Super+Alt+F);
- tiling;
- Flatpak with a fast app store (`ostrich store`);
- real power and graphics modes;
- speaker tuning.

Nothing is deleted. Replaced extensions are switched off, and changed files are backed up first.

## The `ostrich` command

```text
ostrich store [search | github-link]   find, install, update and remove apps
ostrich theme                          accent colours from your wallpaper
ostrich speakers                       speaker presets and tuning
ostrich drawer                         Ostrich Drawer (--list, --recommended, --add SITE)
ostrich setup [--step NAME]            the setup tour, or one step
ostrich env [list|save|open|close]     environments: saved desktops
ostrich update                         get the latest version
ostrich uninstall                      put everything back as it was
```

## For developers

See [docs/DESIGN.md](docs/DESIGN.md) for the design and [CLAUDE.md](CLAUDE.md) for the build and test commands. Everything is tested in a scripted QEMU VM (`tests/vm/`), never on the developer's own machine.

MIT licensed, except `modules/gnome/extensions/`, which is GPL-2.0-or-later.

## Trademarks

Ubuntu is a registered trademark of Canonical Ltd. Ostrich OS is not affiliated with or endorsed by Canonical.
