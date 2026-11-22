#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 xvfb x11-apps imagemagick dbus-x11 adwaita-icon-theme libglib2.0-bin >/tmp/i.log 2>&1 || { tail -5 /tmp/i.log; exit 1; }
export GDK_BACKEND=x11 GSK_RENDERER=cairo LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1 DISPLAY=:99
Xvfb :99 -screen 0 600x400x24 >/dev/null 2>&1 &
sleep 2
python3 /hello.py >/tmp/app.log 2>&1 &
sleep 1.2
import -window root /out/hello.png 2>&1 | tail -2
wait %2 2>/dev/null; tail -3 /tmp/app.log; python3 --version; dpkg -l python3-gi gir1.2-adw-1 gir1.2-gtk-4.0 xvfb | tail -4 | awk '{print $2,$3}'
