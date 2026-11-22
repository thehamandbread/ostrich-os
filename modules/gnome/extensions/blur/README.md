# Blur (part of Ostrich OS)

Frosted-glass blur behind GNOME Shell's top bar, menus, quick settings, notification banners, app
folders, the overview and the lock screen. Each surface can be switched to a solid colour, and power
saver keeps the cost down.

- **GNOME 50.** Works on its own; no other Ostrich OS part is needed.
- **Settings:** the extension's preferences window (`gnome-extensions prefs blur@ostrich-os`), or
  `gsettings` under `org.gnome.shell.extensions.ostrich-os.blur`.
- **The dock switch** blurs the Ostrich Dock only; it does nothing for Ubuntu Dock or Dash to Dock.
- **Lock screen:** the extension also runs there, only to style the wallpaper; it removes every live
  backdrop while the screen is locked.
- **What blurs what:** the dock blurs live, behind the windows near it. The top bar blurs the wallpaper
  only. Menus, quick settings, banners and app folders blur what is behind them while they are open,
  and the overview blurs a copy of the wallpaper made once.
- **Power saver** (or *High contrast*): the top bar and dock blur the wallpaper only and the rest turn
  solid, so no live blur runs.

Part of [Ostrich OS](https://github.com/thehamandbread/ostrich-os). Licence: GPL-2.0-or-later.
