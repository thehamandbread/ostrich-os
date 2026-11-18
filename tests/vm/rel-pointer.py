#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Runs INSIDE the test VM (as root): moves the pointer with a temporary uinput relative mouse.
# GNOME's pressure barriers (dock edge reveal) only react to relative motion; QEMU's absolute
# tablet can't hit them, and QEMU's USB mouse aborts on input-send-event (qemu 10.2).
#
# usage: rel-pointer.py DX DY [N] [DELAY_MS]   (N moves of DX,DY; default 1 move, 10 ms apart)
import fcntl
import os
import struct
import sys
import time

EV_SYN, EV_KEY, EV_REL = 0, 1, 2
REL_X, REL_Y, BTN_LEFT = 0, 1, 0x110
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT = 0x40045564, 0x40045565, 0x40045566
UI_DEV_SETUP, UI_DEV_CREATE, UI_DEV_DESTROY = 0x405C5503, 0x5501, 0x5502
BUS_VIRTUAL = 0x06


def emit(fd, typ, code, value):
    os.write(fd, struct.pack("llHHi", 0, 0, typ, code, value))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__ or "usage: rel-pointer.py DX DY [N] [DELAY_MS]")
    dx, dy = int(sys.argv[1]), int(sys.argv[2])
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    delay = (int(sys.argv[4]) if len(sys.argv) > 4 else 10) / 1000

    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    try:
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
        fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_LEFT)
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_REL)
        fcntl.ioctl(fd, UI_SET_RELBIT, REL_X)
        fcntl.ioctl(fd, UI_SET_RELBIT, REL_Y)
        setup = struct.pack("HHHH80sI", BUS_VIRTUAL, 0x1234, 0x5678, 1, b"ost-test-rel-pointer", 0)
        fcntl.ioctl(fd, UI_DEV_SETUP, setup)
        fcntl.ioctl(fd, UI_DEV_CREATE)
        time.sleep(1.0)  # let libinput/mutter pick the device up
        for _ in range(n):
            emit(fd, EV_REL, REL_X, dx)
            emit(fd, EV_REL, REL_Y, dy)
            emit(fd, EV_SYN, 0, 0)
            time.sleep(delay)
        time.sleep(0.3)
        fcntl.ioctl(fd, UI_DEV_DESTROY)
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
