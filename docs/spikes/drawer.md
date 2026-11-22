# Spike: web-app drawer host (2026-10-20)

Throwaway code: `spikes/drawer-host/` (Rust, gtk4 0.11 + webkit6 0.6). It was built and run inside the test VM (Ubuntu 26.04.1, GNOME Shell 50.1, GTK 4.22, WebKitGTK 2.52) and never on the host.

## Questions and answers

| Question | Answer |
|---|---|
| Do the sites render in WebKitGTK? | **Yes.** Messages, Claude and YouTube render their real UI with WebKit's own user agent. A Chrome user agent changed nothing. Chat redirects to its marketing page when signed out (expected). |
| Can a notification show as the service itself? | **Yes, through `org.gtk.Notifications.AddNotification(app_id, …)`** with app ID `ostrich_os.drawer.<service>` and a matching `.desktop` file. GNOME shows the service's name and icon, even when sent from the drawer process that owns the window. |
| Does the `desktop-entry` hint on `org.freedesktop.Notifications` work? | **No.** GNOME 50 silently drops those notifications (tested with our entries and with Firefox's). Without the hint, the notification is labelled with the sender's own app ID. |
| Can sites post notifications without a prompt? | **Yes.** Grant the service origins in `WebContext::initialize-notification-permissions`; pages then see `Notification.permission === 'granted'`. `Notification.requestPermission()` without a user gesture still returns `denied`, but sites check `permission` first. |
| Separate logins per service? | **Yes.** One `NetworkSession` per service, with data and cache under `~/.local/share/ostrich-os/drawer/<service>/`. |
| Memory | Four signed-out services loaded at once: about **1.65 GB PSS** in total (UI process about 160 MB under llvmpipe, network process about 40 MB, web processes 50–480 MB each; YouTube and Claude are the heaviest). This drives the "only messaging stays loaded" rule. |

## Other findings

- In the VM, `xdg-desktop-portal` crashes (SIGSEGV) every time a GTK4 app activates it. This is an Ubuntu issue rather than ours. Watch for it on real hardware, since the drawer must not depend on the portal.
- WebKit runs its web processes in a bubblewrap sandbox by default. Good, keep it.
- WebKit's cache is persistent per service, so a changed page can be served stale. Use the low-memory cache model.

## Spike (b): placing the window from a Shell extension

Code: `spikes/drawer-ext/drawer-spike@ostrich-os/`. A GNOME 50 extension finds the drawer window by its GTK application ID and is driven over D-Bus (`Toggle`, `State`).

| Check | Result |
|---|---|
| Place and size it under the top bar (centred, 50 % × 60 % of the monitor) | **Works**: `move_resize_frame` on Wayland, frame exactly as requested |
| Slide down / up | **Works**: easing the window actor's `translation_y`; hidden = minimized, so WebKit throttles the pages |
| Above other windows, on every workspace | **Works**: `make_above()`, `stick()` |
| Focus and typing | **Works**: typed text lands in the page's input immediately after `Toggle` |
| Out of Alt+Tab | **Works**: filtered in `Meta.Display.get_tab_list` (the holder-monitor approach); Alt+Tab with only the drawer open shows nothing |
| Out of the dock | Not yet: Ubuntu Dock still shows a running icon. Our own dock filters it out. |

For the real drawer: an undecorated window (no title bar) with rounded bottom corners, and the hotkey registered through the extension's GSettings schema.

## Sign-in test (user, in the VM window)

- **Google Chat: works.** Google did not block the embedded browser. The test exposed two gaps in the spike, both fixed:
  1. **Pop-ups.** "Sign in" opens a new window, which the spike ignored, so the click did nothing. It now creates a related view in a small window and hands the page back to the tab once the pop-up reaches `chat.google.com`.
  2. **Cookies were in memory only.** A persistent `NetworkSession` still needs `cookie_manager().set_persistent_storage(…, Sqlite)`; without it every restart signs out. With it, Chat opened straight into `chat.google.com/app/home` after a restart.
- **Google Messages:** Google sign-in went through. Phone pairing (QR code) is still to do, at the user's convenience.

## Still open

- Messages QR pairing, and a real incoming Chat or Messages notification arriving as that app.
