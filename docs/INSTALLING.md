# Installing on a machine you use

The one-line install in the README is safe to undo (`ostrich uninstall`). On a machine you rely on,
these steps add a second safety net and tell you what to check. From the readiness council of
2026-10-31 (`docs/council/2026-10-31-ready-to-install-on-the-dell.md`).

## Before

1. Keep your own copies; don't rely only on the restore point:
   ```bash
   mkdir -p ~/ostrich-pre && cd ~/ostrich-pre
   dconf dump / > dconf-before.ini
   apt-mark showmanual > packages-before.txt
   gnome-extensions list --enabled > extensions-before.txt
   prime-select query > prime-before.txt 2>/dev/null
   cp -a ~/.config/gtk-4.0 ~/.config/gtk-3.0 ~/.config/ghostty . 2>/dev/null
   ```
   Note anything else you care about staying as it is (services, PAM, your own dotfiles).
   Also measure boot time and memory before, to compare with after (the VM showed +151 % boot and
   +24 % memory, partly first-boot work; only your PC gives the real numbers). After a fresh boot
   and 2 minutes idle at the desktop:
   ```bash
   systemd-analyze > boot-before.txt; systemd-analyze blame | head -20 >> boot-before.txt
   free -m > memory-before.txt; ps -eo rss,comm --sort=-rss | head -15 >> memory-before.txt
   ```
2. From a checkout rather than the one-line install, use a complete build of this commit:
   `tests/vm/build-tools.sh --check` builds it in the test VM, then
   `export BUILD_DIR=~/.local/share/ostrich-os/vm/tools-bin`. The installer stops before
   changing anything if the build is partial or older than `tools/`.
3. `./install.sh --dry-run` and read it: it names the tools it will use ("using the tools built
   in …", never "would be downloaded" for a checkout), the restore point, and the hardware modules
   it detected.

## Install, then check

4. Install on AC power: `./install.sh`. It asks for your password itself.
5. Before logging out:
   - `wc -c ~/.local/state/ostrich-os/restore/original/dconf.ini` is more than 0 (tens of KB
     on a lived-in machine). If it is 0, stop and uninstall.
   - `ostrich --version` is the version you built.
   - Every `@ostrich-os` extension is ACTIVE (`gnome-extensions info NAME`); the ones it
     replaced are off, not deleted.
   - `./install.sh --dry-run` again lists no changes.
6. After logging back in, only real hardware can show these:
   - NVIDIA laptops: `cat /sys/bus/pci/devices/*/power/runtime_status` for the NVIDIA device reads
     `suspended`, also after opening the system monitor and the clock menu.
   - Battery: 15 minutes unplugged with `measure.sh`; close the lid and resume.
   - The drawer: open each site once; no "internal error" dialog should appear (0.1.5 fixed it).
   - Speakers (the A/B test), the touchscreen, a printer, Bluetooth audio.
   - Boot and memory: reboot, wait 2 minutes at the desktop, and run the same two commands into
     `boot-after.txt` and `memory-after.txt` in `~/ostrich-pre`. Claude compares them.

## Undo

`ostrich uninstall` puts every setting back as it was at install time (also ones you changed
since; `--keep-new-settings` keeps those), removes what was added and keeps apps from the Store.
It prints where it kept a copy of your drawer sites and saved desktops. Don't pass
`--remove-packages` unless you mean it: it also removes apt packages you installed yourself since.

## On a USB drive you carry between PCs

This puts a whole Ostrich OS system on a USB drive: your account, apps and settings live on
the drive, and it boots on any 64-bit PC from the boot menu. The PC's own disk is never written to,
and booting the drive adds no boot entry to the PC's firmware. (A *live* USB keeps nothing when you
unplug it; this is a real install.) Use a USB SSD (128 GB or more); a stick works, but slowly.

1. Build the image: `tests/vm/build-tools.sh --check`, then `image/build-iso.sh --portable`.
2. Plug in the drive. Find it with `lsblk -d -o NAME,TRAN,SIZE,MODEL` (TRAN says `usb`).
3. `image/to-usb.sh /dev/sdX`. It refuses anything but a whole, unmounted USB disk, and prints a
   `sudo setfacl` line to run once so it can write to the drive. Type `ERASE` to go on.
4. In the installer window: **Erase disk** (the drive is the only disk listed), encryption
   recommended (the passphrase is asked at every boot), your account. After the restart, log in
   once: a terminal finishes the Ostrich OS setup. Shut down, then unplug.
5. On the other PC: power it off, plug the drive in, power on and press the one-time boot key
   (Dell: F12 at the logo), pick the drive under UEFI. Secure Boot can stay on. Don't change BIOS
   settings on someone else's PC (it can ask for their BitLocker recovery key).
6. Connect to Wi-Fi and run `ostrich update`, so the hardware parts (Dell, power, touchscreen)
   detect that PC.
7. Always shut down before unplugging. `image/to-usb.sh --boot /dev/sdX` boots the drive in a
   window on this machine.

## Coming from Ubuntu Ostrich (0.5.0 and earlier)

The project was renamed Ostrich OS in 0.6.0. Run the same one-line command (or `ostrich update`): the installer moves your settings, web logins, restore points and per-site notification choices to the new names, and says when to log out. Two things to know:

- **The drawer keeps your web logins.** If the drawer is running when you update, it is asked to quit; if it will not, its data stays where it is until you log out and run `ostrich update` again. Nothing is deleted before it has been copied and checked.
- **Settings you keep in your own dotfiles repo** (`ostrich config export …/dot_config/ubuntu-ostrich/settings.dconf`) stay where they are: move that file to `dot_config/ostrich-os/settings.dconf` yourself.
