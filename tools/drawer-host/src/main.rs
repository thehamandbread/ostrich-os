//! ostrich-drawer: Ostrich Drawer, web apps that drop down from the top bar (DESIGN.md: drawer-host).
//!
//! Any web page as a tab, each with its own persistent login. Tabs load the first time they're
//! opened, can be unloaded by hand (right-click a tab) and non-keep-alive tabs unload by themselves
//! after `idle_unload_minutes` hidden. Notifications go out under each service's own app id, so GNOME
//! shows them as that app; clicking one runs `--show <id>`, which this single instance receives.
//!
//! The window is only the site: no bar. Window placement, the slide animation, the top-bar icons
//! and their menus (add, unload, remove...) belong to the drawer shell extension. Esc or Ctrl+W
//! folds it up, Alt+Left/Right and the mouse's side buttons go back and forward, Ctrl+R reloads.
//! This app exposes GApplication actions over D-Bus (org.gtk.Actions on /ubuntu_ostrich/drawer):
//!   toggle, show(s), mute(b)               the drawer as a whole
//!   load(s) unload(s) reload(s) back(s) remove(s) add(s)
//!   elsewhere(s)                           a DRM site: its own app, or the browser
//!   pin(sb) keep(sb) mute-site(sb)         a site's top-bar icon, keep-alive, notifications
//!   set-size((suu))                        the size the user resized a site to
//!   use-set((asas))                        an environment's sites and keep-alive ones; ([],[]) ends it
//!   visible(b)                             from the extension: shown or hidden (Wayland doesn't tell
//!                                          an app it was minimized)
//!   state                                  read-only: JSON of the sites and the drawer, for the
//!                                          extension (its Changed signal means nothing polls)
//!
//!   ostrich-drawer [--show ID] [--hidden]
//!   ostrich-drawer --list | --recommended | --add URL|ID | --remove ID | --pin ID | --unpin ID
//!   ostrich-drawer --elsewhere ID                                        (a DRM site, elsewhere)
//!                                                                         (used by the wizard)

mod config;
mod recommended;

use config::{Config, Service};
use gtk::gio;
use gtk::glib;
use gtk::glib::variant::ToVariant;
use gtk::prelude::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;
use webkit6::prelude::*;

// No dash before the last dot: WebKit writes this id into its sandbox's /.flatpak-info, and
// xdg-desktop-portal 1.21 rejects such an id without an error and crashes (upstream #2123), which
// Ubuntu shows as "internal error" the first time a site opens.
const APP_ID: &str = "ubuntu_ostrich.drawer";

fn data_root() -> PathBuf {
    glib::user_data_dir().join("ubuntu-ostrich/drawer")
}

fn config_path() -> PathBuf {
    glib::user_config_dir().join("ubuntu-ostrich/drawer.toml")
}

/// The sites, and whether they really came from the file. Only then may `build` delete the data of
/// sites that aren't in it: a fallback to the defaults would otherwise sign every other site out.
fn load_config() -> (Config, bool) {
    load_config_at(&config_path())
}

fn load_config_at(path: &std::path::Path) -> (Config, bool) {
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        // First run: the defaults, saved.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let c = Config::for_memory(mem_total_kb());
            save_config(&c);
            return (c, true);
        }
        // There but unreadable (permissions): the defaults for now, the file left alone.
        Err(e) => {
            eprintln!("can't read {}: {e}; using the defaults", path.display());
            return (Config::default(), false);
        }
    };
    let parsed = std::str::from_utf8(&bytes)
        .map_err(|e| e.to_string())
        .and_then(|t| {
            // An empty file is a save that never finished, not "no sites".
            if t.trim().is_empty() {
                Err("the file is empty".to_string())
            } else {
                Config::parse(t).map_err(|e| e.to_string())
            }
        });
    match parsed {
        Ok(c) => (c, true),
        Err(e) => {
            // Moved aside, each time under its own name, so the next save (any pin or resize)
            // can't write the defaults over the user's sites.
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_nanos());
            let broken = path.with_extension(format!("toml.broken-{stamp}"));
            let _ = std::fs::rename(path, &broken);
            eprintln!(
                "{e}; using the defaults (the file is now {})",
                broken.display()
            );
            (Config::default(), false)
        }
    }
}

/// The machine's memory (MemTotal), 0 if unknown.
fn mem_total_kb() -> u64 {
    std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|t| config::kb_field(&t, "MemTotal"))
        .unwrap_or(0)
}

fn save_config(c: &Config) {
    let path = config_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let header =
        "# Ostrich Drawer's sites (Ubuntu Ostrich). Edit here or with the drawer's + button.\n";
    // Written beside it, then renamed over it: a crash or a full disk mid-write never leaves an
    // empty or half file (which read as "no sites").
    let tmp = path.with_extension("toml.tmp");
    if std::fs::write(&tmp, format!("{header}{}", c.to_toml())).is_ok() {
        let _ = std::fs::rename(&tmp, &path);
    }
}

fn service_app_id(id: &str) -> String {
    format!("{APP_ID}.{id}")
}

/// The site's favicon, saved the first time its page shows one.
fn favicon_path(id: &str) -> PathBuf {
    data_root().join(id).join("icon.png")
}

/// The favicon if there is one, else the configured icon, else a generic one.
fn icon_for(s: &Service) -> String {
    let fav = favicon_path(&s.id);
    if fav.exists() {
        return fav.to_string_lossy().into_owned();
    }
    s.icon
        .clone()
        .unwrap_or_else(|| "web-browser-symbolic".into())
}

/// One .desktop file per service, so notifications show its name and icon and clicking one opens it.
fn write_desktop_file(s: &Service, exe: &str) {
    let dir = glib::user_data_dir().join("applications");
    let _ = std::fs::create_dir_all(&dir);
    let icon = icon_for(s);
    let text = format!(
        "[Desktop Entry]\nType=Application\nName={}\nComment=Web app in Ostrich Drawer\nIcon={icon}\nExec={exe} --show {}\nNoDisplay=true\nX-GNOME-UsesNotifications=true\n",
        s.name, s.id
    );
    let path = dir.join(format!("{}.desktop", service_app_id(&s.id)));
    if std::fs::read_to_string(&path).ok().as_deref() != Some(text.as_str()) {
        let _ = std::fs::write(path, text);
    }
}

fn remove_desktop_file(id: &str) {
    let _ = std::fs::remove_file(
        glib::user_data_dir()
            .join("applications")
            .join(format!("{}.desktop", service_app_id(id))),
    );
}

// ---- tabs --------------------------------------------------------------------------------------

struct Tab {
    service: Service,
    page: gtk::Box,
    view: Option<webkit6::WebView>,
    idle_source: Option<glib::SourceId>,
    unread: u32,
    /// The page didn't load (it shows what happened, and Try again).
    failed: bool,
}

/// An environment's drawer: the sites in the top bar, in order, and the ones kept loaded.
/// Held in memory only, so a restart always comes back to the normal set.
struct Set {
    sites: Vec<String>,
    keep: Vec<String>,
}

struct Drawer {
    app: gtk::Application,
    window: gtk::ApplicationWindow,
    stack: gtk::Stack,
    config: Config,
    tabs: Vec<Tab>,
    current: Option<String>,
    muted: bool,
    set: Option<Set>,
    /// Clicked or typed in since it was last shown: the extension stops hover-to-close.
    engaged: bool,
    /// On screen, as the extension reports it (`visible`).
    shown: bool,
    /// Counts requests to show the drawer (see `present`) and to hide it (`request_hide`).
    show_requests: u32,
    hide_requests: u32,
    /// The last site added and the last add that failed, for the extension's + popover.
    last_added: Option<String>,
    last_error: Option<String>,
    /// Counts failed adds, so the same mistake twice is still news (GLib merges state changes made
    /// in one go, so clearing and re-setting last_error never reached the extension).
    error_count: u32,
    /// The power-profiles-daemon proxies; held so their signals keep coming.
    power_proxies: Vec<gio::DBusProxy>,
    state: gio::SimpleAction,
    /// What each loaded site uses, in MB, by site id; see `measure_memory`.
    site_mb: HashMap<String, u32>,
    /// The web processes each site owns, by site id (claimed when its page commits).
    web_pids: HashMap<String, Vec<u32>>,
    /// Sites whose view was made but hold no web process yet, in the order they were made.
    web_waiting: Vec<String>,
    /// The machine's memory (MemTotal), for the warning about keeping many sites loaded.
    mem_total_kb: u64,
}

type Shared = Rc<RefCell<Drawer>>;

impl Drawer {
    /// Stays loaded: keep-alive in the config, or in the open environment's set.
    fn is_kept(&self, id: &str) -> bool {
        self.config
            .services
            .iter()
            .any(|s| s.id == id && s.keep_alive)
            || self
                .set
                .as_ref()
                .is_some_and(|s| s.keep.iter().any(|k| k == id))
    }

    /// The sites with a top-bar icon, in order.
    /// The average a kept-loaded site uses, in MB (0: none measured yet), for the small-machine warning.
    fn kept_site_mb(&self) -> u32 {
        let kept: Vec<u32> = self
            .tabs
            .iter()
            .filter(|t| self.is_kept(&t.service.id))
            .filter_map(|t| self.site_mb.get(&t.service.id).copied())
            .collect();
        kept.iter()
            .sum::<u32>()
            .checked_div(kept.len() as u32)
            .unwrap_or(0)
    }

    fn bar(&self) -> Vec<String> {
        match &self.set {
            Some(set) => set
                .sites
                .iter()
                .filter(|id| self.tabs.iter().any(|t| &t.service.id == *id))
                .cloned()
                .collect(),
            None => self
                .tabs
                .iter()
                .filter(|t| t.service.pinned)
                .map(|t| t.service.id.clone())
                .collect(),
        }
    }
}

/// Updates the read-only `state` action, whose D-Bus Changed signal tells the extension.
fn publish(d: &Shared) {
    let (json, action) = {
        let dr = d.borrow();
        let sites: Vec<serde_json::Value> = dr
            .tabs
            .iter()
            .map(|t| {
                let s = &t.service;
                serde_json::json!({
                    "id": s.id, "name": s.name, "url": s.url,
                    "pinned": s.pinned, "keep": dr.is_kept(&s.id), "muted": s.muted,
                    "loaded": t.view.is_some(), "unread": t.unread, "failed": t.failed,
                    "playing": t.view.as_ref().is_some_and(|v| v.is_playing_audio()),
                    "shape": s.shape().as_str(), "width": s.width, "height": s.height,
                    "icon": icon_for(s),
                    "mb": t.view.as_ref().and_then(|_| dr.site_mb.get(&s.id)),
                })
            })
            .collect();
        let kept = dr.tabs.iter().filter(|t| dr.is_kept(&t.service.id)).count();
        let json = serde_json::json!({
            "sites": sites,
            "bar": dr.bar(),
            "set": dr.set.is_some(),
            "active": dr.current,
            "shown": dr.shown,
            "engaged": dr.engaged,
            "showRequests": dr.show_requests,
            "hideRequests": dr.hide_requests,
            "lastAdded": dr.last_added,
            "lastError": dr.last_error,
            "errorCount": dr.error_count,
            "memWarning": config::memory_warning(kept, dr.kept_site_mb(), dr.mem_total_kb),
            "recommended": recommended::all().iter().map(|r| serde_json::json!({
                "id": r.id, "name": r.name, "group": r.group,
                "drm": r.status == recommended::Status::Drm,
                "app": r.app.is_some(),
                "added": dr.tabs.iter().any(|t| t.service.url == r.url || t.service.id == r.id),
            })).collect::<Vec<_>>(),
            "window": [dr.window.width(), dr.window.height()],
        })
        .to_string();
        (json, dr.state.clone())
    };
    if action
        .state()
        .and_then(|v| v.str().map(String::from))
        .as_deref()
        != Some(json.as_str())
    {
        action.set_state(&json.to_variant());
    }
}

/// This drawer's WebKit processes: (pid, is a web process). The network and GPU processes are
/// the others. They run inside the sandbox (bubblewrap), so they're further down than our children.
fn webkit_processes() -> Vec<(u32, bool)> {
    let mut procs = HashMap::new(); // pid: (parent pid, comm)
    for e in std::fs::read_dir("/proc").into_iter().flatten().flatten() {
        let Ok(pid) = e.file_name().to_string_lossy().parse::<u32>() else {
            continue;
        };
        if let Ok(stat) = std::fs::read_to_string(e.path().join("stat")) {
            if let Some((comm, ppid)) = config::stat_comm_ppid(&stat) {
                procs.insert(pid, (ppid, comm.to_string()));
            }
        }
    }
    let me = std::process::id();
    let ours = |mut pid: u32| {
        while let Some((ppid, _)) = procs.get(&pid) {
            if *ppid == me {
                return true;
            }
            pid = *ppid;
        }
        false
    };
    procs
        .iter()
        .filter(|(pid, (_, comm))| comm.starts_with("WebKit") && ours(**pid))
        .map(|(pid, (_, comm))| (*pid, comm.starts_with("WebKitWebProc")))
        .collect()
}

/// A process's memory in kB: PSS, so libraries it shares count once.
fn pss_kb(pid: u32) -> Option<u64> {
    let read = |f: &str| std::fs::read_to_string(format!("/proc/{pid}/{f}")).ok();
    read("smaps_rollup")
        .and_then(|t| config::kb_field(&t, "Pss"))
        .or_else(|| read("status").and_then(|t| config::kb_field(&t, "VmRSS")))
}

/// Gives the site that just committed a page the web processes that are new (see
/// `config::claim_processes`).
fn claim_web_processes(d: &Shared, id: &str) {
    let live: Vec<u32> = webkit_processes()
        .into_iter()
        .filter(|(_, web)| *web)
        .map(|(pid, _)| pid)
        .collect();
    let mut dr = d.borrow_mut();
    let dr = &mut *dr;
    config::claim_processes(&mut dr.web_pids, &mut dr.web_waiting, id, &live);
}

/// Measures what each loaded site costs, for the MB in its menu and the warning. The /proc reads
/// run on a worker thread: the window never waits for them.
fn measure_memory(d: &Shared) {
    let (pids, loaded) = {
        let dr = d.borrow();
        let loaded: Vec<String> = dr
            .tabs
            .iter()
            .filter(|t| t.view.is_some())
            .map(|t| t.service.id.clone())
            .collect();
        (dr.web_pids.clone(), loaded)
    };
    let dd = d.clone();
    glib::spawn_future_local(async move {
        let read = gio::spawn_blocking(|| {
            let mut web = HashMap::new();
            let mut shared = 0;
            for (pid, is_web) in webkit_processes() {
                let kb = pss_kb(pid).unwrap_or(0);
                if is_web {
                    web.insert(pid, kb);
                } else {
                    shared += kb;
                }
            }
            (web, shared)
        })
        .await;
        let Ok((web, shared)) = read else { return };
        let mb = config::site_memory_mb(&pids, &web, shared, &loaded);
        if std::mem::replace(&mut dd.borrow_mut().site_mb, mb.clone()) != mb {
            publish(&dd);
        }
    });
}

/// Measures once, a little later (a page is still growing as it loads; an unloaded one's process
/// takes a moment to quit). One-shot, so nothing wakes up while the drawer is idle.
fn measure_later(d: &Shared, seconds: u32) {
    let dd = d.clone();
    glib::timeout_add_seconds_local_once(seconds, move || measure_memory(&dd));
}

/// Brings the drawer up. On Wayland an app can't unminimize its own window, so this also counts
/// the request in the published state, and the extension unminimizes it.
fn present(d: &Shared) {
    // Sites start unloaded (placeholder-first): the one on show loads when the drawer first opens,
    // however it was opened (an icon already loads its site; the shortcut and focus mode don't).
    let current = {
        let dr = d.borrow();
        dr.current
            .as_deref()
            .and_then(|id| dr.tabs.iter().position(|t| t.service.id == id))
    };
    if let Some(i) = current {
        load_tab(d, i);
    }
    let w = {
        let mut dr = d.borrow_mut();
        dr.show_requests += 1;
        dr.window.clone()
    };
    w.present();
    publish(d);
}

/// Asks the extension to slide the drawer away (Esc, Ctrl+W, a close request). Without the
/// extension (nobody reports it shown), it just minimizes.
fn request_hide(d: &Shared) {
    let (shown, w) = {
        let mut dr = d.borrow_mut();
        dr.hide_requests += 1;
        (dr.shown, dr.window.clone())
    };
    if shown {
        publish(d);
    } else {
        w.minimize();
    }
}

/// The current site's page, for the navigation keys.
fn current_view(d: &Shared) -> Option<webkit6::WebView> {
    let dr = d.borrow();
    let id = dr.current.as_deref()?;
    dr.tabs.iter().find(|t| t.service.id == id)?.view.clone()
}

/// The page shown for a site that isn't loaded: its icon, its name and a Load button.
fn placeholder(d: &Shared, service: &Service) -> gtk::Box {
    let b = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .valign(gtk::Align::Center)
        .halign(gtk::Align::Center)
        .vexpand(true)
        .build();
    let icon = icon_for(service);
    let image = if icon.starts_with('/') {
        gtk::Image::from_file(&icon)
    } else {
        gtk::Image::from_icon_name(&icon)
    };
    image.set_pixel_size(64);
    let name = gtk::Label::new(Some(&service.name));
    name.add_css_class("title-2");
    let hint = gtk::Label::new(Some("Unloaded to save memory"));
    hint.add_css_class("dimmed");
    let load = gtk::Button::with_label("Load");
    load.add_css_class("suggested-action");
    load.add_css_class("pill");
    load.set_halign(gtk::Align::Center);
    let (dd, id) = (d.clone(), service.id.clone());
    load.connect_clicked(move |_| {
        let idx = dd.borrow().tabs.iter().position(|t| t.service.id == id);
        if let Some(i) = idx {
            load_tab(&dd, i);
        }
    });
    for w in [
        image.upcast_ref::<gtk::Widget>(),
        name.upcast_ref(),
        hint.upcast_ref(),
        load.upcast_ref(),
    ] {
        b.append(w);
    }
    b
}

/// Marks a site's page as failed (or loaded again) and tells the extension, when it changed.
fn set_failed(d: &Shared, id: &str, failed: bool) {
    let changed = {
        let mut dr = d.borrow_mut();
        let Some(t) = dr.tabs.iter_mut().find(|t| t.service.id == id) else {
            return;
        };
        std::mem::replace(&mut t.failed, failed) != failed
    };
    if changed {
        publish(d);
    }
}

/// The page shown when a site didn't load: what happened, Try again, and Open in browser.
fn failed_page(
    view: &webkit6::WebView,
    page: &gtk::Box,
    name: &str,
    url: &str,
    why: &str,
) -> gtk::Box {
    let b = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .valign(gtk::Align::Center)
        .halign(gtk::Align::Center)
        .vexpand(true)
        .build();
    let title = gtk::Label::new(Some(&format!("{name} didn't load")));
    title.add_css_class("title-2");
    let detail = gtk::Label::new(Some(&format!("Check that you're online. ({why})")));
    detail.set_wrap(true);
    detail.set_justify(gtk::Justification::Center);
    detail.set_max_width_chars(40);
    let again = gtk::Button::with_label("Try again");
    again.add_css_class("suggested-action");
    again.add_css_class("pill");
    let (v, pg) = (view.clone(), page.clone());
    again.connect_clicked(move |_| {
        set_page(&pg, &v);
        v.reload();
    });
    let browser = gtk::Button::with_label("Open in browser");
    browser.add_css_class("pill");
    let u = url.to_string();
    browser.connect_clicked(move |_| {
        let _ = gio::AppInfo::launch_default_for_uri(&u, None::<&gio::AppLaunchContext>);
    });
    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    buttons.set_halign(gtk::Align::Center);
    buttons.append(&again);
    buttons.append(&browser);
    for w in [
        title.upcast_ref::<gtk::Widget>(),
        detail.upcast_ref(),
        buttons.upcast_ref(),
    ] {
        b.append(w);
    }
    b
}

fn set_page(page: &gtk::Box, child: &impl IsA<gtk::Widget>) {
    while let Some(c) = page.first_child() {
        page.remove(&c);
    }
    page.append(child);
}

fn session_for(id: &str) -> webkit6::NetworkSession {
    // The sites' cookies and storage: private to this user, whatever the home folder's mode.
    let root = data_root();
    let _ = std::fs::create_dir_all(&root);
    let _ = std::fs::set_permissions(&root, std::os::unix::fs::PermissionsExt::from_mode(0o700));
    let dir = root.join(id);
    let session = webkit6::NetworkSession::new(
        Some(dir.join("data").to_str().unwrap()),
        Some(dir.join("cache").to_str().unwrap()),
    );
    if let Some(data) = session.website_data_manager() {
        data.set_favicons_enabled(true);
    }
    // A persistent session still keeps cookies in memory unless told where to store them.
    if let Some(cookies) = session.cookie_manager() {
        cookies.set_persistent_storage(
            dir.join("data/cookies.sqlite").to_str().unwrap(),
            webkit6::CookiePersistentStorage::Sqlite,
        );
    }
    session
}

fn notify(app: &gtk::Application, service: &Service, title: &str, body: &str) {
    let mut n: HashMap<String, glib::Variant> = HashMap::new();
    n.insert("title".into(), title.to_variant());
    n.insert("body".into(), body.to_variant());
    let id = format!("{}-{}", service.id, glib::monotonic_time());
    let params = (service_app_id(&service.id), id, n).to_variant();
    if let Some(conn) = app.dbus_connection() {
        conn.call(
            Some("org.gtk.Notifications"),
            "/org/gtk/Notifications",
            "org.gtk.Notifications",
            "AddNotification",
            Some(&params),
            None,
            gio::DBusCallFlags::NONE,
            -1,
            gio::Cancellable::NONE,
            |r| {
                if let Err(e) = r {
                    eprintln!("notification failed: {e}");
                }
            },
        );
    }
}

fn host_of_uri(uri: &str) -> Option<String> {
    config::host_of(uri)
}

/// A site the drawer can't play (DRM): its own app if it has one (the snap, else the Flatpak),
/// App Center's page for that snap when neither is installed, or the site in the browser.
fn open_elsewhere(id: &str) {
    let Some(site) = recommended::find(id) else {
        return;
    };
    let none = None::<&gio::AppLaunchContext>;
    if let Some(app) = &site.app {
        let ids = [
            Some(format!("{app}_{app}.desktop")),
            site.flatpak.as_ref().map(|f| format!("{f}.desktop")),
        ];
        let installed = gio::AppInfo::all();
        for desktop in ids.into_iter().flatten() {
            let found = installed
                .iter()
                .find(|a| a.id().as_deref() == Some(desktop.as_str()));
            if found.is_some_and(|info| info.launch(&[], none).is_ok()) {
                return;
            }
        }
        if gio::AppInfo::launch_default_for_uri(&format!("snap://{app}"), none).is_ok() {
            return;
        }
    }
    let _ = gio::AppInfo::launch_default_for_uri(&site.url, none);
}

/// Turns off one of WebKit's runtime features (by its identifier) for a view.
fn disable_feature(settings: &webkit6::Settings, id: &str) {
    let Some(list) = webkit6::Settings::all_features() else {
        return;
    };
    for f in (0..list.length()).filter_map(|i| list.get(i)) {
        if f.identifier().as_deref() == Some(id) {
            settings.set_feature_enabled(&f, false);
        }
    }
}

/// Creates the WebView for a tab (first open, or after an unload).
fn load_tab(d: &Shared, idx: usize) {
    let (service, page) = {
        let dr = d.borrow();
        if dr.tabs[idx].view.is_some() {
            return;
        }
        (dr.tabs[idx].service.clone(), dr.tabs[idx].page.clone())
    };
    measure_later(d, 30);
    d.borrow_mut().web_waiting.push(service.id.clone());
    let view = webkit6::WebView::builder()
        .network_session(&session_for(&service.id))
        .build();
    view.set_vexpand(true);
    if let Some(settings) = WebViewExt::settings(&view) {
        if let Some(ua) = &service.user_agent {
            settings.set_user_agent(Some(ua));
        }
        if !recommended::media_controls(&service.url) {
            disable_feature(&settings, "MediaSessionEnabled");
        }
    }

    let name = service.name.clone();
    let site_url = service.url.clone();
    view.connect_permission_request(move |view, req| {
        // Notifications: the service's own site may (DESIGN.md: granted up front), nothing else.
        if req.is::<webkit6::NotificationPermissionRequest>() {
            if view.uri().is_some_and(|u| config::same_site(&site_url, &u)) {
                req.allow();
            } else {
                req.deny();
            }
            return true;
        }
        // Camera, microphone or the screen: asked every time, naming the site; "Don't allow" is the
        // default. Anything else is denied (WebKit's default when nobody answers).
        if let Some(media) = req.downcast_ref::<webkit6::UserMediaPermissionRequest>() {
            let what = media_wanted(media.is_for_video_device(), media.is_for_audio_device());
            let dialog = gtk::AlertDialog::builder()
                .modal(true)
                .message(format!("Let {name} use {what}?"))
                .detail("Only while you're on this page. It asks again next time.")
                .buttons(["Don't allow", "Allow"])
                .cancel_button(0)
                .default_button(0)
                .build();
            let req = req.clone();
            let parent = view.root().and_downcast::<gtk::Window>();
            dialog.choose(parent.as_ref(), None::<&gio::Cancellable>, move |r| {
                if matches!(r, Ok(1)) {
                    req.allow();
                } else {
                    req.deny();
                }
            });
            return true;
        }
        false
    });
    // A page that didn't load says so, with a way on, instead of a blank panel. Not for a load that
    // was cancelled or stopped by policy (a navigation that opened in the browser instead).
    let (pg, name, url) = (page.clone(), service.name.clone(), service.url.clone());
    let (dd, sid) = (d.clone(), service.id.clone());
    view.connect_load_failed(move |v, _, _, err| {
        if err.matches(webkit6::NetworkError::Cancelled)
            || err.matches(gio::IOErrorEnum::Cancelled)
            || err.kind::<webkit6::PolicyError>().is_some()
        {
            return false;
        }
        set_page(&pg, &failed_page(v, &pg, &name, &url, err.message()));
        set_failed(&dd, &sid, true);
        // It will never commit a page, so it must not wait for (and take) another site's process.
        dd.borrow_mut().web_waiting.retain(|s| s != &sid);
        true
    });
    // Leaving the site (a link, a script, a redirect) opens the browser instead, so a drawer site
    // can't quietly turn into another one. Checked at the main frame's response: its address is
    // final there (load-changed's Started still has the old one), and embedded frames (captchas,
    // players) aren't the page's own.
    let site_url = service.url.clone();
    view.connect_decide_policy(move |_, decision, kind| {
        if kind != webkit6::PolicyDecisionType::Response {
            return false;
        }
        let Some(r) = decision.downcast_ref::<webkit6::ResponsePolicyDecision>() else {
            return false;
        };
        let uri = r.request().and_then(|q| q.uri()).unwrap_or_default();
        if !r.is_main_frame_main_resource() || config::stays_in_drawer(&site_url, &uri) {
            return false;
        }
        decision.ignore();
        let _ = gio::AppInfo::launch_default_for_uri(&uri, None::<&gio::AppLaunchContext>);
        true
    });
    let (dd, sid) = (d.clone(), service.id.clone());
    view.connect_load_changed(move |_, ev| {
        if ev == webkit6::LoadEvent::Committed {
            set_failed(&dd, &sid, false);
            claim_web_processes(&dd, &sid);
        }
    });
    let dd = d.clone();
    let svc = service.clone();
    view.connect_show_notification(move |_, n| {
        let dr = dd.borrow();
        let site_muted = dr.config.services.iter().any(|s| s.id == svc.id && s.muted);
        if !dr.muted && !site_muted {
            notify(
                &dr.app,
                &svc,
                &n.title().unwrap_or_default(),
                &n.body().unwrap_or_default(),
            );
        }
        true
    });
    let dd = d.clone();
    let sid = service.id.clone();
    view.connect_title_notify(move |v| {
        let count = config::unread_from_title(&v.title().unwrap_or_default());
        let changed = {
            let mut dr = dd.borrow_mut();
            let Some(tab) = dr.tabs.iter_mut().find(|t| t.service.id == sid) else {
                return;
            };
            let n = count.unwrap_or(0);
            std::mem::replace(&mut tab.unread, n) != n
        };
        if changed {
            publish(&dd);
        }
    });
    // Sound playing: the top bar shows a speaker on the site's icon, also while the drawer is
    // folded up (notes 20261101-224940, 225058). WebKit tells us; nothing polls.
    let dd = d.clone();
    view.connect_is_playing_audio_notify(move |_| publish(&dd));
    // The site's own icon, for the top bar, the unloaded page and its notifications.
    let dd = d.clone();
    let svc = service.clone();
    view.connect_favicon_notify(move |v| {
        let Some(texture) = v.favicon() else { return };
        let path = favicon_path(&svc.id);
        let _ = std::fs::create_dir_all(path.parent().unwrap());
        if texture.save_to_png(&path).is_err() {
            return;
        }
        write_desktop_file(&svc, &exe_path());
        publish(&dd);
    });
    // Sign-in pop-ups get a related view (same session); when one reaches the service's own host,
    // sign-in is done and the page moves into the tab. Its title shows the host it's on, live, so a
    // look-alike sign-in page can't hide where it is.
    let service_host = host_of_uri(&service.url);
    let site_url = service.url.clone();
    view.connect_create(move |view, action| {
        // A link that opens a new window and leaves the site (most links in a chat) goes to the
        // browser, not into a sign-in pop-up with the site's cookies.
        let uri = action.request().and_then(|r| r.uri()).unwrap_or_default();
        if !uri.is_empty() && !config::stays_in_drawer(&site_url, &uri) {
            let _ = gio::AppInfo::launch_default_for_uri(&uri, None::<&gio::AppLaunchContext>);
            return None;
        }
        let popup = webkit6::WebView::builder().related_view(view).build();
        // Transient for the drawer, so it stacks above it and the extension leaves it alone.
        let win = gtk::Window::builder()
            .title(popup_title(None))
            .default_width(520)
            .default_height(680)
            .build();
        win.set_transient_for(view.root().and_downcast_ref::<gtk::Window>());
        win.set_child(Some(&popup));
        let w = win.clone();
        popup.connect_uri_notify(move |p| w.set_title(Some(&popup_title(p.uri().as_deref()))));
        let w = win.clone();
        popup.connect_ready_to_show(move |_| w.present());
        let (w, parent) = (win.clone(), view.clone());
        popup.connect_close(move |_| {
            w.destroy();
            parent.reload();
        });
        let (w, parent, host) = (win.clone(), view.clone(), service_host.clone());
        popup.connect_load_changed(move |p, ev| {
            if ev != webkit6::LoadEvent::Committed {
                return;
            }
            let uri = p.uri().unwrap_or_default().to_string();
            if host.is_some() && host_of_uri(&uri) == host {
                parent.load_uri(&uri);
                w.destroy();
            }
        });
        Some(popup.upcast())
    });

    set_page(&page, &view);
    view.load_uri(&service.url);
    d.borrow_mut().tabs[idx].view = Some(view);
    publish(d);
}

/// Frees a tab's web process; the tab stays, greyed, and loads again when opened.
/// The borrow is dropped before touching widgets: tearing a WebView down can emit signals whose
/// handlers borrow the drawer again.
/// Power saver: background tabs that aren't keep-alive are unloaded at once (the visible one stays
/// while the drawer is open). Keep-alive services keep notifying.
/// What a site asked for, in words. A request for neither the camera nor the microphone is for the
/// screen (the bindings don't expose WebKit's is_for_display_device).
fn media_wanted(camera: bool, mic: bool) -> &'static str {
    match (camera, mic) {
        (true, true) => "your camera and microphone",
        (true, false) => "your camera",
        (false, true) => "your microphone",
        (false, false) => "your screen",
    }
}

/// The sign-in pop-up's title: the host it's showing, and a warning when the page isn't encrypted.
fn popup_title(uri: Option<&str>) -> String {
    match uri.and_then(host_of_uri) {
        Some(host) if uri.is_some_and(|u| u.starts_with("https://")) => format!("Sign in · {host}"),
        Some(host) => format!("Sign in · {host} (not secure)"),
        None => "Sign in".into(),
    }
}

/// In a call (using the camera, microphone or screen): never unloaded by itself.
fn in_call(tab: &Tab) -> bool {
    use webkit6::MediaCaptureState::None as Off;
    tab.view.as_ref().is_some_and(|v| {
        v.camera_capture_state() != Off
            || v.microphone_capture_state() != Off
            || v.display_capture_state() != Off
    })
}

fn unload_for_power_saver(d: &Shared) {
    let visible = d.borrow().shown;
    let current = d.borrow().current.clone();
    let dr = d.borrow();
    let victims: Vec<usize> = dr
        .tabs
        .iter()
        .enumerate()
        .filter(|(_, t)| t.view.is_some() && !dr.is_kept(&t.service.id) && !in_call(t))
        .filter(|(_, t)| !(visible && current.as_deref() == Some(t.service.id.as_str())))
        .map(|(i, _)| i)
        .collect();
    drop(dr);
    for i in victims {
        unload_tab(d, i);
    }
}

/// Watches power-profiles-daemon (both of its bus names) and reacts to power saver.
fn watch_power_profile(d: &Shared) {
    for (name, path) in [
        (
            "org.freedesktop.UPower.PowerProfiles",
            "/org/freedesktop/UPower/PowerProfiles",
        ),
        ("net.hadess.PowerProfiles", "/net/hadess/PowerProfiles"),
    ] {
        let d = d.clone();
        gio::DBusProxy::for_bus(
            gio::BusType::System,
            gio::DBusProxyFlags::DO_NOT_AUTO_START,
            None,
            name,
            path,
            name,
            None::<&gio::Cancellable>,
            move |res| {
                let Ok(proxy) = res else { return };
                // The daemon may start after the drawer (it's D-Bus activated): the proxy follows
                // its name, so watch both the owner and the property.
                let check = {
                    let d = d.clone();
                    move |p: &gio::DBusProxy| {
                        let saver = p
                            .cached_property("ActiveProfile")
                            .and_then(|v| v.str().map(|s| s == "power-saver"))
                            .unwrap_or(false);
                        if saver {
                            unload_for_power_saver(&d);
                        }
                    }
                };
                check(&proxy);
                let c = check.clone();
                proxy.connect_notify_local(Some("g-name-owner"), move |p, _| c(p));
                proxy.connect_local("g-properties-changed", false, move |args| {
                    if let Some(p) = args.first().and_then(|a| a.get::<gio::DBusProxy>().ok()) {
                        check(&p);
                    }
                    None
                });
                d.borrow_mut().power_proxies.push(proxy);
            },
        );
    }
}

fn unload_tab(d: &Shared, idx: usize) {
    let (view, page, service, src) = {
        let mut dr = d.borrow_mut();
        let Some(t) = dr.tabs.get_mut(idx) else {
            return;
        };
        (
            t.view.take(),
            t.page.clone(),
            t.service.clone(),
            t.idle_source.take(),
        )
    };
    if let Some(src) = src {
        src.remove();
    }
    if let Some(view) = view {
        // The view may not be on the page (its "didn't load" page is shown instead).
        if view.parent().as_ref() == Some(page.upcast_ref()) {
            page.remove(&view);
        }
        set_page(&page, &placeholder(d, &service));
        if let Some(t) = d.borrow_mut().tabs.get_mut(idx) {
            t.unread = 0;
            t.failed = false;
        }
        {
            let mut dr = d.borrow_mut();
            dr.web_pids.remove(&service.id);
            dr.web_waiting.retain(|s| s != &service.id);
        }
        publish(d);
        measure_later(d, 5);
    }
}

fn select(d: &Shared, id: &str) {
    let Some(idx) = d.borrow().tabs.iter().position(|t| t.service.id == id) else {
        return;
    };
    load_tab(d, idx);
    let idle = d.borrow().config.idle_unload_minutes;
    let previous = d.borrow_mut().current.replace(id.to_string());
    {
        let mut dr = d.borrow_mut();
        let tab = &mut dr.tabs[idx];
        if let Some(src) = tab.idle_source.take() {
            src.remove();
        }
        dr.stack.set_visible_child_name(id);
    }
    // The tab we left starts its idle countdown unless it's keep-alive. One-shot, only while hidden.
    // The timer finds the tab by id when it fires (tabs can be removed meanwhile).
    if let Some(prev) = previous.filter(|p| p != id) {
        let pidx = d.borrow().tabs.iter().position(|t| t.service.id == prev);
        if let Some(pidx) = pidx {
            if !d.borrow().is_kept(&prev) && idle > 0 {
                let dd = d.clone();
                let src = glib::timeout_add_seconds_local_once(idle * 60, move || {
                    let idx = dd.borrow().tabs.iter().position(|t| t.service.id == prev);
                    if let Some(idx) = idx {
                        dd.borrow_mut().tabs[idx].idle_source = None; // fired: don't remove it again
                        if !dd.borrow().is_kept(&prev) && !in_call(&dd.borrow().tabs[idx]) {
                            unload_tab(&dd, idx);
                        }
                    }
                });
                d.borrow_mut().tabs[pidx].idle_source = Some(src);
            }
        }
    }
    publish(d);
}

/// Dictionary names from the session's locale list ("en_US.UTF-8", "en_US", "en", "C"): the
/// language and region without the encoding, once each, "C" and "POSIX" left out.
fn spelling_languages<'a>(names: impl Iterator<Item = &'a str>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for n in names {
        let n = n.split(['.', '@']).next().unwrap_or(n);
        if n.is_empty() || n == "C" || n == "POSIX" || n.contains('-') || out.iter().any(|o| o == n)
        {
            continue;
        }
        out.push(n.to_string());
    }
    out
}

/// The script that hands the page a pasted image as a file, in a paste event on the focused element.
/// WebKitGTK inserts a pasted image into a text field itself but gives the page's own paste handler
/// (ChatGPT, Claude, Messages: they read `clipboardData.files`) an empty clipboardData, so the
/// drawer does the reading and dispatches the event itself.
fn paste_script(png_base64: &str) -> String {
    format!(
        "(() => {{ const bin = atob('{png_base64}'); \
         const bytes = Uint8Array.from(bin, c => c.charCodeAt(0)); \
         const dt = new DataTransfer(); \
         dt.items.add(new File([bytes], 'image.png', {{type: 'image/png'}})); \
         (document.activeElement || document.body).dispatchEvent(new ClipboardEvent('paste', \
         {{clipboardData: dt, bubbles: true, cancelable: true, composed: true}})); }})()"
    )
}

/// Ctrl+V with an image (and no text) on the clipboard: reads it and pastes it into the page as a
/// file. False when it isn't that case, so the page gets the key as usual.
fn paste_image(d: &Shared) -> bool {
    let Some(display) = gtk::gdk::Display::default() else {
        return false;
    };
    let clipboard = display.clipboard();
    let formats = clipboard.formats();
    if !formats.contains_type(gtk::gdk::Texture::static_type())
        || formats.contains_type(String::static_type())
        || current_view(d).is_none()
    {
        return false;
    }
    let dd = d.clone();
    glib::spawn_future_local(async move {
        let Ok(Some(texture)) = clipboard.read_texture_future().await else {
            return;
        };
        let png = texture.save_to_png_bytes();
        let script = paste_script(&glib::base64_encode(&png));
        if let Some(view) = current_view(&dd) {
            view.evaluate_javascript(&script, None, None, None::<&gio::Cancellable>, |_| {});
        }
    });
    true
}

/// The site after (dir 1) or before (dir -1) `current` in `bar`, wrapping; the first or last when
/// `current` isn't in it. Browser-style Ctrl+Tab inside the drawer.
fn step_in(bar: &[String], current: Option<&str>, dir: i32) -> Option<String> {
    if bar.is_empty() {
        return None;
    }
    let n = bar.len() as i32;
    let at = current.and_then(|c| bar.iter().position(|id| id == c));
    let to = match at {
        Some(i) => (i as i32 + dir).rem_euclid(n) as usize,
        None if dir > 0 => 0,
        None => bar.len() - 1,
    };
    Some(bar[to].clone())
}

/// Opens the site `pick` chooses from the bar's order (and the open one); true if there was one.
fn switch_site(d: &Shared, pick: impl Fn(&[String], Option<&str>) -> Option<String>) -> bool {
    let (bar, current) = {
        let dr = d.borrow();
        (dr.bar(), dr.current.clone())
    };
    match pick(&bar, current.as_deref()) {
        Some(id) => {
            select(d, &id);
            true
        }
        None => false,
    }
}

/// A site's page in the stack: its placeholder until it loads.
fn add_page(d: &Shared, service: Service) {
    let page = gtk::Box::new(gtk::Orientation::Vertical, 0);
    set_page(&page, &placeholder(d, &service));
    let mut dr = d.borrow_mut();
    dr.stack.add_named(&page, Some(&service.id));
    dr.tabs.push(Tab {
        service,
        page,
        view: None,
        idle_source: None,
        unread: 0,
        failed: false,
    });
}

/// Adds a site; `open` also shows its tab (and loads it).
fn add_site(d: &Shared, input: &str, open: bool) {
    let result = d.borrow_mut().config.add_site(input, None);
    match result {
        Ok(id) => {
            let (service, exe) = {
                let dr = d.borrow();
                (
                    dr.config
                        .services
                        .iter()
                        .find(|s| s.id == id)
                        .cloned()
                        .unwrap(),
                    exe_path(),
                )
            };
            save_config(&d.borrow().config);
            write_desktop_file(&service, &exe);
            grant_notifications(&d.borrow().config);
            let keep = service.keep_alive;
            add_page(d, service);
            {
                let mut dr = d.borrow_mut();
                dr.last_added = Some(id.clone());
                dr.last_error = None;
            }
            if open {
                select(d, &id);
            } else if keep {
                let idx = d.borrow().tabs.len() - 1;
                load_tab(d, idx);
            }
            publish(d);
        }
        Err(e) => {
            {
                let mut dr = d.borrow_mut();
                dr.last_error = Some(e);
                dr.error_count += 1;
            }
            publish(d);
        }
    }
}

/// Changes one site's settings, saves them and tells the extension.
fn update_site(d: &Shared, id: &str, change: impl FnOnce(&mut Service)) {
    {
        let mut dr = d.borrow_mut();
        let Some(s) = dr.config.get_mut(id) else {
            return;
        };
        change(s);
        let s = s.clone();
        if let Some(t) = dr.tabs.iter_mut().find(|t| t.service.id == id) {
            t.service = s;
        }
        save_config(&dr.config);
    }
    publish(d);
}

/// An environment's drawer: its keep-alive sites load, and loaded sites outside it that nothing
/// keeps are unloaded. An empty set goes back to the normal one.
fn use_set(d: &Shared, sites: Vec<String>, keep: Vec<String>) {
    d.borrow_mut().set = (!sites.is_empty() || !keep.is_empty()).then_some(Set { sites, keep });
    let (load, unload): (Vec<usize>, Vec<usize>) = {
        let dr = d.borrow();
        let in_set = |id: &str| {
            dr.set
                .as_ref()
                .is_none_or(|s| s.sites.iter().any(|x| x == id))
        };
        let load = dr
            .tabs
            .iter()
            .enumerate()
            .filter(|(_, t)| t.view.is_none() && dr.is_kept(&t.service.id))
            .map(|(i, _)| i)
            .collect();
        let unload = dr
            .tabs
            .iter()
            .enumerate()
            .filter(|(_, t)| {
                t.view.is_some() && !dr.is_kept(&t.service.id) && !in_set(&t.service.id)
            })
            .map(|(i, _)| i)
            .collect();
        (load, unload)
    };
    for i in load {
        load_tab(d, i);
    }
    for i in unload {
        unload_tab(d, i);
    }
    publish(d);
}

fn remove_site(d: &Shared, id: &str) {
    let idx = d.borrow().tabs.iter().position(|t| t.service.id == id);
    let Some(idx) = idx else { return };
    // Its cookies and storage go too, so removing a site signs you out of it: cleared through
    // WebKit (deleting the folder under its network process crashed it); `build` deletes the
    // emptied folder at the next start.
    let open = d.borrow().tabs[idx]
        .view
        .as_ref()
        .and_then(|v| v.network_session());
    if let Some(m) = open
        .unwrap_or_else(|| session_for(id))
        .website_data_manager()
    {
        m.clear(
            webkit6::WebsiteDataTypes::all(),
            glib::TimeSpan(0),
            None::<&gio::Cancellable>,
            |_| {},
        );
    }
    unload_tab(d, idx);
    let tab = d.borrow_mut().tabs.remove(idx);
    {
        let dr = d.borrow();
        dr.stack.remove(&tab.page);
    }
    d.borrow_mut().config.remove(id);
    save_config(&d.borrow().config);
    grant_notifications(&d.borrow().config);
    remove_desktop_file(id);
    let first = d.borrow().tabs.first().map(|t| t.service.id.clone());
    if let Some(f) = first {
        select(d, &f);
    }
    publish(d);
}

thread_local! {
    /// The sites granted notifications, read by the one initialize-notification-permissions handler.
    static GRANTED: RefCell<Option<Vec<String>>> = const { RefCell::new(None) };
}

/// Drawer services get notification permission up front (WebKit denies unprompted requests). Called
/// again when the list changes; the handler is connected once.
fn grant_notifications(c: &Config) {
    let origins = c.services.iter().map(|s| s.url.clone()).collect();
    if GRANTED.replace(Some(origins)).is_some() {
        return;
    }
    if let Some(ctx) = webkit6::WebContext::default() {
        ctx.connect_initialize_notification_permissions(|ctx| {
            let allowed: Vec<webkit6::SecurityOrigin> = GRANTED.with_borrow(|g| {
                g.iter()
                    .flatten()
                    .map(|o| webkit6::SecurityOrigin::for_uri(o))
                    .collect()
            });
            let refs: Vec<&webkit6::SecurityOrigin> = allowed.iter().collect();
            ctx.initialize_notification_permissions(&refs, &[]);
        });
    }
}

fn exe_path() -> String {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.to_str().map(String::from))
        .unwrap_or_else(|| "ostrich-drawer".into())
}

// The window is see-through and the frame inside it is rounded at the bottom (it drops from the top
// bar, so the top edge stays straight) and clips the page to that shape.
const CSS: &str = "
window.drawer { background: transparent; }
.drawer-frame { border-radius: 0 0 14px 14px; border: 1px solid alpha(currentColor, 0.15); border-top: none; background: @window_bg_color; }
.drawer .grip { background: alpha(currentColor, 0.18); border-radius: 3px; transition: background 150ms; }
.drawer .grip:hover { background: alpha(currentColor, 0.45); }
";

/// A resize handle: pressing it starts the compositor's own resize from that edge.
fn add_grip(
    overlay: &gtk::Overlay,
    window: &gtk::ApplicationWindow,
    edge: gtk::gdk::SurfaceEdge,
    (halign, width, height): (gtk::Align, i32, i32),
    cursor: &str,
) {
    let grip = gtk::Box::builder()
        .halign(halign)
        .valign(gtk::Align::End)
        .width_request(width)
        .height_request(height)
        .margin_bottom(3)
        .build();
    grip.add_css_class("grip");
    grip.set_cursor_from_name(Some(cursor));
    let press = gtk::GestureClick::new();
    let (w, g) = (window.clone(), grip.clone());
    press.connect_pressed(move |gesture, _, x, y| {
        let Some(top) = w
            .surface()
            .and_then(|s| s.downcast::<gtk::gdk::Toplevel>().ok())
        else {
            return;
        };
        let Some(p) = g.compute_point(&w, &gtk::graphene::Point::new(x as f32, y as f32)) else {
            return;
        };
        let (sx, sy) = w.surface_transform();
        top.begin_resize(
            edge,
            gesture.device().as_ref(),
            gesture.current_button() as i32,
            p.x() as f64 + sx,
            p.y() as f64 + sy,
            gesture.current_event_time(),
        );
    });
    grip.add_controller(press);
    overlay.add_overlay(&grip);
}

fn build(app: &gtk::Application) -> Shared {
    let provider = gtk::CssProvider::new();
    provider.load_from_string(CSS);
    gtk::style_context_add_provider_for_display(
        &gtk::gdk::Display::default().unwrap(),
        &provider,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );

    if let Some(ctx) = webkit6::WebContext::default() {
        ctx.set_cache_model(webkit6::CacheModel::DocumentViewer); // low memory
                                                                  // Red underlines and suggestions in text fields, in the session's languages (enchant, with
                                                                  // Ubuntu's hunspell dictionaries). Off by default in WebKitGTK.
        ctx.set_spell_checking_enabled(true);
        let languages = spelling_languages(glib::language_names().iter().map(|l| l.as_str()));
        if !languages.is_empty() {
            let refs: Vec<&str> = languages.iter().map(String::as_str).collect();
            ctx.set_spell_checking_languages(&refs);
        }
    }

    let (config, from_file) = load_config();
    // Data of sites removed earlier (nothing has them open yet); only when the sites are really
    // the user's (see load_config).
    let leftovers = if from_file {
        std::fs::read_dir(data_root())
            .into_iter()
            .flatten()
            .flatten()
            .collect()
    } else {
        Vec::new()
    };
    for e in leftovers {
        let id = e.file_name().to_string_lossy().into_owned();
        if !config.services.iter().any(|s| s.id == id) {
            let _ = std::fs::remove_dir_all(e.path());
        }
    }
    let exe = exe_path();
    for s in &config.services {
        write_desktop_file(s, &exe);
    }
    grant_notifications(&config);

    let window = gtk::ApplicationWindow::builder()
        .application(app)
        .title("Ostrich Drawer")
        .default_width(960)
        .default_height(640)
        .decorated(false)
        .build();
    window.add_css_class("drawer");
    // Only the site: the top-bar icons switch sites and hold the menus, so there's no bar here.
    let stack = gtk::Stack::builder()
        .vexpand(true)
        .transition_type(gtk::StackTransitionType::Crossfade)
        .transition_duration(120)
        .build();
    // A grip at the bottom edge resizes the site; the extension remembers the size.
    let overlay = gtk::Overlay::new();
    overlay.add_css_class("drawer-frame");
    overlay.set_overflow(gtk::Overflow::Hidden);
    overlay.set_child(Some(&stack));
    add_grip(
        &overlay,
        &window,
        gtk::gdk::SurfaceEdge::South,
        (gtk::Align::Center, 56, 5),
        "ns-resize",
    );
    window.set_child(Some(&overlay));

    let state = gio::SimpleAction::new_stateful("state", None, &"{}".to_variant());
    app.add_action(&state);

    let d: Shared = Rc::new(RefCell::new(Drawer {
        app: app.clone(),
        window: window.clone(),
        stack,
        config: config.clone(),
        tabs: Vec::new(),
        current: None,
        muted: false,
        set: None,
        engaged: false,
        shown: false,
        show_requests: 0,
        hide_requests: 0,
        last_added: None,
        last_error: None,
        error_count: 0,
        power_proxies: Vec::new(),
        state,
        site_mb: HashMap::new(),
        web_pids: HashMap::new(),
        web_waiting: Vec::new(),
        mem_total_kb: mem_total_kb(),
    }));
    for s in config.services {
        add_page(&d, s);
    }

    // Esc hides the drawer (the extension animates it away). Any other key, or a click, means the
    // user is working in it: hovering away no longer closes it.
    let engage = {
        let dd = d.clone();
        move || {
            if !dd.borrow().engaged {
                dd.borrow_mut().engaged = true;
                publish(&dd);
            }
        }
    };
    // Keys without a bar: Ctrl+Tab / Ctrl+Shift+Tab / Ctrl+1..9 switch site like a browser's tabs,
    // Esc / Ctrl+W fold it up, Alt+Left/Right go back and forward, Ctrl+R or
    // F5 reload (Shift: without the cache).
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let e = engage.clone();
    let dd = d.clone();
    keys.connect_key_pressed(move |_, key, _, mods| {
        use gtk::gdk::{Key, ModifierType as M};
        let ctrl = mods.contains(M::CONTROL_MASK);
        let alt = mods.contains(M::ALT_MASK);
        let shift = mods.contains(M::SHIFT_MASK);
        let view = || current_view(&dd);
        let handled = match key {
            Key::Escape => {
                request_hide(&dd);
                true
            }
            Key::w | Key::W if ctrl => {
                request_hide(&dd);
                true
            }
            Key::Left if alt => view().map(|v| v.go_back()).is_some(),
            Key::Right if alt => view().map(|v| v.go_forward()).is_some(),
            Key::r | Key::R if ctrl => view()
                .map(|v| {
                    if shift {
                        v.reload_bypass_cache()
                    } else {
                        v.reload()
                    }
                })
                .is_some(),
            Key::Tab | Key::ISO_Left_Tab if ctrl => {
                let back = shift || key == Key::ISO_Left_Tab;
                switch_site(&dd, |bar, cur| step_in(bar, cur, if back { -1 } else { 1 }))
            }
            Key::_1
            | Key::_2
            | Key::_3
            | Key::_4
            | Key::_5
            | Key::_6
            | Key::_7
            | Key::_8
            | Key::_9
                if ctrl && !alt =>
            {
                let n = key.to_unicode().and_then(|c| c.to_digit(10)).unwrap_or(1) as usize;
                switch_site(&dd, |bar, _| bar.get(n - 1).cloned())
            }
            Key::v | Key::V if ctrl && !alt && paste_image(&dd) => true,
            Key::F5 => view()
                .map(|v| {
                    if shift {
                        v.reload_bypass_cache()
                    } else {
                        v.reload()
                    }
                })
                .is_some(),
            _ => false,
        };
        if handled {
            return glib::Propagation::Stop;
        }
        e();
        glib::Propagation::Proceed
    });
    window.add_controller(keys);
    // The mouse's back and forward buttons.
    let nav = gtk::GestureClick::new();
    nav.set_button(0);
    nav.set_propagation_phase(gtk::PropagationPhase::Capture);
    let dd = d.clone();
    nav.connect_pressed(move |g, _, _, _| match g.current_button() {
        8 => {
            if let Some(v) = current_view(&dd) {
                v.go_back();
            }
        }
        9 => {
            if let Some(v) = current_view(&dd) {
                v.go_forward();
            }
        }
        _ => {}
    });
    window.add_controller(nav);
    // Closing (from anywhere) only hides it: the drawer keeps running for its notifications.
    let dd = d.clone();
    window.connect_close_request(move |_| {
        request_hide(&dd);
        glib::Propagation::Stop
    });
    // And the app outlives its window.
    std::mem::forget(app.hold());
    let click = gtk::GestureClick::new();
    click.set_propagation_phase(gtk::PropagationPhase::Capture);
    click.set_button(0);
    click.connect_pressed(move |_, _, _, _| engage());
    window.add_controller(click);
    // Resized (by the extension or a grip): the state carries the window size. The surface's
    // layout signal follows every compositor resize (GtkWindow's default size doesn't on Wayland).
    let dd = d.clone();
    window.connect_realize(move |w| {
        if let Some(surface) = w.surface() {
            let dd = dd.clone();
            surface.connect_layout(move |_, _, _| publish(&dd));
        }
    });

    // Keep-alive services (messaging) load now, so they can notify before the drawer is opened.
    let keep: Vec<usize> = d
        .borrow()
        .tabs
        .iter()
        .enumerate()
        .filter(|(_, t)| t.service.keep_alive)
        .map(|(i, _)| i)
        .collect();
    for i in keep {
        load_tab(&d, i);
    }
    watch_power_profile(&d);
    // The rest start on their "Unloaded to save memory" page: a site loads when it's opened. The
    // drawer opens on a kept site if there is one (already loaded), else the first.
    let first = {
        let dr = d.borrow();
        dr.tabs
            .iter()
            .find(|t| t.service.keep_alive)
            .or(dr.tabs.first())
            .map(|t| t.service.id.clone())
    };
    if let Some(f) = first {
        d.borrow().stack.set_visible_child_name(&f);
        d.borrow_mut().current = Some(f);
    }
    add_site_actions(app, &d);
    publish(&d);
    d
}

/// The per-site actions the extension's top-bar icons use (see the header).
fn add_site_actions(app: &gtk::Application, d: &Shared) {
    let s = glib::VariantTy::STRING;
    let sb = glib::VariantTy::new("(sb)").unwrap();
    let suu = glib::VariantTy::new("(suu)").unwrap();
    let asas = glib::VariantTy::new("(asas)").unwrap();
    type Handler = Box<dyn Fn(&Shared, &glib::Variant)>;
    let add = |name: &str, ty: &glib::VariantTy, f: Handler| {
        let action = gio::SimpleAction::new(name, Some(ty));
        let dd = d.clone();
        action.connect_activate(move |_, p| {
            if let Some(p) = p {
                f(&dd, p);
            }
        });
        app.add_action(&action);
    };
    let idx = |d: &Shared, id: &str| d.borrow().tabs.iter().position(|t| t.service.id == id);
    add(
        "load",
        s,
        Box::new(move |d, p| {
            if let Some(i) = p.str().and_then(|id| idx(d, id)) {
                load_tab(d, i);
            }
        }),
    );
    add(
        "unload",
        s,
        Box::new(move |d, p| {
            if let Some(i) = p.str().and_then(|id| idx(d, id)) {
                unload_tab(d, i);
            }
        }),
    );
    add(
        "reload",
        s,
        Box::new(move |d, p| {
            let Some(i) = p.str().and_then(|id| idx(d, id)) else {
                return;
            };
            let view = d.borrow().tabs[i].view.clone();
            match view {
                Some(v) => v.reload(),
                None => load_tab(d, i),
            }
        }),
    );
    add(
        "back",
        s,
        Box::new(move |d, p| {
            let view = p
                .str()
                .and_then(|id| idx(d, id))
                .and_then(|i| d.borrow().tabs[i].view.clone());
            if let Some(v) = view {
                v.go_back();
            }
        }),
    );
    add(
        "remove",
        s,
        Box::new(|d, p| {
            if let Some(id) = p.str() {
                remove_site(d, id);
            }
        }),
    );
    add(
        "elsewhere",
        s,
        Box::new(|_, p| {
            if let Some(id) = p.str() {
                open_elsewhere(id);
            }
        }),
    );
    add(
        "add",
        s,
        Box::new(|d, p| {
            if let Some(input) = p.str() {
                add_site(d, input, false);
            }
        }),
    );
    add(
        "pin",
        sb,
        Box::new(|d, p| {
            if let Some((id, on)) = p.get::<(String, bool)>() {
                update_site(d, &id, |s| s.pinned = on);
            }
        }),
    );
    add(
        "keep",
        sb,
        Box::new(move |d, p| {
            if let Some((id, on)) = p.get::<(String, bool)>() {
                update_site(d, &id, |s| s.keep_alive = on);
                if let (true, Some(i)) = (on, idx(d, &id)) {
                    load_tab(d, i);
                }
            }
        }),
    );
    add(
        "mute-site",
        sb,
        Box::new(|d, p| {
            if let Some((id, on)) = p.get::<(String, bool)>() {
                update_site(d, &id, |s| s.muted = on);
            }
        }),
    );
    add(
        "set-size",
        suu,
        Box::new(|d, p| {
            if let Some((id, w, h)) = p.get::<(String, u32, u32)>() {
                if w <= 10000 && h <= 10000 {
                    update_site(d, &id, |s| {
                        s.width = w;
                        s.height = h;
                    });
                }
            }
        }),
    );
    add(
        "visible",
        glib::VariantTy::BOOLEAN,
        Box::new(|d, p| {
            let on = p.get::<bool>().unwrap_or(false);
            {
                let mut dr = d.borrow_mut();
                dr.shown = on;
                if !on {
                    dr.engaged = false; // hidden: the next hover-open starts fresh
                }
            }
            publish(d);
            measure_memory(d);
        }),
    );
    add(
        "use-set",
        asas,
        Box::new(|d, p| {
            if let Some((sites, keep)) = p.get::<(Vec<String>, Vec<String>)>() {
                use_set(d, sites, keep);
            }
        }),
    );
}

fn main() -> glib::ExitCode {
    let app = gtk::Application::builder()
        .application_id(APP_ID)
        .flags(gio::ApplicationFlags::HANDLES_COMMAND_LINE)
        .build();
    let state: Rc<RefCell<Option<Shared>>> = Rc::new(RefCell::new(None));

    // app.toggle, app.show(s), app.mute(b): used by the shell extension, focus mode and notifications.
    let s = state.clone();
    let toggle = gio::SimpleAction::new("toggle", None);
    toggle.connect_activate(move |_, _| {
        if let Some(d) = s.borrow().as_ref() {
            let w = d.borrow().window.clone();
            if w.is_active() {
                request_hide(d);
            } else {
                present(d);
            }
        }
    });
    app.add_action(&toggle);
    let s = state.clone();
    let show = gio::SimpleAction::new("show", Some(glib::VariantTy::STRING));
    show.connect_activate(move |_, p| {
        if let (Some(d), Some(id)) = (
            s.borrow().as_ref(),
            p.and_then(|v| v.str().map(String::from)),
        ) {
            select(d, &id);
            present(d);
        }
    });
    app.add_action(&show);
    let s = state.clone();
    let mute = gio::SimpleAction::new_stateful(
        "mute",
        Some(glib::VariantTy::BOOLEAN),
        &false.to_variant(),
    );
    mute.connect_activate(move |a, p| {
        let on = p.and_then(|v| v.get::<bool>()).unwrap_or(false);
        a.set_state(&on.to_variant());
        if let Some(d) = s.borrow().as_ref() {
            d.borrow_mut().muted = on;
        }
    });
    app.add_action(&mute);

    let s = state.clone();
    app.connect_command_line(move |app, cmd| {
        let args: Vec<String> = cmd
            .arguments()
            .iter()
            .skip(1)
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        // Listings need no drawer: answered before building one, so a drawer that wasn't running
        // isn't started (and kept alive by its window) just to print them.
        if args.iter().any(|a| a == "--recommended") {
            cmd.print_literal(&recommended::listing());
            return glib::ExitCode::SUCCESS;
        }
        if args.iter().any(|a| a == "--list") {
            let services = match s.borrow().as_ref() {
                Some(d) => d.borrow().config.services.clone(),
                None => load_config().0.services,
            };
            let text: String = services
                .iter()
                .map(|s| {
                    let pinned = if s.pinned { "pinned" } else { "" };
                    let kept = if s.keep_alive { "kept" } else { "" };
                    format!("{}\t{}\t{}\t{pinned}\t{kept}\n", s.id, s.name, s.url)
                })
                .collect();
            cmd.print_literal(&text);
            return glib::ExitCode::SUCCESS;
        }
        // --add URL / --remove ID (from the welcome wizard): change the list, leave the window be.
        let arg_after = |flag: &str| {
            args.iter()
                .position(|a| a == flag)
                .and_then(|i| args.get(i + 1))
        };
        if let Some(id) = arg_after("--elsewhere") {
            open_elsewhere(id); // needs no drawer either
            return glib::ExitCode::SUCCESS;
        }
        let fresh = s.borrow().is_none(); // no drawer was running: this one exists for this command
        if fresh {
            *s.borrow_mut() = Some(build(app));
        }
        let d = s.borrow().clone().unwrap();
        let edits = [
            "--add", "--remove", "--pin", "--unpin", "--keep", "--unkeep",
        ];
        if edits.iter().any(|f| arg_after(f).is_some()) {
            if let Some(url) = arg_after("--add") {
                add_site(&d, url, false);
            }
            if let Some(id) = arg_after("--remove") {
                remove_site(&d, id);
            }
            if let Some(id) = arg_after("--pin") {
                update_site(&d, id, |s| s.pinned = true);
            }
            if let Some(id) = arg_after("--unpin") {
                update_site(&d, id, |s| s.pinned = false);
            }
            // Keep loaded (Ostrich Settings' switch); the right-click menu's "keep" action does the same.
            if let Some(id) = arg_after("--keep") {
                update_site(&d, id, |s| s.keep_alive = true);
                let i = d.borrow().tabs.iter().position(|t| t.service.id == *id);
                if let (false, Some(i)) = (fresh, i) {
                    load_tab(&d, i);
                }
            }
            if let Some(id) = arg_after("--unkeep") {
                update_site(&d, id, |s| s.keep_alive = false);
            }
            if fresh {
                app.quit(); // the change is saved; nothing was running before
            }
            return glib::ExitCode::SUCCESS;
        }
        let hidden = args.iter().any(|a| a == "--hidden");
        if let Some(i) = args.iter().position(|a| a == "--show") {
            if let Some(id) = args.get(i + 1) {
                select(&d, id);
            }
        }
        let w = d.borrow().window.clone();
        if hidden {
            // Not mapped at all: a window mapped and minimized at login makes GNOME show
            // "Drawer is ready". The pages still run; the first toggle shows the window.
            if w.is_visible() {
                w.minimize();
            }
        } else {
            present(&d);
        }
        glib::ExitCode::SUCCESS
    });
    app.run()
}

#[cfg(test)]
mod tests {
    use super::{
        load_config_at, media_wanted, paste_script, popup_title, spelling_languages, step_in,
    };

    #[test]
    fn a_pasted_image_goes_to_the_page_as_a_file() {
        let js = paste_script("QUJD");
        assert!(js.contains("atob('QUJD')") && js.contains("new ClipboardEvent('paste'"));
        assert!(js.contains("image/png") && js.contains("dt.items.add"));
    }

    #[test]
    fn dictionaries_come_from_the_locale_list() {
        let l = spelling_languages(["en_US.UTF-8", "en_US", "en", "C"].into_iter());
        assert_eq!(l, ["en_US", "en"]);
        let l = spelling_languages(["de_DE.UTF-8@euro", "POSIX"].into_iter());
        assert_eq!(l, ["de_DE"]);
        assert!(spelling_languages(["C"].into_iter()).is_empty());
    }

    #[test]
    fn ctrl_tab_walks_the_bar_and_wraps() {
        let bar: Vec<String> = ["a", "b", "c"].map(String::from).to_vec();
        assert_eq!(step_in(&bar, Some("a"), 1).as_deref(), Some("b"));
        assert_eq!(step_in(&bar, Some("c"), 1).as_deref(), Some("a"));
        assert_eq!(step_in(&bar, Some("a"), -1).as_deref(), Some("c"));
        assert_eq!(step_in(&bar, None, 1).as_deref(), Some("a"));
        assert_eq!(step_in(&bar, Some("gone"), -1).as_deref(), Some("c"));
        assert_eq!(step_in(&[], Some("a"), 1), None);
    }

    #[test]
    fn a_broken_config_is_kept_aside() {
        let dir = std::env::temp_dir().join(format!("drawer-config-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("drawer.toml");
        let broken = |dir: &std::path::Path| -> Vec<String> {
            let mut v: Vec<String> = std::fs::read_dir(dir)
                .unwrap()
                .flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.starts_with("drawer.toml.broken"))
                .collect();
            v.sort();
            v
        };
        std::fs::write(&path, "[[service]]\nid = \"x\"\nurl = oops\n").unwrap();
        let (c, from_file) = load_config_at(&path);
        assert_eq!(c.services.len(), super::Config::default().services.len());
        assert!(
            !from_file,
            "defaults after a broken file must not delete site data"
        );
        assert!(!path.exists());
        let first = broken(&dir);
        assert_eq!(first.len(), 1);
        assert!(std::fs::read_to_string(dir.join(&first[0]))
            .unwrap()
            .contains("oops"));
        // An empty file (a save cut short) is broken too, not "no sites".
        std::fs::write(&path, "  \n").unwrap();
        let (_, from_file) = load_config_at(&path);
        assert!(!from_file);
        // Not UTF-8: also set aside, never overwritten.
        std::fs::write(&path, [0xff_u8, 0xfe, 0x00]).unwrap();
        let (_, from_file) = load_config_at(&path);
        assert!(!from_file);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn media_in_words() {
        assert_eq!(media_wanted(true, true), "your camera and microphone");
        assert_eq!(media_wanted(false, true), "your microphone");
        assert_eq!(media_wanted(false, false), "your screen");
    }

    #[test]
    fn popup_titles_name_the_host() {
        assert_eq!(popup_title(None), "Sign in");
        assert_eq!(
            popup_title(Some("https://accounts.google.com/x?y")),
            "Sign in · accounts.google.com"
        );
        assert_eq!(
            popup_title(Some("http://evil.example/login")),
            "Sign in · evil.example (not secure)"
        );
    }
}
