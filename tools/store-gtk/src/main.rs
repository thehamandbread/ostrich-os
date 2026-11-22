//! ostrich-store-gtk: Ostrich Store, the app store window (DESIGN.md: app store). It runs on
//! store-core, like the terminal store: the Flathub catalogue flatpak keeps on disk (search never
//! touches the network), installs, updates and removals through the `flatpak` command.
//!
//!   ostrich-store-gtk [SEARCH | GITHUB-LINK]
//!
//! Explore: the recommended apps by category, and search as you type. Paste a GitHub link to
//! install that project: from Flathub if it's there, else its latest release (exactly what the
//! terminal store does). Installed and Updates list what's on this computer. App pages show the
//! screenshots (downloaded when the page opens, then cached), size, licence and permissions.

use adw::prelude::*;
use gtk::{gio, glib};
use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::Child;
use std::rc::Rc;
use std::sync::mpsc;
use store_core::appstream::{self, App};
use store_core::flatpak::{self, Action, Installed};
use store_core::github::{self, Kind};
use store_core::search::Searcher;
use store_core::{cache, ghinstall, ostrich_update};

const APP_ID: &str = "ostrich_os.store";
const REMOTE: &str = "flathub";
const MAX_RESULTS: usize = 80;

/// A flatpak run in progress: its output lines and the action, for the progress bar.
struct Job {
    action: Action,
    id: String,
    child: Child,
    lines: mpsc::Receiver<String>,
}

struct Store {
    apps: Vec<App>,
    by_id: HashMap<String, usize>,
    catalogue: PathBuf,
    installed: RefCell<HashMap<String, Installed>>,
    updates: RefCell<Option<Vec<(String, String)>>>,
    searcher: RefCell<Searcher>,
    queue: RefCell<VecDeque<(Action, String)>>,
    job: RefCell<Option<Job>>,
    /// Called after every change (an install finished, the updates were checked): each redraws
    /// its part, and returns false once its widgets are gone.
    listeners: RefCell<Vec<Box<dyn Fn() -> bool>>>,
    toasts: adw::ToastOverlay,
    job_bar: gtk::Revealer,
    job_label: gtk::Label,
    job_progress: gtk::ProgressBar,
    nav: adw::NavigationView,
    window: RefCell<Option<adw::ApplicationWindow>>,
}

impl Store {
    fn app(&self, id: &str) -> Option<&App> {
        self.by_id.get(id).map(|&i| &self.apps[i])
    }

    fn is_installed(&self, id: &str) -> bool {
        self.installed.borrow().contains_key(id)
    }

    fn has_update(&self, id: &str) -> bool {
        self.updates
            .borrow()
            .as_ref()
            .is_some_and(|u| u.iter().any(|(i, _)| i == id))
    }

    fn busy_with(&self, id: &str) -> bool {
        self.job.borrow().as_ref().is_some_and(|j| j.id == id)
            || self.queue.borrow().iter().any(|(_, i)| i == id)
    }

    fn listen(&self, f: impl Fn() -> bool + 'static) {
        self.listeners.borrow_mut().push(Box::new(f));
    }

    fn changed(&self) {
        let fs = std::mem::take(&mut *self.listeners.borrow_mut());
        let kept: Vec<_> = fs.into_iter().filter(|f| f()).collect();
        self.listeners.borrow_mut().extend(kept);
    }

    fn reload_installed(&self) {
        match flatpak::installed() {
            Ok(list) => {
                *self.installed.borrow_mut() = list.into_iter().map(|i| (i.id.clone(), i)).collect()
            }
            Err(e) => self.toast(&format!("Couldn't list the installed apps: {e}")),
        }
    }

    /// A GitHub install has ended: hide its progress bar (unless a Flatpak job is running), say how it
    /// went, and refresh what's installed.
    fn finish_job(&self, result: Result<String, String>) {
        if self.job.borrow().is_none() {
            self.job_bar.set_reveal_child(false);
        }
        match result {
            Ok(summary) => self.toast(&summary),
            Err(e) => self.toast(&format!("That didn't work: {e}")),
        }
        self.reload_installed();
        self.changed();
    }

    fn toast(&self, text: &str) {
        let t = adw::Toast::new(text);
        t.set_timeout(5);
        self.toasts.add_toast(t);
    }

    /// A failure says what to try and stays until closed (a screen reader can still reach it); the
    /// raw output is behind Details.
    fn fail(&self, text: &str, details: &str) {
        let t = adw::Toast::new(text);
        t.set_timeout(0);
        let details = details.trim().to_string();
        if !details.is_empty() {
            t.set_button_label(Some("Details"));
            let window = self.window.borrow().clone();
            t.connect_button_clicked(move |_| {
                let d = adw::AlertDialog::new(Some("What went wrong"), Some(&details));
                d.add_response("close", "Close");
                d.present(window.as_ref());
            });
        }
        self.toasts.add_toast(t);
    }

    /// The icon of a catalogue app at `size` px (the catalogue's cached icon), or a generic one.
    fn icon(&self, app: Option<&App>, size: i32) -> gtk::Image {
        let file = app.and_then(|a| a.icon.as_ref()).and_then(|(name, s)| {
            // A bigger copy of the same icon, if the catalogue has one, for the app page.
            [128, *s]
                .into_iter()
                .filter(|px| size > 64 || *px == *s)
                .find_map(|px| store_core::icon_path(&self.catalogue, &(name.clone(), px)))
        });
        let image = match file {
            Some(f) => gtk::Image::from_file(f),
            None => gtk::Image::from_icon_name("application-x-executable"),
        };
        image.set_pixel_size(size);
        image
    }
}

// ---- jobs: one flatpak run at a time, the rest queued ------------------------------------------

fn enqueue(store: &Rc<Store>, action: Action, id: &str) {
    if store.busy_with(id) {
        return;
    }
    store.queue.borrow_mut().push_back((action, id.to_string()));
    if store.job.borrow().is_none() {
        start_next(store);
    }
    store.changed();
}

fn verb(action: Action) -> (&'static str, &'static str) {
    match action {
        Action::Install => ("Installing", "installed"),
        Action::Uninstall => ("Removing", "removed"),
        Action::Update => ("Updating", "updated"),
    }
}

fn name_of(store: &Store, id: &str) -> String {
    store
        .app(id)
        .map(|a| a.name.clone())
        .unwrap_or_else(|| id.to_string())
}

fn start_next(store: &Rc<Store>) {
    let Some((action, id)) = store.queue.borrow_mut().pop_front() else {
        store.job_bar.set_reveal_child(false);
        return;
    };
    let mut child = match flatpak::spawn(action, REMOTE, &id) {
        Ok(c) => c,
        Err(e) => {
            store.toast(&e);
            return start_next(store);
        }
    };
    let (tx, rx) = mpsc::channel();
    let pipes: Vec<Box<dyn std::io::Read + Send>> = [
        child
            .stdout
            .take()
            .map(|p| Box::new(p) as Box<dyn std::io::Read + Send>),
        child
            .stderr
            .take()
            .map(|p| Box::new(p) as Box<dyn std::io::Read + Send>),
    ]
    .into_iter()
    .flatten()
    .collect();
    for pipe in pipes {
        let tx = tx.clone();
        std::thread::spawn(move || {
            // flatpak redraws its progress with \r: split on it too, so each state arrives.
            let mut r = BufReader::new(pipe);
            let mut buf = Vec::new();
            while r
                .read_until(b'\r', &mut buf)
                .map(|n| n > 0)
                .unwrap_or(false)
            {
                for part in String::from_utf8_lossy(&buf).split(['\r', '\n']) {
                    let part = part.trim();
                    if !part.is_empty() && tx.send(part.to_string()).is_err() {
                        return;
                    }
                }
                buf.clear();
            }
        });
    }
    store
        .job_label
        .set_text(&format!("{} {}…", verb(action).0, name_of(store, &id)));
    store.job_progress.set_fraction(0.0);
    store.job_bar.set_reveal_child(true);
    *store.job.borrow_mut() = Some(Job {
        action,
        id,
        child,
        lines: rx,
    });
    let s = store.clone();
    glib::timeout_add_local(std::time::Duration::from_millis(150), move || {
        if poll_job(&s) {
            glib::ControlFlow::Continue
        } else {
            glib::ControlFlow::Break
        }
    });
}

/// Moves the progress bar; true while the job runs.
fn poll_job(store: &Rc<Store>) -> bool {
    let mut ended = None;
    if let Some(job) = store.job.borrow_mut().as_mut() {
        let mut last = None;
        while let Ok(line) = job.lines.try_recv() {
            if let Some(f) = flatpak::parse_progress(&line) {
                store.job_progress.set_fraction(f);
            }
            last = Some(line);
        }
        if let Some(line) = last {
            store.job_progress.set_tooltip_text(Some(&line));
        }
        if let Ok(Some(status)) = job.child.try_wait() {
            ended = Some((job.action, job.id.clone(), status.success()));
        }
    }
    let Some((action, id, ok)) = ended else {
        return true;
    };
    *store.job.borrow_mut() = None;
    let name = name_of(store, &id);
    if ok {
        store.toast(&format!("{name} {}", verb(action).1));
    } else {
        let last = store.job_progress.tooltip_text().unwrap_or_default();
        store.fail(
            &format!(
                "{name} couldn't be {}. Check the internet connection and try again.",
                verb(action).1
            ),
            &last,
        );
    }
    store.reload_installed();
    if ok && action != Action::Install {
        if let Some(u) = store.updates.borrow_mut().as_mut() {
            u.retain(|(i, _)| *i != id);
        }
    }
    start_next(store);
    store.changed();
    false
}

// ---- widgets ------------------------------------------------------------------------------------

fn heading(text: &str) -> gtk::Label {
    let l = gtk::Label::new(Some(text));
    l.add_css_class("title-3");
    l.set_xalign(0.0);
    l.set_margin_top(18);
    l
}

/// Install / Open / Update / Remove for one app, kept in step with the store.
fn action_buttons(store: &Rc<Store>, id: &str) -> gtk::Box {
    let b = gtk::Box::builder().spacing(8).build();
    let install = gtk::Button::with_label("Install");
    install.add_css_class("suggested-action");
    install.add_css_class("pill");
    let open = gtk::Button::with_label("Open");
    open.add_css_class("pill");
    let update = gtk::Button::with_label("Update");
    update.add_css_class("suggested-action");
    update.add_css_class("pill");
    let remove = gtk::Button::with_label("Remove");
    remove.add_css_class("destructive-action");
    remove.add_css_class("pill");
    let busy = gtk::Spinner::new();
    for w in [
        install.upcast_ref::<gtk::Widget>(),
        open.upcast_ref(),
        update.upcast_ref(),
        remove.upcast_ref(),
        busy.upcast_ref(),
    ] {
        b.append(w);
    }
    let (s, i) = (store.clone(), id.to_string());
    install.connect_clicked(move |_| enqueue(&s, Action::Install, &i));
    let (s, i) = (store.clone(), id.to_string());
    update.connect_clicked(move |_| enqueue(&s, Action::Update, &i));
    let i = id.to_string();
    open.connect_clicked(move |_| {
        let _ = gio::Subprocess::newv(
            &[
                std::ffi::OsStr::new("flatpak"),
                std::ffi::OsStr::new("run"),
                std::ffi::OsStr::new(&i),
            ],
            gio::SubprocessFlags::NONE,
        );
    });
    let (s, i) = (store.clone(), id.to_string());
    remove.connect_clicked(move |button| confirm_remove(&s, &i, button));

    let sync = {
        let (s, i) = (store.clone(), id.to_string());
        let weak = b.downgrade();
        move || {
            if weak.upgrade().is_none() {
                return false;
            }
            let (inst, upd, working) = (s.is_installed(&i), s.has_update(&i), s.busy_with(&i));
            install.set_visible(!inst && !working);
            open.set_visible(inst && !working);
            update.set_visible(inst && upd && !working);
            remove.set_visible(inst && !working);
            busy.set_visible(working);
            busy.set_spinning(working);
            true
        }
    };
    sync();
    store.listen(sync);
    b
}

fn confirm_remove(store: &Rc<Store>, id: &str, near: &impl IsA<gtk::Widget>) {
    let name = name_of(store, id);
    let d = adw::AlertDialog::new(
        Some(&format!("Remove {name}?")),
        Some("Its settings and data in your home folder stay, so a reinstall picks up where you left off."),
    );
    d.add_response("cancel", "Cancel");
    d.add_response("remove", "Remove");
    d.set_response_appearance("remove", adw::ResponseAppearance::Destructive);
    d.set_close_response("cancel");
    let (s, i) = (store.clone(), id.to_string());
    d.connect_response(None, move |_, r| {
        if r == "remove" {
            enqueue(&s, Action::Uninstall, &i);
        }
    });
    d.present(Some(near));
}

/// A row showing `title` and `subtitle` as plain text. They're set after use_markup is off: given to
/// the builder, they were parsed as markup first, and a bare "&" blanked them ("Play, chat & explore").
fn plain_row(title: &str, subtitle: &str) -> adw::ActionRow {
    let row = adw::ActionRow::builder().use_markup(false).build();
    row.set_title(title);
    row.set_subtitle(subtitle);
    row
}

/// A list row for an app: icon, name, summary, and its state on the right.
fn app_row(store: &Rc<Store>, id: &str) -> adw::ActionRow {
    let app = store.app(id);
    let row = plain_row(
        app.map(|a| a.name.as_str()).unwrap_or(id),
        app.map(|a| a.summary.as_str()).unwrap_or(""),
    );
    row.set_activatable(app.is_some());
    row.add_prefix(&store.icon(app, 48));
    let state = gtk::Label::new(None);
    state.add_css_class("dimmed");
    row.add_suffix(&state);
    if app.is_some() {
        row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
    }
    let sync = {
        let (s, i) = (store.clone(), id.to_string());
        let weak = state.downgrade();
        move || {
            let Some(state) = weak.upgrade() else {
                return false;
            };
            state.set_text(if s.busy_with(&i) {
                "Working…"
            } else if s.has_update(&i) {
                "Update"
            } else if s.is_installed(&i) {
                "Installed"
            } else {
                ""
            });
            true
        }
    };
    sync();
    store.listen(sync);
    let (s, i) = (store.clone(), id.to_string());
    row.connect_activated(move |_| show_app(&s, &i));
    row
}

/// A tile on the Explore page: big icon, name, one line about it.
fn app_tile(store: &Rc<Store>, id: &str, name: &str, about: &str) -> gtk::Button {
    let app = store.app(id);
    let b = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(6)
        .margin_top(12)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .build();
    b.append(&store.icon(app, 64));
    let title = gtk::Label::new(Some(app.map(|a| a.name.as_str()).unwrap_or(name)));
    title.add_css_class("heading");
    title.set_ellipsize(gtk::pango::EllipsizeMode::End);
    b.append(&title);
    let sub = gtk::Label::new(Some(if about.is_empty() {
        app.map(|a| a.summary.as_str()).unwrap_or("")
    } else {
        about
    }));
    sub.add_css_class("dimmed");
    sub.add_css_class("caption");
    sub.set_wrap(true);
    sub.set_lines(2);
    sub.set_ellipsize(gtk::pango::EllipsizeMode::End);
    sub.set_justify(gtk::Justification::Center);
    sub.set_max_width_chars(28);
    b.append(&sub);
    // One width for every tile, so each category's row lines up with the others.
    let button = gtk::Button::builder()
        .child(&b)
        .css_classes(["card"])
        .width_request(260)
        .build();
    let (s, i) = (store.clone(), id.to_string());
    button.connect_clicked(move |_| show_app(&s, &i));
    button.set_sensitive(app.is_some());
    button
}

// ---- the app page ---------------------------------------------------------------------------------

fn show_app(store: &Rc<Store>, id: &str) {
    let Some(app) = store.app(id).cloned() else {
        return;
    };
    let body = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .margin_top(24)
        .margin_bottom(24)
        .margin_start(18)
        .margin_end(18)
        .build();

    // Icon, name, developer, summary, buttons.
    let top = gtk::Box::builder().spacing(18).build();
    top.append(&store.icon(Some(&app), 128));
    let words = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(4)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .build();
    let name = gtk::Label::new(Some(&app.name));
    name.add_css_class("title-1");
    name.set_xalign(0.0);
    name.set_wrap(true);
    words.append(&name);
    if !app.developer.is_empty() {
        let dev = gtk::Label::new(Some(&app.developer));
        dev.add_css_class("dimmed");
        dev.set_xalign(0.0);
        words.append(&dev);
    }
    let summary = gtk::Label::new(Some(&app.summary));
    summary.set_xalign(0.0);
    summary.set_wrap(true);
    words.append(&summary);
    let buttons = action_buttons(store, &app.id);
    buttons.set_margin_top(8);
    words.append(&buttons);
    top.append(&words);
    body.append(&top);

    // Screenshots, fetched now (cached after the first time).
    if !app.screenshots.is_empty() {
        let carousel = adw::Carousel::builder()
            .spacing(12)
            .height_request(380)
            .build();
        let dots = adw::CarouselIndicatorDots::builder()
            .carousel(&carousel)
            .build();
        let frame = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(6)
            .build();
        frame.append(&carousel);
        frame.append(&dots);
        body.append(&frame);
        let dir = glib::user_cache_dir().join("ostrich-os").join("store");
        for url in app.screenshots.clone() {
            let slot = gtk::Picture::builder()
                .content_fit(gtk::ContentFit::Contain)
                .can_shrink(true)
                .hexpand(true)
                .build();
            let spinner = gtk::Spinner::builder()
                .spinning(true)
                .halign(gtk::Align::Center)
                .valign(gtk::Align::Center)
                .build();
            let stack = gtk::Stack::new();
            stack.add_named(&spinner, Some("wait"));
            stack.add_named(&slot, Some("shot"));
            carousel.append(&stack);
            let dir = dir.clone();
            glib::spawn_future_local(async move {
                let got = gio::spawn_blocking(move || cache::fetch(&dir, &url)).await;
                match got {
                    Ok(Ok(path)) => {
                        slot.set_filename(Some(&path));
                        stack.set_visible_child_name("shot");
                    }
                    _ => spinner.set_spinning(false),
                }
            });
        }
    }

    // Description.
    if !app.description.is_empty() {
        let d = gtk::Label::new(Some(&app.description));
        d.set_wrap(true);
        d.set_xalign(0.0);
        d.set_selectable(true);
        body.append(&d);
    }

    // Details, and what it can reach on this computer (asked of Flathub when the page opens).
    let details = adw::PreferencesGroup::builder().title("Details").build();
    let info_row = |title: &str, value: &str| {
        let r = plain_row(title, value);
        r.add_css_class("property");
        r
    };
    let version = info_row("Version", "Checking…");
    let size = info_row("Download size", "Checking…");
    let disk = info_row("Size on disk", "Checking…");
    details.add(&version);
    details.add(&size);
    details.add(&disk);
    if !app.license.is_empty() {
        details.add(&info_row("Licence", &app.license));
    }
    for (title, url) in [
        ("Website", app.homepage.clone()),
        ("Source code", app.vcs_browser.clone()),
    ] {
        if let Some(url) = url {
            let r = info_row(title, &url);
            r.set_activatable(true);
            r.add_suffix(&gtk::Image::from_icon_name("adw-external-link-symbolic"));
            r.connect_activated(move |row| {
                let window = row.root().and_downcast::<gtk::Window>();
                gtk::UriLauncher::new(&url).launch(
                    window.as_ref(),
                    None::<&gio::Cancellable>,
                    |_| {},
                );
            });
            details.add(&r);
        }
    }
    body.append(&details);
    let perms = adw::PreferencesGroup::builder()
        .title("Permissions")
        .description("What it can reach outside its sandbox")
        .build();
    let checking = info_row("Checking…", "");
    perms.add(&checking);
    body.append(&perms);
    let id = app.id.clone();
    glib::spawn_future_local(async move {
        let got = gio::spawn_blocking(move || flatpak::remote_info(REMOTE, &id)).await;
        perms.remove(&checking);
        match got {
            Ok(Ok(info)) => {
                version.set_subtitle(&info.version);
                size.set_subtitle(&info.download);
                disk.set_subtitle(&info.installed);
                if info.permissions.is_empty() {
                    perms.add(&info_row(
                        "No special permissions",
                        "It stays inside its sandbox",
                    ));
                }
                for p in info.permissions {
                    perms.add(&info_row(&p, ""));
                }
            }
            _ => {
                for r in [&version, &size, &disk] {
                    r.set_subtitle("Not known (no connection?)");
                }
                perms.add(&info_row("Couldn't check (no connection?)", ""));
            }
        }
    });

    let clamp = adw::Clamp::builder().maximum_size(860).child(&body).build();
    let scroll = gtk::ScrolledWindow::builder()
        .child(&clamp)
        .vexpand(true)
        .build();
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&scroll));
    store
        .nav
        .push(&adw::NavigationPage::new(&toolbar, &app.name));
}

// ---- GitHub links ---------------------------------------------------------------------------------

fn is_github_link(q: &str) -> bool {
    q.contains("github.com/") || q.trim_start().starts_with("git@github.com:")
}

/// Looks the project up (off the UI thread), then says exactly what would happen and asks.
fn github_install(store: &Rc<Store>, link: &str) {
    let Some(repo) = github::parse_repo(link) else {
        store.toast("That isn't a link to a GitHub project");
        return;
    };
    if let Some(app) = github::flathub_match(&store.apps, &repo) {
        let id = app.id.clone();
        store.toast(&format!("{} is on Flathub: here it is", app.name));
        show_app(store, &id);
        return;
    }
    store.toast(&format!("Looking up github.com/{}…", repo.slug()));
    let s = store.clone();
    glib::spawn_future_local(async move {
        let r = repo.clone();
        let got = gio::spawn_blocking(move || github::latest_release(&r)).await;
        let release = match got {
            Ok(Ok(Some(rel))) => rel,
            Ok(Ok(None)) => {
                return s.toast(&format!(
                    "github.com/{} has no releases to install",
                    repo.slug()
                ))
            }
            Ok(Err(e)) => return s.toast(&format!("GitHub: {e}")),
            Err(_) => return,
        };
        let had = ghinstall::Dirs::from_env().and_then(|d| ghinstall::installed_tag(&d, &repo));
        let repair =
            ghinstall::Dirs::from_env().is_some_and(|d| ghinstall::needs_repair(&d, &repo));
        if had.as_deref() == Some(release.tag.as_str()) && !repair {
            return s.toast(&format!("{} is up to date ({})", repo.slug(), release.tag));
        }
        let Some((kind, asset)) =
            github::choose_asset(&release.assets).map(|(k, a)| (k, a.clone()))
        else {
            return s.toast(&format!("Release {} has no Linux app in it", release.tag));
        };
        let how = match kind {
            Kind::Flatpak => "a Flatpak bundle, installed for you only",
            Kind::AppImage => "an AppImage, kept in your home folder with a launcher",
            Kind::Deb => "a Debian package. Its install scripts run as root",
            Kind::Tarball => "a tarball, unpacked into your home folder with a launcher",
        };
        let d = adw::AlertDialog::new(
            Some(&match &had {
                Some(t) if *t == release.tag => format!("Install {} again?", repo.slug()),
                Some(t) => format!("Update {} from {t}?", repo.slug()),
                None => format!("Install {}?", repo.slug()),
            }),
            Some(&format!(
                "{} {}: {} ({:.1} MB), {how}.\n\nThis isn't reviewed by Flathub or Ubuntu: only install projects you trust. The download is checked against the release's checksum when one is published.",
                repo.slug(),
                release.tag,
                asset.name,
                asset.size as f64 / 1e6
            )),
        );
        d.add_response("cancel", "Cancel");
        d.add_response("install", "Install");
        d.set_response_appearance(
            "install",
            if kind == Kind::Deb {
                adw::ResponseAppearance::Destructive
            } else {
                adw::ResponseAppearance::Suggested
            },
        );
        d.set_close_response("cancel");
        let s2 = s.clone();
        d.connect_response(None, move |_, r| {
            if r != "install" {
                return;
            }
            let (repo, release, kind, asset) =
                (repo.clone(), release.clone(), kind.clone(), asset.clone());
            let repo_slug = repo.slug();
            s2.job_label
                .set_text(&format!("Installing {}…", repo.slug()));
            s2.job_progress.pulse();
            s2.job_bar.set_reveal_child(true);
            let s3 = s2.clone();
            glib::spawn_future_local(async move {
                let dl = {
                    let (release, asset) = (release.clone(), asset.clone());
                    gio::spawn_blocking(move || -> Result<(PathBuf, bool, Vec<String>), String> {
                        let dirs = ghinstall::Dirs::from_env().ok_or("HOME is not set")?;
                        std::fs::create_dir_all(dirs.downloads()).map_err(|e| e.to_string())?;
                        let dest = dirs.downloads().join(&asset.name);
                        let verified = github::download_verified(&release, &asset, &dest)?;
                        let scripts = ghinstall::deb_scripts(&dest);
                        Ok((dest, verified, scripts))
                    })
                    .await
                };
                let (dest, verified, scripts) = match dl {
                    Ok(Ok(got)) => got,
                    Ok(Err(e)) => return s3.finish_job(Err(e)),
                    Err(_) => return s3.finish_job(Err("the download stopped".into())),
                };
                // A package that runs as root and couldn't be checked: ask once more, Cancel first.
                if kind == Kind::Deb && !verified {
                    let what = if scripts.is_empty() {
                        "It has no install scripts, but it still installs as root.".to_string()
                    } else {
                        format!("It runs install scripts as root ({}).", scripts.join(", "))
                    };
                    let d = adw::AlertDialog::new(
                        Some("Install it without a check?"),
                        Some(&format!(
                            "{} published no checksum for {}, so there's no way to tell it's the file its authors built. {what} This can change your whole computer.",
                            repo.slug(),
                            asset.name
                        )),
                    );
                    d.add_response("cancel", "Cancel");
                    d.add_response("install", "Install anyway");
                    d.set_response_appearance("install", adw::ResponseAppearance::Destructive);
                    d.set_default_response(Some("cancel"));
                    d.set_close_response("cancel");
                    let window = s3.window.borrow().clone();
                    if d.choose_future(window.as_ref()).await != "install" {
                        let _ = std::fs::remove_file(&dest);
                        return s3.finish_job(Err("cancelled; nothing was installed".into()));
                    }
                }
                let got = gio::spawn_blocking(move || -> Result<String, String> {
                    let dirs = ghinstall::Dirs::from_env().ok_or("HOME is not set")?;
                    let done =
                        ghinstall::install(&dirs, &repo, &release.tag, &kind, &asset.name, &dest);
                    let _ = std::fs::remove_file(&dest);
                    let summary = done?.summary;
                    Ok(if verified {
                        summary
                    } else {
                        format!("{summary} (no checksum was published, so it wasn't verified)")
                    })
                })
                .await;
                let got = got.unwrap_or_else(|_| Err("the install stopped".into()));
                if got.is_ok() {
                    let id = format!("{}{}", ghinstall::UPDATE_PREFIX, repo_slug);
                    if let Some(u) = s3.updates.borrow_mut().as_mut() {
                        u.retain(|(i, _)| *i != id);
                    }
                }
                s3.finish_job(got);
            });
        });
        let window = s.window.borrow().clone();
        d.present(window.as_ref());
    });
}

/// Asks, then removes an app installed from GitHub (off the UI thread: a .deb asks for a password).
fn github_remove(store: &Rc<Store>, slug: &str, near: &impl IsA<gtk::Widget>) {
    let Some(repo) = github::parse_repo(slug) else {
        return;
    };
    let d = adw::AlertDialog::new(
        Some(&format!("Remove {slug}?")),
        Some("Its settings and data in your home folder stay."),
    );
    d.add_response("cancel", "Cancel");
    d.add_response("remove", "Remove");
    d.set_response_appearance("remove", adw::ResponseAppearance::Destructive);
    d.set_close_response("cancel");
    let s = store.clone();
    d.connect_response(None, move |_, r| {
        if r != "remove" {
            return;
        }
        s.job_label.set_text(&format!("Removing {}…", repo.slug()));
        s.job_progress.pulse();
        s.job_bar.set_reveal_child(true);
        let (s2, repo) = (s.clone(), repo.clone());
        glib::spawn_future_local(async move {
            let got = gio::spawn_blocking(move || {
                let dirs = ghinstall::Dirs::from_env().ok_or("HOME is not set")?;
                ghinstall::remove(&dirs, &repo)
            })
            .await;
            s2.finish_job(got.unwrap_or_else(|_| Err("the removal stopped".into())));
        });
    });
    d.present(Some(near));
}

// ---- pages ----------------------------------------------------------------------------------------

fn page_box() -> gtk::Box {
    gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .margin_top(18)
        .margin_bottom(24)
        .margin_start(18)
        .margin_end(18)
        .build()
}

fn scrolled(child: &impl IsA<gtk::Widget>) -> gtk::ScrolledWindow {
    let clamp = adw::Clamp::builder()
        .maximum_size(1000)
        .child(child)
        .build();
    gtk::ScrolledWindow::builder()
        .child(&clamp)
        .vexpand(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .build()
}

fn explore_page(store: &Rc<Store>, search: &gtk::SearchEntry) -> gtk::ScrolledWindow {
    let b = page_box();
    let home = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(6)
        .build();
    for c in welcome::recommended() {
        home.append(&heading(&c.name));
        let flow = gtk::FlowBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .homogeneous(true)
            .min_children_per_line(2)
            .max_children_per_line(4)
            .row_spacing(12)
            .column_spacing(12)
            .build();
        for a in &c.apps {
            let tile = app_tile(store, &a.id, &a.name, &a.about);
            if a.snap {
                // Not on Flathub: its page in App Center, which installs and opens it.
                tile.set_sensitive(true);
                tile.set_tooltip_text(Some("Opens in App Center"));
                let page = a.page();
                tile.connect_clicked(move |_| {
                    let _ =
                        gio::AppInfo::launch_default_for_uri(&page, None::<&gio::AppLaunchContext>);
                });
            }
            flow.append(&tile);
        }
        home.append(&flow);
    }
    let gh_hint = gtk::Label::new(Some(
        "Tip: paste a GitHub project's link into the search to install it from there.",
    ));
    gh_hint.add_css_class("dimmed");
    gh_hint.set_margin_top(18);
    home.append(&gh_hint);

    let results = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .css_classes(["boxed-list"])
        .build();
    let empty = adw::StatusPage::builder()
        .icon_name("system-search-symbolic")
        .title("Nothing found")
        .description("Try another word, or paste a GitHub link")
        .build();
    let github_row = adw::ButtonRow::builder()
        .title("Install from this GitHub link")
        .start_icon_name("folder-download-symbolic")
        .build();
    let github_list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .css_classes(["boxed-list"])
        .build();
    github_list.append(&github_row);
    b.append(&home);
    b.append(&github_list);
    b.append(&results);
    b.append(&empty);

    let update = {
        let (s, home, results, empty, github_list) = (
            store.clone(),
            home.clone(),
            results.clone(),
            empty.clone(),
            github_list.clone(),
        );
        move |q: &str| {
            let q = q.trim();
            let gh = is_github_link(q);
            home.set_visible(q.is_empty());
            github_list.set_visible(gh);
            results.remove_all();
            if q.is_empty() || gh {
                results.set_visible(false);
                empty.set_visible(false);
                return;
            }
            let found = s.searcher.borrow_mut().search(&s.apps, q, MAX_RESULTS);
            results.set_visible(!found.is_empty());
            empty.set_visible(found.is_empty());
            for i in found {
                results.append(&app_row(&s, &s.apps[i].id));
            }
        }
    };
    update(&search.text());
    let u = update.clone();
    search.connect_search_changed(move |e| u(&e.text()));
    let (s, e) = (store.clone(), search.clone());
    github_row.connect_activated(move |_| github_install(&s, &e.text()));
    let s = store.clone();
    search.connect_activate(move |e| {
        if is_github_link(&e.text()) {
            github_install(&s, &e.text());
        }
    });
    scrolled(&b)
}

fn installed_page(store: &Rc<Store>) -> gtk::ScrolledWindow {
    let b = page_box();
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .css_classes(["boxed-list"])
        .build();
    let others = adw::PreferencesGroup::builder()
        .title("From GitHub")
        .description("Installed from release downloads: Update looks for a newer release")
        .build();
    let gh_list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .css_classes(["boxed-list"])
        .build();
    others.add(&gh_list);
    b.append(&list);
    b.append(&others);
    let fill = {
        let (s, weak, others) = (store.clone(), list.downgrade(), others.clone());
        let shown = RefCell::new(String::new());
        let gh_shown = RefCell::new(String::new());
        move || {
            let Some(list) = weak.upgrade() else {
                return false;
            };
            let mut ids: Vec<String> = s.installed.borrow().keys().cloned().collect();
            ids.sort_by_key(|i| name_of(&s, i).to_lowercase());
            let key = ids.join("\n");
            if *shown.borrow() != key {
                *shown.borrow_mut() = key;
                list.remove_all();
                for id in &ids {
                    let row = app_row(&s, id);
                    let remove = gtk::Button::from_icon_name("user-trash-symbolic");
                    remove.set_valign(gtk::Align::Center);
                    remove.add_css_class("flat");
                    remove.set_tooltip_text(Some("Remove"));
                    let (s2, i) = (s.clone(), id.clone());
                    remove.connect_clicked(move |b| confirm_remove(&s2, &i, b));
                    row.add_suffix(&remove);
                    list.append(&row);
                }
                if ids.is_empty() {
                    list.append(&plain_row("No Flatpak apps yet", ""));
                }
            }
            // GitHub installs, from the store's own record of them.
            let manifest = ghinstall::Dirs::from_env().map(|d| ghinstall::read_manifest(&d));
            let gh: Vec<(String, String)> = manifest
                .as_ref()
                .and_then(|m| m.as_object())
                .map(|o| {
                    o.iter()
                        .map(|(k, v)| (k.clone(), v["tag"].as_str().unwrap_or("").to_string()))
                        .collect()
                })
                .unwrap_or_default();
            others.set_visible(!gh.is_empty());
            let key = gh
                .iter()
                .map(|(s, t)| format!("{s}@{t}"))
                .collect::<Vec<_>>()
                .join("\n");
            if *gh_shown.borrow() != key {
                *gh_shown.borrow_mut() = key;
                gh_list.remove_all();
                for (slug, tag) in gh {
                    let row = plain_row(&slug, &tag);
                    let update = gtk::Button::with_label("Update");
                    update.set_valign(gtk::Align::Center);
                    let (s2, link) = (s.clone(), format!("https://github.com/{slug}"));
                    update.connect_clicked(move |_| github_install(&s2, &link));
                    let remove = gtk::Button::from_icon_name("user-trash-symbolic");
                    remove.set_valign(gtk::Align::Center);
                    remove.add_css_class("flat");
                    remove.set_tooltip_text(Some("Remove"));
                    let (s2, sl) = (s.clone(), slug.clone());
                    remove.connect_clicked(move |b| github_remove(&s2, &sl, b));
                    row.add_suffix(&update);
                    row.add_suffix(&remove);
                    gh_list.append(&row);
                }
            }
            true
        }
    };
    fill();
    store.listen(fill);
    scrolled(&b)
}

fn updates_page(store: &Rc<Store>) -> gtk::ScrolledWindow {
    let b = page_box();
    let status = adw::StatusPage::builder()
        .icon_name("emblem-ok-symbolic")
        .title("Checking for updates…")
        .build();
    let group = adw::PreferencesGroup::new();
    let all = gtk::Button::with_label("Update all");
    all.add_css_class("suggested-action");
    all.set_valign(gtk::Align::Center);
    group.set_header_suffix(Some(&all));
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .css_classes(["boxed-list"])
        .build();
    group.add(&list);
    let check = gtk::Button::with_label("Check again");
    check.set_halign(gtk::Align::Center);
    check.add_css_class("pill");
    b.append(&status);
    b.append(&group);
    b.append(&check);
    // Snaps and Ubuntu's own packages aren't ours to update.
    let elsewhere = gtk::Label::builder()
        .label("Snap apps update themselves (App Center shows them), and Ubuntu's own software updates in Software Updater.")
        .wrap(true)
        .justify(gtk::Justification::Center)
        .build();
    b.append(&elsewhere);
    let s = store.clone();
    all.connect_clicked(move |_| {
        let ids: Vec<String> = s
            .updates
            .borrow()
            .iter()
            .flatten()
            .map(|(i, _)| i.clone())
            .collect();
        for id in ids {
            // Ostrich OS itself opens a terminal and asks for the password: its own button.
            if id == ostrich_update::UPDATE_ID {
                continue;
            }
            match id.strip_prefix(ghinstall::UPDATE_PREFIX) {
                // Each asks first, as an install from GitHub always does.
                Some(slug) => github_install(&s, &format!("https://github.com/{slug}")),
                None => enqueue(&s, Action::Update, &id),
            }
        }
    });
    let fill = {
        let (s, weak, status, group) = (
            store.clone(),
            list.downgrade(),
            status.clone(),
            group.clone(),
        );
        let shown = RefCell::new(None::<String>);
        move || {
            let Some(list) = weak.upgrade() else {
                return false;
            };
            let u = s.updates.borrow().clone();
            let key = u.as_ref().map(|u| {
                u.iter()
                    .map(|(i, v)| format!("{i}={v}"))
                    .collect::<Vec<_>>()
                    .join("\n")
            });
            if *shown.borrow() == key && key.is_some() {
                return true;
            }
            *shown.borrow_mut() = key;
            list.remove_all();
            match u {
                None => {
                    status.set_title("Checking for updates…");
                    status.set_visible(true);
                    group.set_visible(false);
                }
                Some(u) if u.is_empty() => {
                    status.set_title("Everything is up to date");
                    status.set_visible(true);
                    group.set_visible(false);
                }
                Some(u) => {
                    status.set_visible(false);
                    group.set_visible(true);
                    group.set_title(&match u.len() {
                        1 => "1 update".to_string(),
                        n => format!("{n} updates"),
                    });
                    for (id, version) in u {
                        if id == ostrich_update::UPDATE_ID {
                            let row = plain_row(
                                "Ostrich OS",
                                &format!("New release {version}. Updating opens a terminal and asks for your password."),
                            );
                            let update = gtk::Button::with_label("Update");
                            update.set_valign(gtk::Align::Center);
                            update.add_css_class("suggested-action");
                            let (s2, tag) = (s.clone(), version.clone());
                            update.connect_clicked(move |_| run_ostrich_update(&s2, &tag));
                            row.add_suffix(&update);
                            list.append(&row);
                            continue;
                        }
                        if let Some(slug) = id.strip_prefix(ghinstall::UPDATE_PREFIX) {
                            let repair = github::parse_repo(slug)
                                .zip(ghinstall::Dirs::from_env())
                                .is_some_and(|(r, d)| ghinstall::needs_repair(&d, &r));
                            let what = if repair {
                                "Needs installing again to start".to_string()
                            } else {
                                format!("New release {version}, from GitHub")
                            };
                            let row = plain_row(slug, &what);
                            let update = gtk::Button::with_label("Update");
                            update.set_valign(gtk::Align::Center);
                            let (s2, link) = (s.clone(), format!("https://github.com/{slug}"));
                            update.connect_clicked(move |_| github_install(&s2, &link));
                            row.add_suffix(&update);
                            list.append(&row);
                            continue;
                        }
                        let row = app_row(&s, &id);
                        if !version.is_empty() {
                            row.set_subtitle(&format!("New version {version}"));
                        }
                        list.append(&row);
                    }
                }
            }
            true
        }
    };
    fill();
    store.listen(fill);
    let s = store.clone();
    check.connect_clicked(move |_| check_updates(&s));
    scrolled(&b)
}

/// Flatpak updates, then apps from GitHub with a newer release (ids `github:owner/name`), and
/// Flatpak's error if it had one: GitHub's are still listed when Flatpak can't be asked.
fn all_updates() -> (Vec<(String, String)>, Option<String>) {
    let (mut u, err) = match flatpak::updates() {
        Ok(u) => (u, None),
        Err(e) => (Vec::new(), Some(e)),
    };
    if let Some(d) = ghinstall::Dirs::from_env() {
        u.extend(ghinstall::updates(&d));
    }
    // Ostrich OS itself: a newer release than the one these tools came with.
    if let Some(tag) = ostrich_update::available(env!("CARGO_PKG_VERSION")) {
        u.push((ostrich_update::UPDATE_ID.to_string(), tag));
    }
    (u, err)
}

/// Runs `ostrich update` pinned to `tag` in a terminal (it needs the password and says what it does).
fn run_ostrich_update(store: &Rc<Store>, tag: &str) {
    let Some(script) = ostrich_update::update_script(tag) else {
        return;
    };
    let argv = ostrich_update::terminal_command(
        |program| glib::find_program_in_path(program).is_some(),
        &script,
    );
    let started = argv.is_some_and(|a| {
        std::process::Command::new(&a[0])
            .args(&a[1..])
            .spawn()
            .is_ok()
    });
    if !started {
        store.toast(&format!(
            "Couldn't open a terminal. Run this in one: REPO_REF={tag} ostrich update"
        ));
    }
}

/// `--check-updates` (the daily ostrich-store-updates timer): no window; a notification when
/// something can be updated, and its button opens the Updates tab.
fn notify_updates() -> glib::ExitCode {
    let (u, _) = all_updates();
    if u.is_empty() {
        return glib::ExitCode::SUCCESS;
    }
    let names: Vec<&str> = u
        .iter()
        .map(|(id, _)| {
            if id == ostrich_update::UPDATE_ID {
                return "Ostrich OS";
            }
            let id = id.strip_prefix(ghinstall::UPDATE_PREFIX).unwrap_or(id);
            id.rsplit(['/', '.']).next().unwrap_or(id)
        })
        .take(3)
        .collect();
    let more = if u.len() > 3 { ", …" } else { "" };
    let title = if u.len() == 1 {
        "1 app can be updated".to_string()
    } else {
        format!("{} apps can be updated", u.len())
    };
    if notify_and_wait(&title, &format!("{}{more}", names.join(", "))) {
        if let Ok(me) = std::env::current_exe() {
            let _ = std::process::Command::new(me).arg("--updates").spawn();
        }
    }
    glib::ExitCode::SUCCESS
}

/// Shows a notification and waits until it's answered: true when it was clicked. Straight over
/// D-Bus: notify-send 0.8.8 says GNOME Shell 50 doesn't do actions, and it does (2026-11-18).
fn notify_and_wait(title: &str, body: &str) -> bool {
    const NAME: &str = "org.freedesktop.Notifications";
    const PATH: &str = "/org/freedesktop/Notifications";
    let Ok(bus) = gio::bus_get_sync(gio::BusType::Session, gio::Cancellable::NONE) else {
        return false;
    };
    let main = glib::MainLoop::new(None, false);
    let id = Rc::new(std::cell::Cell::new(0u32));
    let clicked = Rc::new(std::cell::Cell::new(false));
    // Subscribed first; the shell sends these to this connection only.
    let _sub = {
        let (main, id, clicked) = (main.clone(), id.clone(), clicked.clone());
        bus.subscribe_to_signal(
            Some(NAME),
            Some(NAME),
            None,
            Some(PATH),
            None,
            gio::DBusSignalFlags::NONE,
            move |sig| {
                let ours = sig.parameters.child_value(0).get::<u32>() == Some(id.get());
                if ours && matches!(sig.signal_name, "ActionInvoked" | "NotificationClosed") {
                    clicked.set(sig.signal_name == "ActionInvoked");
                    main.quit();
                }
            },
        )
    };
    let actions = vec!["default", "Open Updates", "open", "Open Updates"];
    let hints: HashMap<String, glib::Variant> = HashMap::new();
    let args = (
        "Ostrich Store",
        0u32,
        "ostrich-store",
        title,
        body,
        actions,
        hints,
        0i32,
    )
        .to_variant();
    match bus.call_sync(
        Some(NAME),
        PATH,
        NAME,
        "Notify",
        Some(&args),
        None,
        gio::DBusCallFlags::NONE,
        -1,
        gio::Cancellable::NONE,
    ) {
        Ok(r) => id.set(r.child_value(0).get::<u32>().unwrap_or(0)),
        Err(_) => return false,
    }
    main.run();
    clicked.get()
}

/// Asks the remotes for updates (network, off the UI thread).
fn check_updates(store: &Rc<Store>) {
    *store.updates.borrow_mut() = None;
    store.changed();
    let s = store.clone();
    glib::spawn_future_local(async move {
        let got = gio::spawn_blocking(all_updates).await;
        *s.updates.borrow_mut() = Some(match got {
            Ok((u, None)) => u,
            Ok((u, Some(e))) => {
                s.toast(&format!("Couldn't check for updates: {e}"));
                u
            }
            Err(_) => Vec::new(),
        });
        s.changed();
    });
}

// ---- the window -----------------------------------------------------------------------------------

/// No catalogue on disk yet (flatpak only fetches it on a first install or update): offer to get it.
/// From the desktop session polkit lets the user update a remote's app list without a password;
/// adding Flathub, if it's missing, asks for one.
fn no_catalogue(app: &adw::Application, query: &str) {
    let page = adw::StatusPage::builder()
        .icon_name("ostrich-store-symbolic")
        .title("Get the app list")
        .description("Ostrich Store searches Flathub's list of apps, kept on this computer. It hasn't been downloaded yet (about 10 MB).")
        .build();
    let get = gtk::Button::builder()
        .label("Download the app list")
        .halign(gtk::Align::Center)
        .css_classes(["pill", "suggested-action"])
        .build();
    let spinner = gtk::Spinner::builder().halign(gtk::Align::Center).build();
    let box_ = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .build();
    box_.append(&get);
    box_.append(&spinner);
    page.set_child(Some(&box_));
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&page));
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("Ostrich Store")
        .default_width(720)
        .default_height(520)
        .content(&toolbar)
        .build();
    let (app, query, w) = (app.clone(), query.to_string(), window.clone());
    get.connect_clicked(move |button| {
        button.set_sensitive(false);
        spinner.set_spinning(true);
        page.set_description(Some("Downloading the app list…"));
        let (app, query, w, page, spinner, button) = (
            app.clone(),
            query.clone(),
            w.clone(),
            page.clone(),
            spinner.clone(),
            button.clone(),
        );
        glib::spawn_future_local(async move {
            let got = gio::spawn_blocking(|| -> Result<(), String> {
                let run = |args: &[&str]| -> Result<(), String> {
                    let out = std::process::Command::new("flatpak")
                        .args(args)
                        .output()
                        .map_err(|e| format!("flatpak: {e}"))?;
                    if out.status.success() {
                        Ok(())
                    } else {
                        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
                    }
                };
                run(&[
                    "remote-add",
                    "--if-not-exists",
                    REMOTE,
                    "https://dl.flathub.org/repo/flathub.flatpakrepo",
                ])?;
                run(&["update", "--appstream", "--noninteractive", REMOTE])
            })
            .await;
            spinner.set_spinning(false);
            match got {
                Ok(Ok(())) if store_core::catalogue_path(REMOTE).is_some() => {
                    w.close();
                    build(&app, &query);
                }
                Ok(Err(e)) => {
                    page.set_description(Some(&format!("Couldn't download it: {e}")));
                    button.set_sensitive(true);
                }
                _ => {
                    page.set_description(Some(
                        "Couldn't download it. Check the connection and try again.",
                    ));
                    button.set_sensitive(true);
                }
            }
        });
    });
    window.present();
}

fn build(app: &adw::Application, query: &str) {
    // `--updates` (the update notification's button) opens on the Updates tab.
    let open_updates = query == "--updates";
    let query = if open_updates { "" } else { query };
    let Some(catalogue) = store_core::catalogue_path(REMOTE) else {
        return no_catalogue(app, query);
    };
    let apps = match appstream::load(&catalogue) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("ostrich-store-gtk: {e}");
            return no_catalogue(app, query);
        }
    };
    let by_id = apps
        .iter()
        .enumerate()
        .map(|(i, a)| (a.id.clone(), i))
        .collect();

    let job_label = gtk::Label::new(None);
    job_label.set_xalign(0.0);
    let job_progress = gtk::ProgressBar::builder()
        .hexpand(true)
        .valign(gtk::Align::Center)
        .build();
    let job_box = gtk::Box::builder()
        .spacing(12)
        .margin_top(8)
        .margin_bottom(8)
        .margin_start(18)
        .margin_end(18)
        .build();
    job_box.append(&job_label);
    job_box.append(&job_progress);
    let job_bar = gtk::Revealer::builder()
        .child(&job_box)
        .reveal_child(false)
        .build();

    let store = Rc::new(Store {
        apps,
        by_id,
        catalogue,
        installed: RefCell::default(),
        updates: RefCell::default(),
        searcher: RefCell::default(),
        queue: RefCell::default(),
        job: RefCell::default(),
        listeners: RefCell::default(),
        toasts: adw::ToastOverlay::new(),
        job_bar: job_bar.clone(),
        job_label,
        job_progress,
        nav: adw::NavigationView::new(),
        window: RefCell::default(),
    });
    store.reload_installed();

    let search = gtk::SearchEntry::builder()
        .placeholder_text("Search for apps, or paste a GitHub link")
        .hexpand(true)
        .text(if open_target_kind(query).is_some() {
            ""
        } else {
            query
        })
        .build();
    let search_clamp = adw::Clamp::builder()
        .maximum_size(640)
        .child(&search)
        .margin_top(12)
        .margin_start(18)
        .margin_end(18)
        .build();

    let stack = adw::ViewStack::new();
    // Tabs cross-fade (libadwaita sets the duration); off when gtk-enable-animations is off.
    stack.set_enable_transitions(true);
    let explore = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .build();
    explore.append(&search_clamp);
    explore.append(&explore_page(&store, &search));
    stack.add_titled_with_icon(
        &explore,
        Some("explore"),
        "Explore",
        "system-search-symbolic",
    );
    stack.add_titled_with_icon(
        &installed_page(&store),
        Some("installed"),
        "Installed",
        "view-list-symbolic",
    );
    let updates = stack.add_titled_with_icon(
        &updates_page(&store),
        Some("updates"),
        "Updates",
        "software-update-available-symbolic",
    );
    // The Updates tab shows how many are waiting.
    {
        let (s, page) = (store.clone(), updates.clone());
        store.listen(move || {
            let n = s.updates.borrow().as_ref().map(Vec::len).unwrap_or(0);
            page.set_badge_number(n as u32);
            page.set_needs_attention(n > 0);
            true
        });
    }
    // Updates are checked (network) as the store opens, so the tab's count is there to see.
    check_updates(&store);
    if open_updates {
        stack.set_visible_child_name("updates");
    }

    let header = adw::HeaderBar::new();
    header.set_title_widget(Some(
        &adw::ViewSwitcher::builder()
            .stack(&stack)
            .policy(adw::ViewSwitcherPolicy::Wide)
            .build(),
    ));
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&stack));
    toolbar.add_bottom_bar(&job_bar);
    store
        .nav
        .add(&adw::NavigationPage::new(&toolbar, "Ostrich Store"));
    store.toasts.set_child(Some(&store.nav));

    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("Ostrich Store")
        .default_width(1040)
        .default_height(760)
        .content(&store.toasts)
        .build();
    *store.window.borrow_mut() = Some(window.clone());
    // Typing anywhere searches.
    search.set_key_capture_widget(Some(&window));
    let st = stack.clone();
    search.connect_search_changed(move |e| {
        if !e.text().is_empty() {
            st.set_visible_child_name("explore");
        }
    });
    // Leaving with installs still running would leave them going unseen: ask first.
    let s = store.clone();
    window.connect_close_request(move |w| {
        if s.job.borrow().is_none() && s.queue.borrow().is_empty() {
            return glib::Propagation::Proceed;
        }
        let d = adw::AlertDialog::new(
            Some("Stop the installs?"),
            Some("Some apps are still being installed or updated."),
        );
        d.add_response("wait", "Keep going");
        d.add_response("stop", "Stop and close");
        d.set_response_appearance("stop", adw::ResponseAppearance::Destructive);
        d.set_close_response("wait");
        let (s2, w2) = (s.clone(), w.clone());
        d.connect_response(None, move |_, r| {
            if r == "stop" {
                s2.queue.borrow_mut().clear();
                if let Some(mut j) = s2.job.borrow_mut().take() {
                    let _ = j.child.kill();
                    let _ = j.child.wait();
                }
                w2.close();
            }
        });
        d.present(Some(w));
        glib::Propagation::Stop
    });
    window.present();
    if is_github_link(query) {
        github_install(&store, query);
    } else if let Some(target) = open_target_kind(query) {
        open_target(&store, target);
    }
}

/// What the store was opened with, when it isn't a search: an app link, or a Flatpak file
/// (a path or a file:// URI, as the file manager passes it).
enum Target {
    App(String),
    Ref(PathBuf),
    Repo(PathBuf),
}

fn open_target_kind(arg: &str) -> Option<Target> {
    if let Some(id) = flatpak::appstream_id(arg) {
        return Some(Target::App(id));
    }
    let path = if arg.starts_with("file://") {
        gio::File::for_uri(arg).path()?
    } else {
        PathBuf::from(arg)
    };
    match path.extension().and_then(|e| e.to_str()) {
        Some("flatpakref") if path.is_file() => Some(Target::Ref(path)),
        Some("flatpakrepo") if path.is_file() => Some(Target::Repo(path)),
        _ => None,
    }
}

/// An app on Flathub opens on its page; a Flatpak file from elsewhere is offered, then installed
/// (a .flatpakref) or its repository added (a .flatpakrepo).
fn open_target(store: &Rc<Store>, target: Target) {
    let (heading, body, argv) = match target {
        Target::App(id) => {
            if store.app(&id).is_some() {
                show_app(store, &id);
            } else {
                store.toast(&format!("{id} isn't on Flathub"));
            }
            return;
        }
        Target::Ref(path) => {
            let r = std::fs::read_to_string(&path)
                .ok()
                .and_then(|t| flatpak::parse_flatpakref(&t));
            let Some(r) = r else {
                store.toast("That file isn't a Flatpak app file");
                return;
            };
            if store.app(&r.name).is_some() {
                show_app(store, &r.name);
                return;
            }
            let title = if r.title.is_empty() {
                r.name.clone()
            } else {
                r.title.clone()
            };
            (
                format!("Install {title}?"),
                format!(
                    "{} from {}.\n\nThis app isn't on Flathub, so it hasn't been reviewed there: only install apps from places you trust.",
                    r.name, r.url
                ),
                vec![
                    "flatpak".to_string(),
                    "install".into(),
                    "--noninteractive".into(),
                    "-y".into(),
                    "--from".into(),
                    path.to_string_lossy().into_owned(),
                ],
            )
        }
        Target::Repo(path) => {
            let name = path
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_else(|| "repository".into());
            (
                format!("Add the {name} repository?"),
                "Its apps can then be installed with flatpak. Only add repositories you trust."
                    .to_string(),
                vec![
                    "flatpak".to_string(),
                    "remote-add".into(),
                    "--if-not-exists".into(),
                    name,
                    path.to_string_lossy().into_owned(),
                ],
            )
        }
    };
    let d = adw::AlertDialog::new(Some(&heading), Some(&body));
    d.add_response("cancel", "Cancel");
    d.add_response("go", "Install");
    d.set_response_appearance("go", adw::ResponseAppearance::Suggested);
    d.set_close_response("cancel");
    let s = store.clone();
    d.connect_response(None, move |_, r| {
        if r != "go" {
            return;
        }
        s.job_label.set_text(&heading);
        s.job_progress.pulse();
        s.job_bar.set_reveal_child(true);
        let (s2, argv) = (s.clone(), argv.clone());
        glib::spawn_future_local(async move {
            let got = gio::spawn_blocking(move || {
                std::process::Command::new(&argv[0])
                    .args(&argv[1..])
                    .output()
            })
            .await;
            if s2.job.borrow().is_none() {
                s2.job_bar.set_reveal_child(false);
            }
            match got {
                Ok(Ok(out)) if out.status.success() => s2.toast("Done"),
                Ok(Ok(out)) => s2.fail(
                    "That didn't work. Check the internet connection and try again.",
                    &String::from_utf8_lossy(&out.stderr),
                ),
                _ => s2.toast("Couldn't run flatpak"),
            }
            s2.reload_installed();
            s2.changed();
        });
    });
    let window = store.window.borrow().clone();
    d.present(window.as_ref());
}

fn main() -> glib::ExitCode {
    if std::env::args().nth(1).as_deref() == Some("--check-updates") {
        return notify_updates();
    }
    let app = adw::Application::builder()
        .application_id(APP_ID)
        .flags(gio::ApplicationFlags::HANDLES_COMMAND_LINE)
        .build();
    // Our icon (modules/tools/icons) for windows the shell can't match to the desktop entry.
    app.connect_startup(|_| {
        gtk::Window::set_default_icon_name("ostrich-store");
        // Screenshots of pages not opened for a month go, so the cache doesn't only grow.
        let dir = glib::user_cache_dir().join("ostrich-os").join("store");
        std::thread::spawn(move || cache::prune(&dir, std::time::Duration::from_secs(30 * 86400)));
    });
    app.connect_command_line(|app, cl| {
        let args: Vec<String> = cl
            .arguments()
            .iter()
            .skip(1)
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        let query = args.join(" ");
        match app.active_window() {
            Some(w) => w.present(),
            None => build(app, &query),
        }
        glib::ExitCode::SUCCESS
    });
    app.run()
}
