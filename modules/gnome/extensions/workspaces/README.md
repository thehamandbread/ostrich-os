# Workspaces (part of Ubuntu Ostrich)

A workspace bar in the top-left corner: one pill per workspace with its name, click or scroll to
switch. Workspaces can be renamed, and a workspace is given the name last used for the apps on it
("smart names").

- **GNOME 50.** Works on its own; no other Ubuntu Ostrich part is needed.
- **Settings:** the extension's preferences window (`gnome-extensions prefs workspaces@ubuntu-ostrich`),
  or `gsettings` under `org.gnome.shell.extensions.ubuntu-ostrich.workspaces`.
- **Scrolling:** one scroll movement moves one workspace, wheel or touchpad.
- **Shortcuts** (change them with `gsettings`): new workspace `Super+Alt+N`, rename `Super+Alt+R`,
  move left or right `Super+Alt+Page Up` / `Page Down`.
- It takes the place of the top-left *Activities* button; turn the extension off and the button is back.

Part of [Ubuntu Ostrich](https://github.com/thehamandbread/ubuntu-ostrich). Licence: GPL-2.0-or-later.
