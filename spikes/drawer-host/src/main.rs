//! Throwaway spike for the web-app drawer (DESIGN.md: drawer-host). Answers:
//!   1. Do Google Messages, Google Chat, Claude and YouTube render in WebKitGTK, or refuse the browser?
//!   2. Does a web notification re-sent with a per-service `desktop-entry` hint show as that app?
//!   3. Does each service keep its own persistent session (separate logins)?
//!
//! Usage: drawer-host-spike [--ua chrome] [service...]   (default: all services)
//! Prints one `REPORT <service> ...` line per loaded page; `NOTIFY <service> id=<n>` per notification.

use std::collections::HashMap;
use std::path::PathBuf;

use gtk::gio;
use gtk::glib;
use gtk::glib::variant::ToVariant;
use gtk::prelude::*;
use webkit6::prelude::*;

const APP_ID: &str = "ostrich_os.drawer";

struct Service {
    id: &'static str,
    name: &'static str,
    url: &'static str,
}

// A local page (served on localhost, a secure context) that asks for notification permission and
// fires one, so (2) is testable without a login. `--write-test-page <dir>` writes it out.
const TEST_PAGE: &str = r#"<!doctype html><title>Drawer test</title><body><h1>Drawer notification test</h1><input id="q" autofocus placeholder="type here"><script>
document.body.insertAdjacentHTML('beforeend', '<p>initial: ' + Notification.permission + ' secure: ' + isSecureContext + '</p>');
// Real sites check Notification.permission first and only prompt when it is 'default'.
if (Notification.permission === 'granted') {
  new Notification('Test message', { body: 'Hello from the drawer test page' });
  document.body.insertAdjacentHTML('beforeend', '<p>notification sent</p>');
}
</script>"#;

const SERVICES: &[Service] = &[
    Service { id: "test", name: "Drawer Test", url: "http://localhost:8765/test.html" },
    Service { id: "messages", name: "Google Messages", url: "https://messages.google.com/web" },
    Service { id: "chat", name: "Google Chat", url: "https://chat.google.com" },
    Service { id: "claude", name: "Claude", url: "https://claude.ai" },
    Service { id: "youtube", name: "YouTube", url: "https://www.youtube.com" },
];

// Mirrors a current desktop Chrome UA; only used with --ua chrome to see whether sites gate on it.
const CHROME_UA: &str =
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36";

fn data_dir(service: &str) -> PathBuf {
    glib::user_data_dir().join("ostrich-os/drawer").join(service)
}

/// Re-sends a web notification through GTK's notification interface with the service's own app id,
/// so GNOME shows it as that app (name + icon from its .desktop file). GNOME 50 drops
/// org.freedesktop.Notifications calls that carry a desktop-entry hint for another app.
fn notify(service: &Service, title: &str, body: &str) {
    let app_id = format!("{APP_ID}.{}", service.id);
    let mut n: HashMap<String, glib::Variant> = HashMap::new();
    n.insert("title".into(), title.to_variant());
    n.insert("body".into(), body.to_variant());
    let id = format!("{}-{}", service.id, glib::monotonic_time());
    let params = (app_id.as_str(), id.as_str(), n).to_variant();

    let bus = match gio::bus_get_sync(gio::BusType::Session, gio::Cancellable::NONE) {
        Ok(bus) => bus,
        Err(e) => return eprintln!("NOTIFY {} error: {e}", service.id),
    };
    match bus.call_sync(
        Some("org.gtk.Notifications"),
        "/org/gtk/Notifications",
        "org.gtk.Notifications",
        "AddNotification",
        Some(&params),
        None,
        gio::DBusCallFlags::NONE,
        -1,
        gio::Cancellable::NONE,
    ) {
        Ok(_) => println!("NOTIFY {} app_id={app_id}", service.id),
        Err(e) => eprintln!("NOTIFY {} error: {e}", service.id),
    }
}

fn web_view(service: &'static Service, chrome_ua: bool) -> webkit6::WebView {
    let dir = data_dir(service.id);
    let session = webkit6::NetworkSession::new(
        Some(dir.join("data").to_str().unwrap()),
        Some(dir.join("cache").to_str().unwrap()),
    );
    // A persistent NetworkSession still keeps cookies in memory unless told where to store them,
    // which would sign the user out of every service on restart.
    if let Some(cookies) = session.cookie_manager() {
        cookies.set_persistent_storage(
            dir.join("data/cookies.sqlite").to_str().unwrap(),
            webkit6::CookiePersistentStorage::Sqlite,
        );
    }
    let view = webkit6::WebView::builder().network_session(&session).build();
    if chrome_ua {
        if let Some(settings) = webkit6::prelude::WebViewExt::settings(&view) {
            settings.set_user_agent(Some(CHROME_UA));
        }
    }

    view.connect_permission_request(|_, request| {
        eprintln!("DEBUG permission-request type={}", request.type_().name());
        if request.is::<webkit6::NotificationPermissionRequest>() {
            request.allow();
            return true;
        }
        false
    });

    // Sign-in buttons ("Sign in", "Continue with Google") open pop-ups. Give them a related view
    // (same session, keeps window.opener) in a small window, and close it when the page does.
    // When the pop-up reaches the service's own host, sign-in is done: load that page in the tab.
    let service_host = glib::Uri::parse(service.url, glib::UriFlags::NONE).ok().and_then(|u| u.host()).map(|h| h.to_string());
    view.connect_create(move |view, _action| {
        let popup = webkit6::WebView::builder().related_view(view).build();
        let window = gtk::Window::builder().title("Sign in").default_width(520).default_height(680).build();
        window.set_child(Some(&popup));
        let w = window.clone();
        popup.connect_ready_to_show(move |_| w.present());
        let w = window.clone();
        let parent = view.clone();
        popup.connect_close(move |_| {
            w.destroy();
            parent.reload();
        });
        let w = window.clone();
        let parent = view.clone();
        let host = service_host.clone();
        popup.connect_load_changed(move |popup, event| {
            if event != webkit6::LoadEvent::Committed {
                return;
            }
            let uri = popup.uri().unwrap_or_default().to_string();
            let popup_host = glib::Uri::parse(&uri, glib::UriFlags::NONE).ok().and_then(|u| u.host()).map(|h| h.to_string());
            println!("POPUP {} host={}", service.id, popup_host.as_deref().unwrap_or("?"));
            if popup_host.is_some() && popup_host == host {
                parent.load_uri(&uri);
                w.destroy();
            }
        });
        Some(popup.upcast())
    });

    view.connect_show_notification(move |_, n| {
        notify(service, &n.title().unwrap_or_default(), &n.body().unwrap_or_default());
        true // handled: suppress WebKit's own (generic) notification
    });

    view.connect_load_changed(move |view, event| {
        if event != webkit6::LoadEvent::Finished {
            return;
        }
        let uri = view.uri().unwrap_or_default();
        let title = view.title().unwrap_or_default();
        let script = "(document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').slice(0, 300)";
        // Single-page apps render after load-finished; read the text once they have settled.
        let view = view.clone();
        glib::timeout_add_seconds_local_once(8, move || {
            view.evaluate_javascript(script, None, None, gio::Cancellable::NONE, move |res| {
                let text = res.map(|v| v.to_str().to_string()).unwrap_or_else(|e| format!("<js error: {e}>"));
                println!("REPORT {} uri={uri} title={title:?} text={text:?}", service.id);
            });
        });
    });

    view.load_uri(service.url);
    view
}

/// Drawer services are chosen by the user, so their origins get notification permission up front
/// (WebKit otherwise denies Notification.requestPermission() calls made without a user gesture).
fn grant_notifications(origins: Vec<String>) {
    let context = webkit6::WebContext::default().expect("default WebContext");
    context.connect_initialize_notification_permissions(move |ctx| {
        eprintln!("DEBUG initialize-notification-permissions: {origins:?}");
        let allowed: Vec<webkit6::SecurityOrigin> =
            origins.iter().map(|o| webkit6::SecurityOrigin::for_uri(o)).collect();
        let allowed: Vec<&webkit6::SecurityOrigin> = allowed.iter().collect();
        ctx.initialize_notification_permissions(&allowed, &[]);
    });
}

fn main() -> glib::ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--write-test-page") {
        let dir = PathBuf::from(args.get(1).expect("dir"));
        std::fs::write(dir.join("test.html"), TEST_PAGE).expect("write test page");
        return glib::ExitCode::SUCCESS;
    }
    let chrome_ua = args.windows(2).any(|w| w[0] == "--ua" && w[1] == "chrome");
    let wanted: Vec<String> = args.iter().filter(|a| *a != "--ua" && *a != "chrome").cloned().collect();

    let app = gtk::Application::builder()
        .application_id(APP_ID)
        .flags(gio::ApplicationFlags::NON_UNIQUE | gio::ApplicationFlags::HANDLES_COMMAND_LINE)
        .build();
    app.connect_command_line(|app, _| {
        app.activate();
        glib::ExitCode::SUCCESS
    });
    let origins: Vec<String> = SERVICES
        .iter()
        .map(|s| s.url.to_string())
        .collect();
    app.connect_activate(move |app| {
        grant_notifications(origins.clone());
        let stack = gtk::Stack::new();
        for service in SERVICES.iter().filter(|s| wanted.is_empty() || wanted.iter().any(|w| w == s.id)) {
            stack.add_titled(&web_view(service, chrome_ua), Some(service.id), service.name);
        }
        let switcher = gtk::StackSwitcher::builder().stack(&stack).build();
        let header = gtk::HeaderBar::builder().title_widget(&switcher).build();
        let window = gtk::ApplicationWindow::builder()
            .application(app)
            .title("Drawer spike")
            .default_width(1100)
            .default_height(800)
            .child(&stack)
            .build();
        window.set_titlebar(Some(&header));
        window.present();
    });
    app.run_with_args::<&str>(&[])
}
