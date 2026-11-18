# Test VM

Every test runs here (or later on an external SSD). The developer's own machine is never modified. See `docs/DESIGN.md` → Testing.

`vm.sh` drives a QEMU/KVM VM running Ubuntu 26.04 desktop. Images, keys and the ISO are stored in `~/.local/share/ubuntu-ostrich/vm/` (override with `VM_DIR`). Nothing is stored in the repo.

## One-time host setup

```bash
sudo apt install qemu-system-x86 qemu-utils ovmf cloud-image-utils xorriso
tests/vm/vm.sh check
```

None of these packages runs a background service. The download needs about 6 GB for the ISO. The VM disk is thin-provisioned with a 40 GB maximum, and its real usage grows with snapshots.

## First run

```bash
tests/vm/vm.sh fetch              # verifies SHA256SUMS signature (Ubuntu CD Image key) and the ISO checksum
tests/vm/vm.sh create
tests/vm/vm.sh install            # unattended; powers off when done
tests/vm/vm.sh snapshot save stock
```

The install creates a throwaway user `tester` with:
- a random password, stored in `$VM_DIR/password`;
- passwordless sudo inside the VM;
- GDM autologin;
- SSH that accepts only a VM-only key, generated in `$VM_DIR`.

## Daily use

```bash
tests/vm/vm.sh start                    # headless; VM_DISPLAY=std to watch in a window
tests/vm/vm.sh ssh 'gnome-shell --version'
tests/vm/vm.sh copy ./some-file /tmp/
tests/vm/vm.sh stop
tests/vm/vm.sh snapshot restore stock   # back to a clean install
```

## Tests

```bash
tests/vm/vm.sh view try-me                                    # try a snapshot in a window
tests/vm/e2e.sh --pipe post-fresh                             # the one-line install on stock
tests/vm/e2e.sh --pipe --from pre --mode keep --uninstall X   # install over the replica, then undo:
                                                              # settings, extensions and files must match
tests/vm/ui-test.sh                                           # dock, workspaces, tray, focus, blur, tiling
tests/vm/env-test.sh                                          # environments and focus with an allow-list
tests/vm/drawer-test.sh                                       # Ostrich Drawer: icons, click, hover, sizes, focus, power, environments
tests/vm/drawer-test.sh --sites                               # every recommended site in WebKitGTK
tests/vm/power-test.sh                                        # power-mode knobs and the saver desktop
tests/vm/motion-test.sh                                       # animations: off, on, reduced motion; no stale slide minimises the drawer
tests/vm/nowplaying-test.sh [--measure]                       # the now-playing pill with a mock player; --measure: its idle cost (E1)
tests/vm/everyday-test.sh                                     # what opens web pages, PDFs, office files, photos, music, video; printing
tests/vm/ext-test.sh focus monitor                            # 20 enable/disable cycles each
tests/vm/a11y-test.sh                                         # screen-reader names of our buttons, over AT-SPI
```

`env-test.sh`, `power-test.sh`, `drawer-test.sh` and `motion-test.sh` start from `post-fresh`; `drawer-test.sh` uses the tools in `$VM_DIR/tools-bin` (`build-tools.sh`).

## Snapshots

| Name | Contents |
|---|---|
| `stock` | Fresh Ubuntu 26.04 |
| `pre` | `stock` + a replica of the original setup (`replicate-current.sh`) |
| `post-<phase>` | `stock` + this project at that phase |

## Limits

The VM has no real battery, NVIDIA GPU, Dell firmware, touchscreen or speakers. Its numbers are only valid for comparing pre against post. Hardware features are tested on the external SSD.

## Critiques: flag problems while you test

`tests/vm/vm.sh view try-me` opens the VM with the critique tool in it (put there the first time,
about two minutes). See something wrong and press **Super+Alt+C**: the screen freezes as it was.
Drag a box around the problem, or click a part to pick it (it's outlined and named), type what's
wrong, choose Bug / Looks wrong / Idea, and press Enter (Shift+Enter for a new line, Esc to cancel).
More boxes can go in one note.

Notes land straight on this computer, in `~/.local/share/ubuntu-ostrich/vm/critiques/` (the VM
mounts that folder), one folder each with the screenshot, a crop per box, what was boxed and its
settings, the versions, and the recent errors. Nothing is lost when a snapshot is restored.

Then in Claude Code, say `/critiques`: the notes are read and a fix plan comes back.

```bash
tests/vm/critique.sh list            # open notes
tests/vm/critique.sh show ID         # one note
tests/vm/critique.sh selftest        # the tool, end to end
```

The tool is a test-VM extension only (`tests/vm/critique/`); it is never part of Ubuntu Ostrich.

