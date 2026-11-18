# Spike: touchscreen toggle (2026-10-20)

Prototype: `spikes/touchscreen/touchscreen.sh` (`status | off [--level hid|transport] [--persist] | on`). It was tested in the VM with `VM_TOUCH=1` (QEMU `virtio-multitouch-pci`). On the host it was only run read-only (`status` and target selection).

## How it finds and switches the device

- Touchscreens are found by the udev property `ID_INPUT_TOUCHSCREEN=1`, never by name or position.
- It walks up sysfs to the bound drivers above the event node:
  - **hid**: the nearest one (`hid-multitouch` on the Precision 5570; `virtio_input` in the VM). Input stops.
  - **transport**: the next one up (`i2c_hid_acpi` on the 5570; `virtio-pci` in the VM). Used only when that device has exactly one bound child, so it can't take a touchpad or anything else down with it. The controller can power down too.
- A touch controller is one HID device even when it exposes several inputs. On the 5570 the touchscreen HID device has three (touch plus extra collections, probably pen and vendor), so the check counts bound child devices, not inputs.
- `--persist` writes `/etc/udev/rules.d/90-ubuntu-ostrich-touchscreen.rules`, which unbinds the device again on add/bind. `on` removes the rule and rebinds exactly what was unbound (state in `/var/lib/ubuntu-ostrich/touchscreen.state`).

## Results (VM)

| Test | Result |
|---|---|
| Off/on at the hid level | Pass: the touchscreen disappears and returns; keyboard, mouse and tablet pointer unaffected |
| Off/on at the transport level | Pass |
| Persist across reboot | Pass: still off after reboot; `on` restores it and removes the rule |
| Survives suspend/resume | Pass: real suspend (`PM: suspend entry`), still off after wake, keyboard fine |

On the host (read-only): the touchscreen is `ELAN2D26:00 04F3:2D26` and the touchpad is a separate I²C device (`04F3:311C`). The transport `i2c-ELAN2D26:00` has one bound child, so the toggle would use the transport level (controller powered down).

## For the real implementation

- This goes into `system-helper` (privileged, one-shot). The polkit `allow_active` rule covers only this action, and the quick-settings tile appears only when `has_touchscreen` (lib/detect.sh) is true.
- The compositor-level fallback isn't needed: unbinding survives suspend/resume.
- Still to check on real hardware (external SSD): that the controller's power actually drops at the transport level, and that pen input goes off and on with it.
