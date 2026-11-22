#!/usr/bin/env bash
# Prints what Ostrich OS could have changed, for a before/after comparison (runs in the VM).
uid=$(id -u)
export XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus
echo "== dconf"
# Keys GNOME and apps rewrite on their own just by being used are left out (window sizes,
# "last shown" stamps, per-app notification entries, recent files, and toolkit-accessibility,
# which GNOME writes at login, and Ubuntu's update manager's launch-time stamp).
dconf dump / | grep -v -E '^(toolkit-accessibility=|launch-time=|window-|last-|release-check-time=|recent|timestamp|.*-size=|.*-position=|maximized=|sidebar-width|welcome-dialog|app-picker-layout|.*state=)' |
	awk '/^\[org\/gnome\/desktop\/notifications\/application\// {skip=1; next} /^\[/ {skip=0} !skip'
echo "== extension lists"
gsettings get org.gnome.shell enabled-extensions
gsettings get org.gnome.shell disabled-extensions
echo "== extensions"
ls ~/.local/share/gnome-shell/extensions 2>/dev/null
echo "== files"
for p in ~/.bashrc ~/.gitconfig ~/.config/xdg-terminals.list ~/.config/ghostty ~/.config/gtk-3.0 ~/.config/gtk-4.0 ~/.config/autostart \
	~/.config/chezmoi ~/.config/ostrich-os ~/.config/systemd/user ~/.config/pipewire ~/.local/bin ~/.local/libexec \
	~/.local/share/gnome-shell/extensions ~/.local/share/applications ~/.local/share/icons/hicolor \
	~/.local/share/backgrounds ~/.local/share/ostrich-os ~/.config/mimeapps.list; do
	[ -e "$p" ] && find "$p" -type f -not -path '*/gschemas.compiled' -print0 | sort -z | xargs -0 -r md5sum
done
echo "== system"
ls /usr/libexec/ostrich-os /usr/share/polkit-1/actions/*ostrich-os* /etc/systemd/system/ostrich-os* /etc/modprobe.d/*ostrich-os* /etc/udev/rules.d/*ostrich-os* 2>/dev/null || true # none: fine
