//! ostrich-setup: Ostrich Settings (DESIGN.md: welcome): every Ubuntu Ostrich setting, a page each,
//! with a sidebar. On the first login it runs as the tour (Back / Next / Skip the tour).
//!
//!   ostrich-setup [--tour | --step NAME]
//!
//! Walks through every feature in order; steps that don't apply to the machine are hidden and any
//! step can be skipped. `--step NAME` opens one step on its own (e.g. from the monitor popup).
//! Settings rows are bound straight to GSettings (the extensions' own schemas), so a change applies
//! at once and the wizard keeps no copy. Finishing removes the wizard's autostart entry.

mod schemes;

use adw::prelude::*;
use audio_tune::{abtest, render, system};
use gtk::{gio, glib};
use std::path::PathBuf;
use std::process::Command;
use welcome::{
    env_drawer, env_summary, parse_drawer_list, parse_palette_list, parse_recommended_sites,
    recommended, search, set_pin, steps, Entry, Hardware, Paths, Step, RECOMMENDED_GROUPS,
};

const APP_ID: &str = "ubuntu-ostrich.setup";
const OURS: &str = "ubuntu-ostrich";
const HELPER: &str = "/usr/libexec/ubuntu-ostrich/system-helper";

// ---- settings ----

/// An extension's settings, from the schema shipped inside the installed extension.
fn ext_settings(name: &str) -> Option<gio::Settings> {
    let dir = glib::user_data_dir().join(format!("gnome-shell/extensions/{name}@{OURS}/schemas"));
    let default = gio::SettingsSchemaSource::default();
    let source = gio::SettingsSchemaSource::from_directory(&dir, default.as_ref(), false).ok()?;
    let schema = source.lookup(&format!("org.gnome.shell.extensions.{OURS}.{name}"), false)?;
    Some(gio::Settings::new_full(
        &schema,
        None::<&gio::SettingsBackend>,
        None,
    ))
}

/// A system schema, if installed.
fn sys_settings(id: &str) -> Option<gio::Settings> {
    gio::SettingsSchemaSource::default()?.lookup(id, true)?;
    Some(gio::Settings::new(id))
}

fn switch_row(s: &gio::Settings, key: &str, title: &str, subtitle: &str) -> adw::SwitchRow {
    let row = {
        let r = adw::SwitchRow::builder().use_markup(false).build();
        r.set_title(title);
        r.set_subtitle(subtitle);
        r
    };
    s.bind(key, &row, "active").build();
    row
}

/// A switch for one of the monitor's top-bar pins (its `panel-items` list).
fn pin_row(s: &gio::Settings, id: &'static str, title: &str) -> adw::SwitchRow {
    let row = {
        let r = adw::SwitchRow::builder().use_markup(false).build();
        r.set_title(title);
        r
    };
    let sync = {
        let row = row.clone();
        move |s: &gio::Settings| {
            let on = s.strv("panel-items").iter().any(|p| p.as_str() == id);
            if row.is_active() != on {
                row.set_active(on);
            }
        }
    };
    sync(s);
    s.connect_changed(Some("panel-items"), move |s, _| sync(s));
    let settings = s.clone();
    row.connect_active_notify(move |row| {
        let pins: Vec<String> = settings
            .strv("panel-items")
            .iter()
            .map(|p| p.to_string())
            .collect();
        let next = set_pin(&pins, id, row.is_active());
        if next != pins {
            let _ = settings.set_strv(
                "panel-items",
                next.iter().map(String::as_str).collect::<Vec<_>>(),
            );
        }
    });
    row
}

fn spin_row(s: &gio::Settings, key: &str, title: &str, range: (f64, f64, f64)) -> adw::SpinRow {
    let row = adw::SpinRow::with_range(range.0, range.1, range.2);
    row.set_use_markup(false);
    row.set_title(title);
    if range.2 < 1.0 {
        row.set_digits(if range.2 < 0.1 { 2 } else { 1 });
    }
    s.bind(key, &row, "value").build();
    row
}

/// A string key with fixed choices: (value, label).
fn combo_row(s: &gio::Settings, key: &str, title: &str, choices: &[(&str, &str)]) -> adw::ComboRow {
    let labels: Vec<&str> = choices.iter().map(|c| c.1).collect();
    let row = {
        let r = adw::ComboRow::builder()
            .use_markup(false)
            .model(&gtk::StringList::new(&labels))
            .build();
        r.set_title(title);
        r
    };
    let current = s.string(key);
    if let Some(i) = choices.iter().position(|c| c.0 == current.as_str()) {
        row.set_selected(i as u32);
    }
    let (s, key, values) = (
        s.clone(),
        key.to_string(),
        choices.iter().map(|c| c.0.to_string()).collect::<Vec<_>>(),
    );
    row.connect_selected_notify(move |r| {
        if let Some(v) = values.get(r.selected() as usize) {
            let _ = s.set_string(&key, v);
        }
    });
    row
}

/// A number key with named choices: (value, label). A value set some other way (a dotfile) shows as
/// the largest choice not above it (the first one, if it is below them all), and stays until the row
/// is changed.
fn uint_combo_row(
    s: &gio::Settings,
    key: &str,
    title: &str,
    choices: &[(u32, &str)],
) -> adw::ComboRow {
    let labels: Vec<&str> = choices.iter().map(|c| c.1).collect();
    let row = adw::ComboRow::builder()
        .use_markup(false)
        .model(&gtk::StringList::new(&labels))
        .build();
    row.set_title(title);
    let current = s.uint(key);
    row.set_selected(choices.iter().rposition(|c| c.0 <= current).unwrap_or(0) as u32);
    let (s, key, values) = (
        s.clone(),
        key.to_string(),
        choices.iter().map(|c| c.0).collect::<Vec<_>>(),
    );
    row.connect_selected_notify(move |r| {
        if let Some(v) = values.get(r.selected() as usize) {
            let _ = s.set_uint(&key, *v);
        }
    });
    row
}

fn shortcut_row(title: &str, accel: &str) -> adw::ActionRow {
    let row = {
        let r = adw::ActionRow::builder().use_markup(false).build();
        r.set_title(title);
        r
    };
    let label = adw::ShortcutLabel::new(accel);
    label.set_valign(gtk::Align::Center);
    row.add_suffix(&label);
    row
}

/// The first accelerator of a keybinding key, for showing it.
fn accel_of(s: Option<&gio::Settings>, key: &str, fallback: &str) -> String {
    s.and_then(|s| s.strv(key).first().map(|a| a.to_string()))
        .unwrap_or_else(|| fallback.to_string())
}

// Every row is plain text (`use_markup(false)`): libadwaita parses row titles as markup by default,
// and a bare '&' ("Mail & calendar", a site or app name, an environment name) blanks the row. The
// title and subtitle are set after the row is built: given to the builder, they were parsed as
// markup before use_markup was off.

fn info_row(title: &str, subtitle: &str) -> adw::ActionRow {
    {
        let r = adw::ActionRow::builder()
            .use_markup(false)
            .subtitle_lines(0)
            .build();
        r.set_title(title);
        r.set_subtitle(subtitle);
        r
    }
}

fn group(title: &str, description: &str) -> adw::PreferencesGroup {
    adw::PreferencesGroup::builder()
        .title(title)
        .description(description)
        .build()
}

fn missing(group: &adw::PreferencesGroup, what: &str) {
    group.add(&info_row(
        &format!("{what} isn't installed"),
        "Run the installer again to add it.",
    ));
}

// ---- running tools ----

/// Our tools live in ~/.local/libexec/ubuntu-ostrich (behind the `ostrich` command).
fn tool(name: &str) -> PathBuf {
    let ours = glib::home_dir()
        .join(".local/libexec/ubuntu-ostrich")
        .join(name);
    if ours.exists() {
        return ours;
    }
    glib::find_program_in_path(name).unwrap_or(ours)
}

fn output(cmd: &mut Command) -> Option<String> {
    let out = cmd.output().ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Runs a command without blocking the window; `done` gets whether it succeeded.
fn run_async(argv: &[&str], done: impl FnOnce(bool) + 'static) {
    let args: Vec<&std::ffi::OsStr> = argv.iter().map(std::ffi::OsStr::new).collect();
    match gio::Subprocess::newv(&args, gio::SubprocessFlags::NONE) {
        Ok(p) => p.wait_check_async(None::<&gio::Cancellable>, move |r| done(r.is_ok())),
        Err(_) => done(false),
    }
}

fn status_label() -> gtk::Label {
    let l = gtk::Label::new(None);
    l.add_css_class("dimmed");
    l.set_valign(gtk::Align::Center);
    l
}

/// A button that runs a command and says what happened next to it (`done` on success).
fn action_row(
    title: &str,
    subtitle: &str,
    button: &str,
    argv: Vec<String>,
    done: &'static str,
) -> adw::ActionRow {
    let row = info_row(title, subtitle);
    let status = status_label();
    let b = gtk::Button::with_label(button);
    b.set_valign(gtk::Align::Center);
    let st = status.clone();
    b.connect_clicked(move |b| {
        b.set_sensitive(false);
        st.set_text("…");
        let (b, st) = (b.clone(), st.clone());
        let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
        run_async(&argv, move |ok| {
            b.set_sensitive(true);
            st.set_text(if ok {
                done
            } else {
                "That didn't work; try again"
            });
        });
    });
    row.add_suffix(&status);
    row.add_suffix(&b);
    row
}

/// One of several (graphics, power, touchscreen): a check mark on the current one, a Use button on
/// each; after a change the mark moves and `said(value)` says what happened.
fn choice_rows(
    g: &adw::PreferencesGroup,
    choices: &[(&str, &str, &str)],
    current: &str,
    argv: impl Fn(&str) -> Vec<String> + 'static,
    said: impl Fn(&str) -> String + 'static,
) {
    let status = status_label();
    status.set_wrap(true);
    status.set_xalign(0.0);
    let marks: std::rc::Rc<std::cell::RefCell<Vec<(String, gtk::Image, gtk::Button)>>> =
        Default::default();
    let (argv, said) = (std::rc::Rc::new(argv), std::rc::Rc::new(said));
    for (value, label, sub) in choices {
        let row = info_row(label, sub);
        let mark = gtk::Image::from_icon_name("object-select-symbolic");
        mark.set_tooltip_text(Some("On now"));
        row.add_prefix(&mark);
        let b = gtk::Button::with_label("Use");
        b.set_valign(gtk::Align::Center);
        row.add_suffix(&b);
        marks
            .borrow_mut()
            .push((value.to_string(), mark, b.clone()));
        let (marks, argv, said, status, v) = (
            marks.clone(),
            argv.clone(),
            said.clone(),
            status.clone(),
            value.to_string(),
        );
        b.connect_clicked(move |b| {
            b.set_sensitive(false);
            status.set_text("…");
            let cmd = argv(&v);
            let refs: Vec<&str> = cmd.iter().map(String::as_str).collect();
            let (marks, said, status, v) = (marks.clone(), said.clone(), status.clone(), v.clone());
            run_async(&refs, move |ok| {
                if ok {
                    for (val, m, btn) in marks.borrow().iter() {
                        m.set_opacity(if *val == v { 1.0 } else { 0.0 });
                        btn.set_sensitive(*val != v);
                    }
                    status.set_text(&said(&v));
                } else {
                    for (val, _, btn) in marks.borrow().iter() {
                        if *val == v {
                            btn.set_sensitive(true);
                        }
                    }
                    status.set_text("That didn't work (was the password dialog cancelled?)");
                }
            });
        });
        g.add(&row);
    }
    for (val, m, b) in marks.borrow().iter() {
        m.set_opacity(if val == current { 1.0 } else { 0.0 });
        b.set_sensitive(val != current);
    }
    let status_row = adw::ActionRow::builder()
        .use_markup(false)
        .activatable(false)
        .build();
    status_row.set_child(Some(&status));
    g.add(&status_row);
}

// ---- steps ----

fn page(step: Step, hw: &Hardware) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::new();
    for g in groups(step, hw) {
        page.add(&g);
    }
    page
}

fn groups(step: Step, hw: &Hardware) -> Vec<adw::PreferencesGroup> {
    match step {
        Step::Welcome => welcome_step(),
        Step::Theme => theme_step(),
        Step::TopBar => top_bar_step(),
        Step::Dock => dock_step(),
        Step::Windows => windows_step(),
        Step::Blur => blur_step(),
        Step::Notifications => notifications_step(),
        Step::Drawer => drawer_step(),
        Step::Focus => focus_step(),
        Step::Graphics => graphics_step(),
        Step::Power => power_step(hw),
        Step::Speakers => speakers_step(),
        Step::Touchscreen => touchscreen_step(),
        Step::Apps => apps_step(),
        Step::Finish => finish_step(),
    }
}

/// What Ubuntu Ostrich adds: (extension, name, one-line description, icon).
const EXTENSIONS: [(&str, &str, &str, &str); 11] = [
    (
        "dock",
        "Dock",
        "Your apps at the bottom of the screen; it hides until you need it",
        "view-app-grid-symbolic",
    ),
    (
        "workspaces",
        "Workspace bar",
        "Named workspaces in the top-left corner; click or scroll to switch",
        "view-paged-symbolic",
    ),
    (
        "drawer",
        "Ostrich Drawer",
        "Messaging, AI, mail and other web apps that drop down from the top bar",
        "web-browser-symbolic",
    ),
    (
        "monitor",
        "System monitor",
        "CPU, memory, temperature and graphics in the top bar",
        "utilities-system-monitor-symbolic",
    ),
    (
        "focus",
        "Focus and saved workspaces",
        "One switch to silence everything; workspaces you save and open again, named, where you left off",
        "weather-clear-night-symbolic",
    ),
    (
        "tiling",
        "Tiling",
        "Snap windows to halves and quarters with the keyboard or by dragging",
        "view-dual-symbolic",
    ),
    (
        "blur",
        "Blur",
        "Frosted glass behind the top bar, dock, menus and overview",
        "weather-fog-symbolic",
    ),
    (
        "tray",
        "Tray icons",
        "Icons for apps that run in the background, like Discord or Dropbox",
        "application-x-addon-symbolic",
    ),
    (
        "tweaks",
        "Tweaks",
        "Animation speed, double-Super for the app grid, a tidier top bar",
        "preferences-other-symbolic",
    ),
    (
        "holder-monitor",
        "Second-screen apps",
        "Apps on a second screen (chat, music) stay out of Alt+Tab",
        "video-display-symbolic",
    ),
    (
        "search-new-window",
        "New window from search",
        "Enter on an app in search opens a new window of it",
        "system-search-symbolic",
    ),
];

/// Turns an extension on or off the way the Extensions app does: both shell lists.
fn set_extension_enabled(shell: &gio::Settings, uuid: &str, on: bool) {
    let edit = |key: &str, add: bool| {
        let mut list: Vec<String> = shell.strv(key).iter().map(|s| s.to_string()).collect();
        list.retain(|u| u != uuid);
        if add {
            list.push(uuid.to_string());
        }
        let refs: Vec<&str> = list.iter().map(String::as_str).collect();
        let _ = shell.set_strv(key, refs.as_slice());
    };
    edit("enabled-extensions", on);
    edit("disabled-extensions", !on);
}

/// Every titled row on a page, for the search (rows added later, such as the drawer's site list, are not in it).
fn collect_rows(widget: &gtk::Widget, step: usize, page: &str, out: &mut Vec<Entry>) {
    if let Some(row) = widget.downcast_ref::<adw::PreferencesRow>() {
        let title = row.title().to_string();
        if !title.is_empty() {
            let subtitle = if let Some(r) = widget.downcast_ref::<adw::ActionRow>() {
                r.subtitle().map(|t| t.to_string()).unwrap_or_default()
            } else if let Some(r) = widget.downcast_ref::<adw::ExpanderRow>() {
                r.subtitle().to_string()
            } else {
                String::new()
            };
            out.push(Entry {
                step,
                page: page.to_string(),
                title,
                subtitle,
            });
        }
    }
    let mut child = widget.first_child();
    while let Some(c) = child {
        collect_rows(&c, step, page, out);
        child = c.next_sibling();
    }
}

fn welcome_step() -> Vec<adw::PreferencesGroup> {
    let g = group(
        "What Ubuntu Ostrich added",
        "Turn anything off here, or set it up on its own page. Everything is in Ostrich Settings in the app grid.",
    );
    let places = group("Where things are", "");
    for (title, about) in [
        (
            "The dock",
            "At the bottom edge of the screen. It hides until you push the pointer against the edge.",
        ),
        (
            "All your apps",
            "Press Super (the key with the Windows logo) to see your windows, and press it twice for every app, or use the grid button at the end of the dock.",
        ),
        (
            "The clock",
            "The date in the middle of the top bar: open it for the calendar and notifications, or just rest the pointer on it.",
        ),
        (
            "Quick settings",
            "The icons at the top right, for sound, Wi-Fi, Bluetooth, power mode and Do Not Disturb. Pushing the pointer into the top-right corner opens it too.",
        ),
    ] {
        places.add(&info_row(title, about));
    }
    let shell = sys_settings("org.gnome.shell");
    for (name, title, about, icon) in EXTENSIONS {
        let uuid = format!("{name}@{OURS}");
        let installed = glib::user_data_dir()
            .join(format!("gnome-shell/extensions/{uuid}"))
            .is_dir();
        let row = {
            let r = adw::SwitchRow::builder().use_markup(false).build();
            r.set_title(title);
            r.set_subtitle(if installed {
                about
            } else {
                "Not installed: run `ostrich update` to add it"
            });
            r
        };
        row.add_prefix(&gtk::Image::from_icon_name(icon));
        match (&shell, installed) {
            (Some(shell), true) => {
                let on = shell
                    .strv("enabled-extensions")
                    .iter()
                    .any(|u| u == uuid.as_str());
                row.set_active(on);
                let shell = shell.clone();
                row.connect_active_notify(move |r| {
                    set_extension_enabled(&shell, &uuid, r.is_active())
                });
            }
            _ => row.set_sensitive(false),
        }
        g.add(&row);
    }
    vec![places, g]
}

fn theme_step() -> Vec<adw::PreferencesGroup> {
    let style = group("Style", "Light or dark, for apps and the shell.");
    if let Some(s) = sys_settings("org.gnome.desktop.interface") {
        style.add(&combo_row(
            &s,
            "color-scheme",
            "Appearance",
            &[
                ("default", "Default"),
                ("prefer-dark", "Dark"),
                ("prefer-light", "Light"),
            ],
        ));
    }
    // GNOME's own Accessibility panel, so text size and contrast are a click away from here too.
    let a11y = info_row(
        "Accessibility",
        "Larger text, high contrast, a screen reader and more, in GNOME's settings",
    );
    let open = gtk::Button::builder()
        .label("Open")
        .valign(gtk::Align::Center)
        .build();
    open.connect_clicked(|_| {
        let _ = gio::Subprocess::newv(
            &["gnome-control-center".as_ref(), "universal-access".as_ref()],
            gio::SubprocessFlags::NONE,
        );
    });
    a11y.add_suffix(&open);
    a11y.set_activatable_widget(Some(&open));
    style.add(&a11y);
    let accents = group(
        "Accent colour",
        "Or only the accent: colours picked from your wallpaper first, then GNOME's own. Applies to apps, the terminal and the shell.",
    );
    let list = output(Command::new(tool("ostrich-theme")).arg("list"))
        .map(|t| parse_palette_list(&t))
        .unwrap_or_default();
    if list.is_empty() {
        missing(&accents, "The theme tool (ostrich theme)");
        return vec![style, schemes::scheme_group(), accents];
    }
    let flow = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .max_children_per_line(10)
        .column_spacing(6)
        .row_spacing(6)
        .margin_top(6)
        .margin_bottom(6)
        .build();
    let css: String = list
        .iter()
        .map(|s| format!(".ost-sw-{} {{ background: {}; min-width: 36px; min-height: 36px; border-radius: 18px; }}\n", s.number, s.hex))
        .collect();
    let provider = gtk::CssProvider::new();
    provider.load_from_string(&css);
    if let Some(d) = gtk::gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &d,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
    let status = status_label();
    for s in list {
        let b = gtk::Button::builder()
            .tooltip_text(format!("{} ({})", s.hex, s.source))
            .css_classes([format!("ost-sw-{}", s.number)])
            .build();
        let (n, st) = (s.number.to_string(), status.clone());
        b.connect_clicked(move |_| {
            st.set_text("applying…");
            let st = st.clone();
            let palette = tool("ostrich-theme").to_string_lossy().into_owned();
            run_async(&[&palette, "apply", &n], move |ok| {
                st.set_text(if ok { "applied" } else { "failed" });
            });
        });
        flow.insert(&b, -1);
    }
    accents.add(&flow);
    accents.set_header_suffix(Some(&status));
    vec![style, schemes::scheme_group(), accents]
}

fn top_bar_step() -> Vec<adw::PreferencesGroup> {
    let g = group(
        "System monitor",
        "Readouts in the top bar; click them for the processor, memory, temperatures, fans, network, storage, battery and graphics. Any value in that list can be pinned to the top bar with its star. It checks less often on battery and stops while the screen is locked. An open section scrolls past the number of rows you choose.",
    );
    match ext_settings("monitor") {
        Some(s) => {
            g.add(&pin_row(&s, "cpu.usage", "Processor usage"));
            g.add(&pin_row(&s, "mem.usage", "Memory usage"));
            g.add(&pin_row(&s, "temp.package", "Processor temperature"));
            g.add(&pin_row(&s, "gpu.state", "NVIDIA GPU on or asleep"));
            g.add(&pin_row(&s, "net.down", "Download speed"));
            g.add(&pin_row(&s, "net.up", "Upload speed"));
            g.add(&switch_row(
                &s,
                "hide-zeros",
                "Hide zero values",
                "Leave out idle fans, no traffic and the like",
            ));
            g.add(&uint_combo_row(
                &s,
                "section-rows",
                "Monitor menu size",
                &[(6, "Compact (6 rows)"), (12, "Tall (12 rows)")],
            ));
        }
        None => missing(&g, "The monitor extension"),
    }
    let t = group("Tweaks", "");
    match ext_settings("tweaks") {
        Some(s) => {
            t.add(&spin_row(
                &s,
                "animation-speed",
                "Animation speed (1 is normal, lower is faster)",
                (0.1, 3.0, 0.1),
            ));
            t.add(&switch_row(
                &s,
                "double-super-to-appgrid",
                "Press Super twice for the app grid",
                "Once shows your windows, again shows all your apps",
            ));
            t.add(&combo_row(
                &s,
                "folder-colour",
                "Folder colour",
                &[
                    ("accent", "Follows the accent colour"),
                    ("default", "Orange (Ubuntu)"),
                    ("bark", "Bark"),
                    ("sage", "Sage"),
                    ("olive", "Olive"),
                    ("viridian", "Viridian"),
                    ("prussiangreen", "Prussian green"),
                    ("blue", "Blue"),
                    ("purple", "Purple"),
                    ("magenta", "Magenta"),
                    ("red", "Red"),
                ],
            ));
            t.add(&switch_row(
                &s,
                "accent-follows-wallpaper",
                "Accent colour follows the wallpaper",
                "A new wallpaper picks a new accent, if your accent came from the old one",
            ));
            t.add(&switch_row(
                &s,
                "today-panel",
                "Today in the clock menu",
                "This computer's battery and power, world clocks and the weather, in place of the month grid",
            ));
            t.add(&switch_row(
                &s,
                "show-events",
                "Show calendar events",
                "GNOME's events card in the clock menu, for calendars added in Online Accounts",
            ));
            t.add(&switch_row(
                &s,
                "now-playing-pill",
                "What's playing, in the top bar",
                "Only while music or a video plays; click it to skip or pause. GNOME's media card stays in the clock menu",
            ));
            t.add(&switch_row(
                &s,
                "hover-open-menus",
                "Open the clock and what's playing by resting the pointer",
                "Like the drawer's icons; the menu closes when the pointer leaves",
            ));
            t.add(&spin_row(
                &s,
                "hover-open-delay-ms",
                "Rest time before the clock or orb opens (milliseconds)",
                (500.0, 2000.0, 50.0),
            ));
            t.add(&switch_row(
                &s,
                "quick-settings-corner",
                "Top-right corner opens quick settings",
                "Push the pointer into the corner, like the top-left corner opens the overview",
            ));
            t.add(&switch_row(
                &s,
                "clock-menu-quiet",
                "Do Not Disturb and Focus in the clock menu",
                "Two switches under the date, also in quick settings (top-right)",
            ));
            t.add(&combo_row(
                &s,
                "quick-settings-style",
                "Quick settings",
                &[
                    (
                        "ostrich",
                        "Ubuntu Ostrich (a power-mode row on laptops with three modes)",
                    ),
                    ("stock", "GNOME's own"),
                ],
            ));
        }
        None => missing(&t, "The tweaks extension"),
    }
    vec![g, t]
}

fn dock_step() -> Vec<adw::PreferencesGroup> {
    let g = group(
        "Dock",
        "Floating at the bottom, only as wide as its icons. Hover over an app to see its windows; scroll over it to go through them.",
    );
    let Some(s) = ext_settings("dock") else {
        missing(&g, "The dock extension");
        return vec![g];
    };
    g.add(&switch_row(
        &s,
        "autohide",
        "Hide when not in use",
        "Push the pointer against the bottom edge to bring it back",
    ));
    g.add(&switch_row(
        &s,
        "intellihide",
        "Only hide when a window is in the way",
        "With nothing near the bottom of the screen, it stays visible",
    ));
    g.add(&combo_row(
        &s,
        "click-action",
        "Clicking an app that's already in front",
        &[
            (
                "focus-or-minimize",
                "Minimize it (or go to its next window)",
            ),
            ("focus-or-cycle", "Go to its next window"),
            ("focus", "Nothing"),
        ],
    ));
    g.add(&combo_row(
        &s,
        "indicator",
        "Running apps",
        &[
            ("dots", "A dot for each window"),
            ("dot", "One dot"),
            ("none", "No dots"),
        ],
    ));
    g.add(&switch_row(
        &s,
        "previews",
        "Window previews",
        "Hover over an app to see its windows; click one to switch, middle-click to close it",
    ));
    g.add(&switch_row(
        &s,
        "badges",
        "Unread counts and progress",
        "From apps that report them, like Thunderbird, Telegram or a download in Firefox",
    ));
    g.add(&switch_row(
        &s,
        "show-apps-at-start",
        "App grid button first",
        "",
    ));
    g.add(&spin_row(&s, "icon-size", "Icon size", (16.0, 64.0, 2.0)));
    g.add(&combo_row(
        &s,
        "background",
        "Colour",
        &[
            ("theme", "Black or white (follows the style)"),
            ("palette", "Accent colour from your wallpaper"),
            ("custom", "Your own colour (as Dash to Dock had it)"),
        ],
    ));
    g.add(&percent_row(&s, "background-opacity", "Background opacity"));
    vec![g]
}

/// A 0.0–1.0 setting shown as a percentage.
fn percent_row(s: &gio::Settings, key: &str, title: &str) -> adw::SpinRow {
    let row = adw::SpinRow::with_range(0.0, 100.0, 5.0);
    row.set_use_markup(false);
    row.set_title(title);
    row.set_value((s.double(key) * 100.0).round());
    let (s2, k) = (s.clone(), key.to_string());
    row.connect_value_notify(move |r| {
        let _ = s2.set_double(&k, r.value() / 100.0);
    });
    row
}

fn windows_step() -> Vec<adw::PreferencesGroup> {
    let w = group(
        "Workspaces",
        "The workspace bar sits at the left of the top bar. Click a workspace to go there (the current one opens the overview), drag one to reorder, drop a window from the overview onto one to move it, and right-click to rename, add, move or remove.",
    );
    if let Some(m) = sys_settings("org.gnome.mutter") {
        w.add(&switch_row(
            &m,
            "dynamic-workspaces",
            "Add and remove workspaces as needed",
            "",
        ));
    }
    if let Some(p) = sys_settings("org.gnome.desktop.wm.preferences") {
        w.add(&spin_row(
            &p,
            "num-workspaces",
            "Number of workspaces",
            (1.0, 12.0, 1.0),
        ));
    }
    if let Some(s) = ext_settings("workspaces") {
        w.add(&switch_row(
            &s,
            "smart-names",
            "Name workspaces after their apps",
            "A workspace with your mail app on it is called what you last named that one",
        ));
        w.add(&switch_row(
            &s,
            "show-empty",
            "Show empty workspaces",
            "Off: only workspaces with windows (and the current one)",
        ));
        w.add(&combo_row(
            &s,
            "indicator-style",
            "Show",
            &[
                ("all", "Every workspace"),
                ("current", "Only the current workspace"),
            ],
        ));
        w.add(&switch_row(
            &s,
            "show-icons",
            "App icons on each workspace",
            "Small icons of what's open, next to the name",
        ));
        w.add(&combo_row(
            &s,
            "active-style",
            "Current workspace",
            &[("accent", "Accent colour"), ("contrast", "White")],
        ));
        let ws = Some(&s);
        for (key, title, fallback) in [
            ("new-workspace", "New workspace", "<Super><Alt>n"),
            (
                "rename-workspace",
                "Rename the current workspace",
                "<Super><Alt>r",
            ),
            ("move-workspace-left", "Move it left", "<Super><Alt>Page_Up"),
            (
                "move-workspace-right",
                "Move it right",
                "<Super><Alt>Page_Down",
            ),
        ] {
            w.add(&shortcut_row(title, &accel_of(ws, key, fallback)));
        }
    }
    let t = group(
        "Tiling",
        "Drag a window to a screen edge or corner, or use the shortcuts below. After tiling, pick a window for the rest of the screen.",
    );
    let ts = ext_settings("tiling");
    match &ts {
        Some(s) => {
            t.add(&switch_row(
                s,
                "drag-tiling",
                "Tile by dragging to an edge",
                "",
            ));
            t.add(&switch_row(
                s,
                "fill-popup",
                "Offer windows for the rest of the screen",
                "",
            ));
            t.add(&switch_row(
                s,
                "raise-together",
                "Raise tiled windows together",
                "",
            ));
            t.add(&spin_row(
                s,
                "window-gap",
                "Gap between windows",
                (0.0, 32.0, 2.0),
            ));
            t.add(&switch_row(
                s,
                "focus-hint",
                "Outline the focused window",
                "",
            ));
        }
        None => missing(&t, "The tiling extension"),
    }
    let k = group("Shortcuts", "");
    k.add(&shortcut_row(
        "Left / right half",
        &format!(
            "{} {}",
            accel_of(ts.as_ref(), "tile-left", "<Super>Left"),
            accel_of(ts.as_ref(), "tile-right", "<Super>Right")
        ),
    ));
    k.add(&shortcut_row(
        "Maximize, or from a half: its top quarter",
        &accel_of(ts.as_ref(), "tile-up", "<Super>Up"),
    ));
    k.add(&shortcut_row(
        "Restore, or from a half: its bottom quarter",
        &accel_of(ts.as_ref(), "tile-down", "<Super>Down"),
    ));
    k.add(&shortcut_row(
        "Quarters",
        "<Super>KP_7 <Super>KP_9 <Super>KP_1 <Super>KP_3",
    ));
    vec![w, t, k]
}

fn blur_step() -> Vec<adw::PreferencesGroup> {
    let g = group(
        "Blur",
        "Frosted glass behind each surface, or solid. The blur is only redrawn when what's behind it changes, so it costs nothing at rest.",
    );
    let Some(s) = ext_settings("blur") else {
        missing(&g, "The blur extension");
        return vec![g];
    };
    g.add(&switch_row(
        &s,
        "high-contrast",
        "High contrast",
        "Every surface solid, for the clearest text. Your blur settings come back when you turn it off",
    ));
    // Each surface: on or off, and how strong (an expander so the step stays short).
    for (key, prefix, title, off) in [
        ("panel", "panel", "Top bar", "Off: solid"),
        ("dock", "dock", "Dock", "Off: solid"),
        ("menus", "menus", "Menus and quick settings", "Off: solid"),
        (
            "notifications",
            "notifications",
            "Notifications",
            "Off: solid",
        ),
        (
            "overview",
            "overview",
            "Overview and app grid",
            "Off: the plain wallpaper",
        ),
        ("app-folders", "folders", "App folders", "Off: solid"),
    ] {
        let row = {
            let r = adw::ExpanderRow::builder()
                .use_markup(false)
                .show_enable_switch(true)
                .build();
            r.set_title(title);
            r.set_subtitle(off);
            r
        };
        s.bind(key, &row, "enable-expansion").build();
        row.add_row(&spin_row(
            &s,
            &format!("{prefix}-radius"),
            "Strength",
            (1.0, 150.0, 5.0),
        ));
        row.add_row(&spin_row(
            &s,
            &format!("{prefix}-brightness"),
            "Brightness",
            (0.3, 1.0, 0.05),
        ));
        g.add(&row);
    }
    g.add(&switch_row(
        &s,
        "lock-screen",
        "Lock screen",
        "Off: a solid colour from your palette",
    ));
    g.add(&switch_row(
        &s,
        "static-on-battery-saver",
        "Lighter glass in power saver",
        "The top bar and dock blur only the wallpaper; menus, folders and the overview turn solid black, to save battery",
    ));
    vec![g]
}

fn notifications_step() -> Vec<adw::PreferencesGroup> {
    let g = group(
        "Notifications",
        "Banners pop up for new notifications. Do Not Disturb (in the top-right menu, and in the clock menu) and focus mode hide them; they still collect in the notification list.",
    );
    if let Some(s) = sys_settings("org.gnome.desktop.notifications") {
        g.add(&switch_row(
            &s,
            "show-banners",
            "Show banners",
            "Off is the same as Do Not Disturb",
        ));
    }
    vec![g]
}

fn drawer_step() -> Vec<adw::PreferencesGroup> {
    let ds = ext_settings("drawer");
    let g = group(
        "Ostrich Drawer",
        "Your web apps in the top bar: messaging, AI chat, mail, video, any site. Each site has an icon with an unread badge; click it, or rest the pointer on it, and the site drops down under it. Each site keeps its own sign-in, and its notifications appear as that app. Drag the drawer's bottom edge to resize a site; it remembers. Right-click an icon to unload it, keep it loaded, mute it or unpin it.",
    );
    g.add(&shortcut_row(
        "Show or hide the drawer",
        &accel_of(ds.as_ref(), "toggle-drawer", "<Super><Alt>d"),
    ));
    match &ds {
        Some(s) => {
            g.add(&switch_row(
                s,
                "open-on-hover",
                "Open a site by hovering over its icon",
                "It folds back up when the pointer leaves, unless you clicked or typed in it",
            ));
            g.add(&spin_row(
                s,
                "hover-delay-ms",
                "Hover delay (milliseconds)",
                (100.0, 2000.0, 50.0),
            ));
            g.add(&spin_row(
                s,
                "bar-max",
                "Site icons in the top bar (the rest are in its ⌄ menu)",
                (0.0, 12.0, 1.0),
            ));
            g.add(&combo_row(
                s,
                "position",
                "Where it opens",
                &[
                    ("under-icon", "Under the site's icon"),
                    ("top-center", "Top centre"),
                    ("top-left", "Top-left corner"),
                    ("top-right", "Top-right corner"),
                ],
            ));
            g.add(&spin_row(
                s,
                "width",
                "Wide sites: width (% of the screen)",
                (20.0, 100.0, 5.0),
            ));
            g.add(&spin_row(
                s,
                "height",
                "Wide sites: height (% of the screen below the top bar)",
                (20.0, 100.0, 5.0),
            ));
            g.add(&switch_row(
                s,
                "hide-on-focus-loss",
                "Hide when clicking outside it",
                "",
            ));
        }
        None => missing(&g, "The drawer extension"),
    }
    let drawer = tool("ostrich-drawer").to_string_lossy().into_owned();
    g.add(&action_row(
        "Open the drawer",
        "Sign in to your sites now, or later",
        "Open",
        vec![drawer.clone()],
        "Opened: it's at the top of the screen",
    ));
    let sites = std::rc::Rc::new(Sites {
        group: group(
            "Your sites",
            "Chat sites open narrow, like a phone; the rest open wide. Any web page can be a site. Sites that need DRM video (Spotify, Netflix) open in their app or your browser instead.",
        ),
        rows: Default::default(),
        drawer,
        recommended: group(
            "Recommended sites",
            "Each loaded site uses about 50–480 MB of memory. Messaging and mail stay loaded so they can notify; the others load when opened and unload after 15 minutes hidden.",
        ),
        rec_rows: Default::default(),
    });
    sites_group(&sites);
    vec![g, sites.group.clone(), sites.recommended.clone()]
}

/// The drawer's sites (pin, remove, add any address) and the recommended ones to add. Changes go
/// through the running drawer (`--add` / `--remove` / `--pin` / `--unpin`), which owns drawer.toml.
struct Sites {
    group: adw::PreferencesGroup,
    rows: std::cell::RefCell<Vec<gtk::Widget>>,
    drawer: String,
    recommended: adw::PreferencesGroup,
    rec_rows: std::cell::RefCell<Vec<gtk::Widget>>,
}

fn refresh_sites(s: &std::rc::Rc<Sites>) {
    for r in s.rows.borrow_mut().drain(..) {
        s.group.remove(&r);
    }
    for r in s.rec_rows.borrow_mut().drain(..) {
        s.recommended.remove(&r);
    }
    let list = output(Command::new(&s.drawer).arg("--list"))
        .map(|t| parse_drawer_list(&t))
        .unwrap_or_default();
    for site in &list {
        let row = info_row(&site.name, &site.url);
        let pin = gtk::Switch::builder()
            .active(site.pinned)
            .valign(gtk::Align::Center)
            .tooltip_text("Icon in the top bar")
            .build();
        let (drawer, id) = (s.drawer.clone(), site.id.clone());
        pin.connect_active_notify(move |p| {
            let flag = if p.is_active() { "--pin" } else { "--unpin" };
            run_async(&[&drawer, flag, &id], |_| {});
        });
        let pin_label = gtk::Label::new(Some("Top bar"));
        pin_label.add_css_class("dimmed");
        row.add_suffix(&pin_label);
        row.add_suffix(&pin);
        // Kept loaded: messages arrive at once, at a cost in memory (about 250 MB a site).
        let keep = gtk::Switch::builder()
            .active(site.kept)
            .valign(gtk::Align::Center)
            .tooltip_text(
                "Keep it loaded in the background, so its messages arrive at once (uses memory)",
            )
            .build();
        let (drawer, id) = (s.drawer.clone(), site.id.clone());
        keep.connect_active_notify(move |k| {
            let flag = if k.is_active() { "--keep" } else { "--unkeep" };
            run_async(&[&drawer, flag, &id], |_| {});
        });
        let keep_label = gtk::Label::new(Some("Keep loaded"));
        keep_label.add_css_class("dimmed");
        row.add_suffix(&keep_label);
        row.add_suffix(&keep);
        let b = gtk::Button::with_label("Remove");
        b.set_valign(gtk::Align::Center);
        let (s2, id) = (s.clone(), site.id.clone());
        b.connect_clicked(move |b| {
            b.set_sensitive(false);
            let s3 = s2.clone();
            run_async(&[&s2.drawer, "--remove", &id], move |_| refresh_sites(&s3));
        });
        row.add_suffix(&b);
        s.group.add(&row);
        s.rows.borrow_mut().push(row.upcast());
    }

    let have: Vec<&str> = list.iter().map(|x| x.url.as_str()).collect();
    let rec = output(Command::new(&s.drawer).arg("--recommended"))
        .map(|t| parse_recommended_sites(&t))
        .unwrap_or_default();
    for (key, title) in RECOMMENDED_GROUPS {
        // The title goes in after use_markup is off: given to the builder, it was parsed as markup
        // first (and "Mail & calendar" came out blank).
        let expander = adw::ExpanderRow::builder().use_markup(false).build();
        expander.set_title(title);
        let mut n = 0;
        for r in rec.iter().filter(|r| r.group == key) {
            n += 1;
            let row = info_row(&r.name, &r.url);
            if r.drm {
                // Can't play in the drawer (DRM video): opened in its own app, or the browser.
                let b = gtk::Button::with_label(if r.app {
                    "Get the app"
                } else {
                    "Open in browser"
                });
                b.set_valign(gtk::Align::Center);
                b.set_tooltip_text(Some(
                    "This site needs DRM video, which the drawer can't play",
                ));
                let (drawer, id) = (s.drawer.clone(), r.id.clone());
                b.connect_clicked(move |_| run_async(&[&drawer, "--elsewhere", &id], |_| {}));
                row.add_suffix(&b);
            } else if have.contains(&r.url.as_str()) {
                let l = gtk::Label::new(Some("Added"));
                l.add_css_class("dimmed");
                row.add_suffix(&l);
            } else {
                let b = gtk::Button::with_label("Add");
                b.set_valign(gtk::Align::Center);
                let (s2, id) = (s.clone(), r.id.clone());
                b.connect_clicked(move |b| {
                    b.set_sensitive(false);
                    let s3 = s2.clone();
                    run_async(&[&s2.drawer, "--add", &id], move |_| refresh_sites(&s3));
                });
                row.add_suffix(&b);
            }
            expander.add_row(&row);
        }
        if n > 0 {
            s.recommended.add(&expander);
            s.rec_rows.borrow_mut().push(expander.upcast());
        }
    }
}

fn sites_group(s: &std::rc::Rc<Sites>) {
    let add = {
        let r = adw::EntryRow::builder()
            .use_markup(false)
            .show_apply_button(true)
            .build();
        r.set_title("Add a site, e.g. web.whatsapp.com");
        r
    };
    s.group.add(&add);
    let s2 = s.clone();
    add.connect_apply(move |e| {
        let url = e.text().trim().to_string();
        if url.is_empty() {
            return;
        }
        e.set_text("");
        let s3 = s2.clone();
        run_async(&[&s2.drawer, "--add", &url], move |_| refresh_sites(&s3));
    });
    refresh_sites(s);
}

fn focus_step() -> Vec<adw::PreferencesGroup> {
    let fs = ext_settings("focus");
    let g = group(
        "Focus mode",
        "One switch: Do Not Disturb on, the drawer muted and hidden, and the dock, tray, drawer icons, monitor and workspace bar hidden. Only your windows and the clock stay. Turning it off puts everything back. Also in the top-right menu and the clock menu.",
    );
    g.add(&shortcut_row(
        "Focus mode on/off",
        &accel_of(fs.as_ref(), "toggle-focus", "<Super><Alt>f"),
    ));
    let Some(fs) = fs else {
        missing(&g, "The focus extension");
        return vec![g];
    };
    vec![g, allow_group(&fs), environments_group()]
}

/// Which apps stay in focus. None ticked: every app stays (only distractions are hidden).
fn allow_group(fs: &gio::Settings) -> adw::PreferencesGroup {
    let g = group(
        "Only these apps in focus",
        "Tick the apps you want while focusing; every other app is hidden (its windows minimised, and gone from the app grid and search) until focus ends. Leave all unticked to keep every app.",
    );
    let mut apps: Vec<gio::AppInfo> = gio::AppInfo::all()
        .into_iter()
        .filter(|a| a.should_show() && a.id().is_some())
        .collect();
    apps.sort_by_key(|a| a.display_name().to_lowercase());
    let expander = {
        let r = adw::ExpanderRow::builder().use_markup(false).build();
        r.set_title("Apps");
        r.set_subtitle(&format!("{} chosen", fs.strv("allowed-apps").len()));
        r
    };
    for app in apps {
        let id = app.id().unwrap().to_string();
        let check = gtk::CheckButton::new();
        check.set_active(fs.strv("allowed-apps").iter().any(|a| a.as_str() == id));
        let row = {
            let r = adw::ActionRow::builder()
                .use_markup(false)
                .activatable_widget(&check)
                .build();
            r.set_title(app.display_name().as_str());
            r
        };
        row.add_prefix(&check);
        let (fs, exp) = (fs.clone(), expander.clone());
        check.connect_toggled(move |c| {
            let mut list: Vec<String> = fs
                .strv("allowed-apps")
                .iter()
                .map(|s| s.to_string())
                .collect();
            list.retain(|x| x != &id);
            if c.is_active() {
                list.push(id.clone());
            }
            let refs: Vec<&str> = list.iter().map(String::as_str).collect();
            let _ = fs.set_strv("allowed-apps", refs.as_slice());
            exp.set_subtitle(&format!("{} chosen", list.len()));
        });
        expander.add_row(&row);
    }
    g.add(&expander);
    g
}

/// Environments: save the current desktop, open saved ones (through `ostrich env`).
/// The environments step's rows that change: one per saved environment, and their drawer sites.
struct Envs {
    group: adw::PreferencesGroup,
    rows: std::cell::RefCell<Vec<gtk::Widget>>,
    ostrich: String,
}

fn refresh_envs(e: &std::rc::Rc<Envs>) {
    for r in e.rows.borrow_mut().drain(..) {
        e.group.remove(&r);
    }
    let dir = glib::user_config_dir().join("ubuntu-ostrich/environments");
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .map(|r| r.filter_map(|x| x.ok().map(|x| x.path())).collect())
        .unwrap_or_default();
    files.retain(|p| p.extension().is_some_and(|x| x == "json"));
    files.sort();
    if files.is_empty() {
        let row = info_row(
            "No saved workspaces yet",
            "Arrange a workspace with the apps you need, then save it above.",
        );
        e.group.add(&row);
        e.rows.borrow_mut().push(row.upcast());
    }
    for path in files {
        let Some(id) = path.file_stem().and_then(|s| s.to_str()).map(String::from) else {
            continue;
        };
        let Some((name, apps)) = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| env_summary(&t))
        else {
            continue;
        };
        let row = info_row(
            &name,
            &format!("{apps} app{}", if apps == 1 { "" } else { "s" }),
        );
        let open = gtk::Button::with_label("Open");
        open.set_valign(gtk::Align::Center);
        let (o, i) = (e.ostrich.clone(), id.clone());
        open.connect_clicked(move |_| run_async(&[&o, "env", "open", &i], |_| {}));
        let delete = gtk::Button::from_icon_name("user-trash-symbolic");
        delete.set_tooltip_text(Some("Delete"));
        delete.add_css_class("flat");
        delete.set_valign(gtk::Align::Center);
        let (e2, i) = (e.clone(), id.clone());
        delete.connect_clicked(move |_| {
            let e3 = e2.clone();
            run_async(&[&e2.ostrich, "env", "delete", &i], move |_| {
                refresh_envs(&e3)
            });
        });
        row.add_suffix(&open);
        row.add_suffix(&delete);
        e.group.add(&row);
        e.rows.borrow_mut().push(row.upcast());
    }
    for row in environment_drawer_rows(&e.ostrich) {
        e.group.add(&row);
        e.rows.borrow_mut().push(row.upcast());
    }
}

fn environments_group() -> adw::PreferencesGroup {
    let g = group(
        "Saved workspaces",
        "Save a workspace (its apps, where their windows are, and the drawer sites in the top bar) and open it again with one click: it comes back on its own workspace, named after it, say \"Video editing\" or \"School\". Closing it saves where you left off and closes its apps. Open them here, from the Focus menu in the top-right, or with `ostrich workspace open NAME`. Focus is separate: it quiets the whole desktop.",
    );
    let ostrich = glib::home_dir()
        .join(".local/bin/ostrich")
        .to_string_lossy()
        .into_owned();
    let save = {
        let r = adw::EntryRow::builder()
            .use_markup(false)
            .show_apply_button(true)
            .build();
        r.set_title("Save this workspace as (a name)");
        r
    };
    let status = status_label();
    save.add_suffix(&status);
    g.add(&save);
    let envs = std::rc::Rc::new(Envs {
        group: g.clone(),
        rows: Default::default(),
        ostrich: ostrich.clone(),
    });
    let e2 = envs.clone();
    save.connect_apply(move |entry| {
        let name = entry.text().trim().to_string();
        if name.is_empty() {
            return;
        }
        let st = status.clone();
        let mut argv = vec![ostrich.as_str(), "env", "save"];
        argv.extend(name.split_whitespace());
        entry.set_text("");
        let e3 = e2.clone();
        run_async(&argv, move |ok| {
            st.set_text(if ok {
                "Saved"
            } else {
                "Couldn't save: open some app windows on this workspace first"
            });
            refresh_envs(&e3);
        });
    });
    refresh_envs(&envs);
    g
}

/// For each saved environment: which Ostrich Drawer sites its top bar has (`ostrich env drawer`).
/// None ticked: it uses the normal sites.
fn environment_drawer_rows(ostrich: &str) -> Vec<adw::ExpanderRow> {
    let dir = glib::user_config_dir().join("ubuntu-ostrich/environments");
    let drawer = tool("ostrich-drawer");
    let sites = output(Command::new(&drawer).arg("--list"))
        .map(|t| parse_drawer_list(&t))
        .unwrap_or_default();
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .map(|r| r.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default();
    files.retain(|p| p.extension().is_some_and(|x| x == "json"));
    files.sort();
    let mut rows = Vec::new();
    for path in files {
        let Some(id) = path.file_stem().and_then(|s| s.to_str()).map(String::from) else {
            continue;
        };
        let Some((name, chosen)) = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| env_drawer(&t))
        else {
            continue;
        };
        let chosen = chosen.unwrap_or_default();
        let subtitle = |n: usize| {
            if n == 0 {
                "The normal sites".to_string()
            } else {
                format!("{n} chosen")
            }
        };
        let expander = {
            let r = adw::ExpanderRow::builder().use_markup(false).build();
            r.set_title(&format!("{name}: drawer sites"));
            r.set_subtitle(&subtitle(chosen.len()));
            r
        };
        let count = std::rc::Rc::new(std::cell::Cell::new(chosen.len()));
        for site in &sites {
            let check = gtk::CheckButton::new();
            check.set_active(chosen.contains(&site.id));
            let row = {
                let r = adw::ActionRow::builder()
                    .use_markup(false)
                    .activatable_widget(&check)
                    .build();
                r.set_title(site.name.as_str());
                r
            };
            row.add_prefix(&check);
            let (ostrich, id, site, exp, count) = (
                ostrich.to_string(),
                id.clone(),
                site.id.clone(),
                expander.clone(),
                count.clone(),
            );
            check.connect_toggled(move |c| {
                let verb = if c.is_active() { "add" } else { "remove" };
                count.set(if c.is_active() {
                    count.get() + 1
                } else {
                    count.get().saturating_sub(1)
                });
                exp.set_subtitle(&subtitle(count.get()));
                run_async(&[&ostrich, "env", "drawer", &id, verb, &site], |_| {});
            });
            expander.add_row(&row);
        }
        rows.push(expander);
    }
    rows
}

fn graphics_step() -> Vec<adw::PreferencesGroup> {
    let g = group(
        "Graphics mode",
        "Which graphics chip runs the desktop. Switching takes effect when you log out and back in.",
    );
    let current = output(Command::new(HELPER).args(["graphics", "status"]))
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    if current.is_empty() || current == "none" {
        missing(&g, "Graphics switching (the system helper or prime-select)");
        return vec![g];
    }
    choice_rows(
        &g,
        &[
            (
                "hybrid",
                "Hybrid (recommended)",
                "The desktop on the built-in chip; NVIDIA wakes up only when an app needs it",
            ),
            (
                "integrated",
                "Integrated",
                "NVIDIA off entirely: the longest battery",
            ),
            (
                "discrete",
                "Discrete",
                "Everything on NVIDIA: the most speed, the shortest battery",
            ),
        ],
        &current,
        |mode| {
            vec![
                "pkexec".into(),
                HELPER.into(),
                "graphics".into(),
                "set".into(),
                mode.into(),
            ]
        },
        |mode| format!("Switched to {mode}: log out and back in to use it."),
    );
    vec![g]
}

fn power_step(hw: &Hardware) -> Vec<adw::PreferencesGroup> {
    let g = group(
        "Power modes",
        "Power saver: CPU boost off and a lower power limit (still fine for the web), deeper power saving for PCIe, USB, Wi-Fi, disks and the NVIDIA GPU, the screen dims sooner, the drawer's background tabs paused. Balanced: the machine's own defaults. Performance: full speed, on battery too. Pick one in the top-right menu at any time; on a laptop with all three modes it is one row there, one click each.",
    );
    let current = output(Command::new("powerprofilesctl").arg("get"))
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    choice_rows(
        &g,
        &[
            (
                "power-saver",
                "Power saver",
                "Longest battery, still smooth for browsing",
            ),
            ("balanced", "Balanced", "The machine's own defaults"),
            ("performance", "Performance", "Full speed, also on battery"),
        ],
        &current,
        |mode| vec!["powerprofilesctl".into(), "set".into(), mode.into()],
        |mode| {
            let name = match mode {
                "power-saver" => "Power saver",
                "performance" => "Performance",
                _ => "Balanced",
            };
            format!("{name} is on. Change it any time in the top-right menu.")
        },
    );
    let mut out = vec![g];
    if let Some(ms) = ext_settings("monitor") {
        let b = group("On battery", "");
        if hw.battery {
            let row = spin_row(
                &ms,
                "auto-saver-percent",
                "Switch to power saver at (%)",
                (0.0, 50.0, 5.0),
            );
            row.set_subtitle("0 = never; it goes back to your mode when you plug in");
            b.add(&row);
        }
        b.add(&switch_row(
            &ms,
            "saver-desktop",
            "In power saver, dim the screen sooner",
            "",
        ));
        b.add(&switch_row(
            &ms,
            "memory-warning",
            "Warn before memory runs out",
            "Once, when memory and swap are 85 % full, naming the app using the most",
        ));
        out.push(b);
    }
    out
}

// ---- speakers: presets with previews, and tuning by ear (A/B) ----
//
// Clips are music and speech (public domain, installed by modules/tools) or, without them, pink
// noise. Previews and the A/B pair are rendered here, through the same biquads PipeWire runs, and
// played with gtk::MediaFile. PipeWire routes everything for the speakers through the current
// tuning, so while previewing or testing the tuning is off (one PipeWire restart); closing the
// wizard without choosing puts the previous tuning back.

thread_local! {
    /// Run when the wizard window closes (puts the speaker tuning back if a test was abandoned).
    static ON_CLOSE: std::cell::RefCell<Vec<Box<dyn Fn()>>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// Run when the wizard closes and when it leaves a page (the speakers stop playing, and a paused
/// tuning comes back).
fn on_close(f: impl Fn() + 'static) {
    ON_CLOSE.with(|v| v.borrow_mut().push(Box::new(f)));
}

fn run_leave_hooks() {
    ON_CLOSE.with(|v| v.borrow().iter().for_each(|f| f()));
}

const PRESET_ABOUT: [(&str, &str); 6] = [
    ("flat", "The speakers as they are, unchanged"),
    ("voice", "Clearer speech for calls, videos and podcasts"),
    ("music", "Fuller sound for music"),
    ("bass", "More low end"),
    ("movie", "Dialogue forward, effects fuller"),
    ("custom", "Your result from tuning by ear"),
];

fn preset_title(p: &str) -> String {
    let mut t = p.to_string();
    if let Some(f) = t.get_mut(0..1) {
        f.make_ascii_uppercase();
    }
    t
}

struct Speakers {
    at: String,
    /// The installed clips: (id, name, kind); the chooser's last entry is pink noise.
    clips: Vec<(String, String, String)>,
    clip: std::cell::RefCell<Option<String>>,
    /// The preset that was on before the wizard paused the tuning ("off": none); None while not paused.
    paused_from: std::cell::RefCell<Option<String>>,
    playing: std::cell::RefCell<Vec<gtk::MediaFile>>,
    status: gtk::Label,
    marks: std::cell::RefCell<Vec<(String, gtk::Image)>>,
}

impl Speakers {
    fn current(&self) -> String {
        output(Command::new(&self.at).arg("current"))
            .map(|t| t.trim().to_string())
            .unwrap_or_else(|| "off".into())
    }

    fn mark(&self, active: &str) {
        for (p, img) in self.marks.borrow().iter() {
            img.set_opacity(if p == active { 1.0 } else { 0.0 });
        }
    }

    fn stop(&self) {
        for m in self.playing.borrow_mut().drain(..) {
            m.pause();
        }
    }

    /// The clip (or pink noise) through a preset's EQ, written to the runtime dir.
    fn render_to(&self, eq: &audio_tune::eq::Eq, name: &str) -> Result<PathBuf, String> {
        let path = glib::user_runtime_dir().join(format!("ubuntu-ostrich-{name}.wav"));
        let clip = self.clip.borrow().clone();
        let music = clip
            .as_deref()
            .and_then(audio_tune::clips::path)
            .and_then(|p| audio_tune::clips::read_file(&p).ok());
        let bytes = match music {
            Some((frames, rate)) => {
                audio_tune::clips::wav_stereo(&render::render_stereo(eq, &frames, rate), rate)
            }
            None => {
                let noise = render::pink_noise(6.0, render::RATE, 1);
                render::wav(&render::render(eq, &noise, render::RATE), render::RATE)
            }
        };
        std::fs::write(&path, bytes).map_err(|e| format!("{}: {e}", path.display()))?;
        Ok(path)
    }

    /// Turns the tuning off for listening (once), remembering what to put back; then `then`.
    fn pause_tuning(self: &std::rc::Rc<Self>, then: impl FnOnce() + 'static) {
        if self.paused_from.borrow().is_some() {
            then();
            return;
        }
        let was = self.current();
        *self.paused_from.borrow_mut() = Some(was.clone());
        if was == "off" {
            then();
            return;
        }
        self.status.set_text(&format!(
            "Pausing your {} tuning while you listen…",
            preset_title(&was)
        ));
        let me = self.clone();
        run_async(&[&self.at, "off"], move |_| {
            me.status
                .set_text("Your tuning is paused while you listen; choose Use to keep one.");
            then();
        });
    }

    /// The tuning is chosen (or put back): nothing to restore any more.
    fn settle(&self, preset: &str) {
        *self.paused_from.borrow_mut() = None;
        self.mark(preset);
    }

    fn apply(self: &std::rc::Rc<Self>, preset: &str) {
        self.stop();
        let argv: Vec<String> = if preset == "off" {
            vec![self.at.clone(), "off".into()]
        } else {
            vec![self.at.clone(), "apply".into(), preset.into()]
        };
        self.status
            .set_text(&format!("Applying {}…", preset_title(preset)));
        let (me, p) = (self.clone(), preset.to_string());
        let refs: Vec<&str> = argv.iter().map(String::as_str).collect();
        run_async(&refs, move |ok| {
            if ok {
                me.status.set_text(&if p == "off" {
                    "Tuning is off: the speakers play as they are.".to_string()
                } else {
                    format!("{} is on.", preset_title(&p))
                });
                me.settle(&p);
            } else {
                me.status.set_text(&format!(
                    "Couldn't apply {}: is PipeWire running?",
                    preset_title(&p)
                ));
            }
        });
    }

    /// Plays one file, looping, from `at` (microseconds): one stream at a time, never two at once.
    /// It starts muted and is heard once it has seeked, so a switch doesn't blip from the start.
    fn play_at(&self, file: &std::path::Path, at: i64) -> gtk::MediaFile {
        self.stop();
        let m = gtk::MediaFile::for_filename(file);
        m.set_loop(true);
        if at > 0 {
            m.set_muted(true);
            m.connect_prepared_notify(move |m| {
                if m.is_prepared() {
                    m.seek(at);
                    m.set_muted(false);
                }
            });
        }
        m.play();
        *self.playing.borrow_mut() = vec![m.clone()];
        m
    }
}

fn speakers_step() -> Vec<adw::PreferencesGroup> {
    let g = group(
        "Speaker tuning",
        "Press ▶ to hear a preset, click a row to use it. Built-in speakers only: Bluetooth and HDMI audio aren't changed.",
    );
    let at = tool("ostrich-speakers").to_string_lossy().into_owned();
    let presets = output(Command::new(&at).arg("list"))
        .map(|t| {
            t.lines()
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if presets.is_empty() {
        missing(&g, "Speaker tuning (ostrich speakers)");
        return vec![g];
    }
    let clips: Vec<(String, String, String)> = output(Command::new(&at).arg("clips"))
        .map(|t| {
            t.lines()
                .filter_map(|l| {
                    let f: Vec<&str> = l.split('\t').collect();
                    (f.len() >= 4 && f[3] == "yes")
                        .then(|| (f[0].to_string(), f[1].to_string(), f[2].to_string()))
                })
                .collect()
        })
        .unwrap_or_default();
    let status = status_label();
    status.set_wrap(true);
    status.set_xalign(0.0);
    let sp = std::rc::Rc::new(Speakers {
        at: at.clone(),
        clip: std::cell::RefCell::new(clips.first().map(|c| c.0.clone())),
        clips,
        paused_from: Default::default(),
        playing: Default::default(),
        status: status.clone(),
        marks: Default::default(),
    });

    // What to listen with.
    let mut labels: Vec<String> = sp
        .clips
        .iter()
        .map(|(_, name, kind)| format!("{kind}: {name}"))
        .collect();
    labels.push(if sp.clips.is_empty() {
        "Pink noise (the music didn't download)".into()
    } else {
        "Pink noise".into()
    });
    let refs: Vec<&str> = labels.iter().map(String::as_str).collect();
    let chooser = {
        let r = adw::ComboRow::builder()
            .use_markup(false)
            .use_subtitle(true) // the chosen name has the whole row to itself instead of a clipped corner
            .model(&gtk::StringList::new(&refs))
            .build();
        r.set_title("Listen with");
        r
    };
    let s2 = sp.clone();
    chooser.connect_selected_notify(move |r| {
        let i = r.selected() as usize;
        *s2.clip.borrow_mut() = s2.clips.get(i).map(|c| c.0.clone());
        s2.stop();
    });
    g.add(&chooser);

    let current = sp.current();
    for p in presets.iter().map(String::as_str).chain(["off"]) {
        let about = if p == "off" {
            "Plain speakers, no equaliser"
        } else {
            PRESET_ABOUT
                .iter()
                .find(|(k, _)| *k == p)
                .map(|(_, v)| *v)
                .unwrap_or("")
        };
        let row = info_row(
            &if p == "off" {
                "Off".to_string()
            } else {
                preset_title(p)
            },
            about,
        );
        // One action per row: clicking it uses the preset; the ▶ in front only previews it.
        row.set_activatable(true);
        if p == "off" {
            let pad = gtk::Box::new(gtk::Orientation::Horizontal, 0);
            pad.set_width_request(34); // lines the label up with the rows that have a ▶
            row.add_prefix(&pad);
        } else {
            let preview = gtk::Button::from_icon_name("media-playback-start-symbolic");
            let label = format!("Preview {}", preset_title(p));
            preview.set_tooltip_text(Some(&label));
            preview.update_property(&[gtk::accessible::Property::Label(&label)]);
            preview.set_valign(gtk::Align::Center);
            preview.add_css_class("flat");
            let (s2, name) = (sp.clone(), p.to_string());
            preview.connect_clicked(move |_| {
                let Some(eq) = system::preset(&name) else {
                    return;
                };
                let (s3, name) = (s2.clone(), name.clone());
                s2.pause_tuning(move || match s3.render_to(&eq, "preview") {
                    Ok(f) => {
                        s3.play_at(&f, 0);
                        s3.status.set_text(&format!(
                            "Playing {} (press ▶ on another to compare).",
                            preset_title(&name)
                        ));
                    }
                    Err(e) => s3
                        .status
                        .set_text(&format!("Couldn't make the preview: {e}")),
                });
            });
            row.add_prefix(&preview);
        }
        let mark = gtk::Image::from_icon_name("object-select-symbolic");
        mark.set_opacity(if p == current { 1.0 } else { 0.0 });
        mark.set_tooltip_text(Some("On now"));
        row.add_suffix(&mark);
        sp.marks.borrow_mut().push((p.to_string(), mark));
        let (s2, name) = (sp.clone(), p.to_string());
        row.connect_activated(move |_| s2.apply(&name));
        g.add(&row);
    }
    let status_row = adw::ActionRow::builder()
        .use_markup(false)
        .activatable(false)
        .build();
    status_row.set_child(Some(&status));
    g.add(&status_row);

    // Leaving with the tuning paused: put back what was on.
    let s2 = sp.clone();
    on_close(move || {
        s2.stop();
        if let Some(was) = s2.paused_from.borrow_mut().take() {
            let argv: Vec<String> = if was == "off" {
                vec![]
            } else {
                vec![s2.at.clone(), "apply".into(), was]
            };
            if !argv.is_empty() {
                let _ = Command::new(&argv[0]).args(&argv[1..]).status();
            }
        }
    });
    vec![g, ab_group(sp)]
}

// ---- tune by ear: the A/B listening test ----

const GROUP_NAMES: [&str; 3] = ["the low end", "the mids", "the treble"];

struct Ab {
    sp: std::rc::Rc<Speakers>,
    test: std::cell::RefCell<abtest::AbTest>,
    media: std::cell::RefCell<Vec<gtk::MediaFile>>,
    /// The rendered A and B of the current comparison.
    files: std::cell::RefCell<Vec<PathBuf>>,
    heard: std::cell::Cell<[bool; 2]>,
    progress: gtk::ProgressBar,
    question: gtk::Label,
    side_a: gtk::ToggleButton,
    choices: Vec<gtk::Button>,
    finish: gtk::Box,
}

impl Ab {
    fn running(&self) -> bool {
        !self.media.borrow().is_empty()
    }

    /// A or B heard: the other version takes over at the same moment in the song.
    fn hear(&self, side: usize) {
        let at = self.media.borrow().first().map_or(0, |m| m.timestamp());
        let file = self.files.borrow().get(side).cloned();
        if let Some(f) = file {
            *self.media.borrow_mut() = vec![self.sp.play_at(&f, at)];
        }
        let mut h = self.heard.get();
        h[side] = true;
        self.heard.set(h);
        let both = h[0] && h[1];
        for c in &self.choices {
            c.set_sensitive(both);
        }
        if !both {
            self.question.set_text(&format!(
                "Now listen to {}.",
                if side == 0 { "B" } else { "A" }
            ));
        } else {
            self.question.set_text("Which sounds better?");
        }
    }

    fn next_pair(&self) -> Result<(), String> {
        let Some((a, b)) = self.test.borrow().pair() else {
            return Ok(());
        };
        let fa = self
            .sp
            .render_to(&audio_tune::eq::three_band("a", a[0], a[1], a[2]), "ab-a")?;
        let fb = self
            .sp
            .render_to(&audio_tune::eq::three_band("b", b[0], b[1], b[2]), "ab-b")?;
        *self.files.borrow_mut() = vec![fa, fb];
        self.media.borrow_mut().clear();
        self.heard.set([false, false]);
        self.side_a.set_active(true);
        self.hear(0);
        let t = self.test.borrow();
        let n = t.comparisons_made();
        let group = GROUP_NAMES[(n / (t.total_comparisons() / 3)).min(2)];
        self.progress
            .set_fraction(n as f64 / t.total_comparisons() as f64);
        self.progress.set_text(Some(&format!(
            "{} of {}: {group}",
            n + 1,
            t.total_comparisons()
        )));
        Ok(())
    }
}

fn answer(ab: &std::rc::Rc<Ab>, c: abtest::Choice) {
    ab.test.borrow_mut().answer(c);
    if !ab.test.borrow().done() {
        if let Err(e) = ab.next_pair() {
            ab.question
                .set_text(&format!("Couldn't make the next clips: {e}"));
        }
        return;
    }
    ab.sp.stop();
    ab.media.borrow_mut().clear();
    for c in &ab.choices {
        c.set_sensitive(false);
    }
    let g = ab.test.borrow().gains;
    ab.progress.set_fraction(1.0);
    ab.progress.set_text(Some("Done"));
    ab.question.set_text(&format!(
        "Your result: low end {:+.1} dB, mids {:+.1} dB, treble {:+.1} dB.",
        g[0], g[1], g[2]
    ));
    ab.finish.set_visible(true);
}

fn ab_group(sp: std::rc::Rc<Speakers>) -> adw::PreferencesGroup {
    let g = group(
        "Tune by ear",
        "Twelve quick comparisons, with the music chosen above: switch between A and B while it plays and pick the one you like. It starts with the low end, then the mids, then the treble, and the result becomes the Custom preset. Set a comfortable volume first.",
    );
    let side_a = gtk::ToggleButton::with_label("A");
    let side_b = gtk::ToggleButton::with_label("B");
    side_b.set_group(Some(&side_a));
    let sides = gtk::Box::builder()
        .css_classes(["linked"])
        .halign(gtk::Align::Center)
        .build();
    for b in [&side_a, &side_b] {
        b.set_size_request(96, 44);
        b.add_css_class("title-3");
        sides.append(b);
    }
    let question = gtk::Label::new(Some("Press Start; the music plays until you choose."));
    question.set_wrap(true);
    let progress = gtk::ProgressBar::builder().show_text(true).build();
    let choices_box = gtk::Box::builder().spacing(6).homogeneous(true).build();
    let choices: Vec<gtk::Button> = ["A is better", "B is better", "About the same"]
        .iter()
        .map(|l| gtk::Button::with_label(l))
        .collect();
    for c in &choices {
        c.set_sensitive(false);
        choices_box.append(c);
    }
    let start = gtk::Button::with_label("Start");
    start.add_css_class("suggested-action");
    start.add_css_class("pill");
    start.set_halign(gtk::Align::Center);
    let finish = gtk::Box::builder()
        .spacing(6)
        .halign(gtk::Align::Center)
        .visible(false)
        .build();
    let keep = gtk::Button::with_label("Keep it");
    keep.add_css_class("suggested-action");
    let again = gtk::Button::with_label("Try again");
    let back = gtk::Button::with_label("Go back to what I had");
    for b in [&keep, &again, &back] {
        finish.append(b);
    }
    let body = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .margin_top(12)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .build();
    for w in [
        start.upcast_ref::<gtk::Widget>(),
        sides.upcast_ref(),
        question.upcast_ref(),
        choices_box.upcast_ref(),
        progress.upcast_ref(),
        finish.upcast_ref(),
    ] {
        body.append(w);
    }
    let row = adw::ActionRow::builder()
        .use_markup(false)
        .activatable(false)
        .build();
    row.set_child(Some(&body));
    g.add(&row);

    let ab = std::rc::Rc::new(Ab {
        sp: sp.clone(),
        test: std::cell::RefCell::new(abtest::AbTest::new([0.0; 3], 6.0, 4, 9.0)),
        media: Default::default(),
        files: Default::default(),
        heard: Default::default(),
        progress,
        question,
        side_a: side_a.clone(),
        choices: choices.clone(),
        finish: finish.clone(),
    });
    let a = ab.clone();
    side_a.connect_toggled(move |b| {
        if b.is_active() && a.running() {
            a.hear(0);
        }
    });
    let a = ab.clone();
    side_b.connect_toggled(move |b| {
        if b.is_active() && a.running() {
            a.hear(1);
        }
    });
    for (i, c) in [abtest::Choice::A, abtest::Choice::B, abtest::Choice::Same]
        .into_iter()
        .enumerate()
    {
        let a = ab.clone();
        choices[i].connect_clicked(move |_| answer(&a, c));
    }
    let a = ab.clone();
    let begin = move || {
        *a.test.borrow_mut() = abtest::AbTest::new([0.0; 3], 6.0, 4, 9.0);
        a.finish.set_visible(false);
        let a2 = a.clone();
        a.sp.pause_tuning(move || {
            if let Err(e) = a2.next_pair() {
                a2.question
                    .set_text(&format!("Couldn't make the test clips: {e}"));
            }
        });
    };
    let b = begin.clone();
    start.connect_clicked(move |s| {
        s.set_label("Start over");
        b();
    });
    again.connect_clicked(move |_| begin());
    let s2 = sp.clone();
    keep.connect_clicked(move |_| {
        if let Err(e) = system::save_custom(ab.test.borrow().gains) {
            s2.status
                .set_text(&format!("Couldn't save the result: {e}"));
            return;
        }
        s2.apply("custom");
        ab.finish.set_visible(false);
    });
    let s2 = sp.clone();
    back.connect_clicked(move |b| {
        let was = s2
            .paused_from
            .borrow()
            .clone()
            .unwrap_or_else(|| "off".into());
        s2.apply(&was);
        if let Some(f) = b.parent() {
            f.set_visible(false);
        }
    });
    g
}

fn touchscreen_step() -> Vec<adw::PreferencesGroup> {
    let g = group(
        "Touchscreen",
        "Turn the touchscreen off when you don't use it: it saves a little power and stops accidental touches. The Touchscreen tile in the top-right menu turns it back on. The touchpad isn't affected.",
    );
    let current = output(Command::new(HELPER).args(["touchscreen", "status"]))
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    if current.is_empty() || current == "none" {
        missing(&g, "Touchscreen control (the system helper)");
        return vec![g];
    }
    choice_rows(
        &g,
        &[
            ("on", "On", "Touch works as usual"),
            (
                "off",
                "Off",
                "Stays off after restarts, until you turn it back on",
            ),
        ],
        if current == "on" { "on" } else { "off" },
        |v| {
            let mut a: Vec<String> = vec![
                "pkexec".into(),
                HELPER.into(),
                "touchscreen".into(),
                v.into(),
            ];
            if v == "off" {
                a.push("--persist".into());
            }
            a
        },
        |v| format!("The touchscreen is {v}."),
    );
    vec![g]
}

fn apps_step() -> Vec<adw::PreferencesGroup> {
    let store = group(
        "App store",
        "Tick the apps you want and press Install, or open the store to search everything on Flathub (and paste a GitHub link to install from there).",
    );
    let open_store = gtk::Button::with_label("Open the store");
    open_store.set_valign(gtk::Align::Center);
    // The page's main action stands out (note 20261102-015056): the accent fill.
    open_store.add_css_class("suggested-action");
    open_store.add_css_class("pill");
    open_store.connect_clicked(move |_| {
        let gui = glib::home_dir()
            .join(".local/libexec")
            .join(OURS)
            .join("ostrich-store-gtk");
        let _ = gio::Subprocess::newv(&[gui.as_os_str()], gio::SubprocessFlags::NONE);
    });
    let store_row = info_row(
        "Ostrich Store",
        "Search for apps, see screenshots and what they can access, install and update.",
    );
    store_row.add_suffix(&open_store);
    store.add(&store_row);
    let mut out = vec![store];
    let chosen: std::rc::Rc<std::cell::RefCell<Vec<String>>> = Default::default();
    for c in recommended() {
        let g = group(&c.name, "");
        for a in c.apps {
            if a.snap {
                // Not on Flathub, so not in the Install below: App Center has it.
                let row = info_row(&a.name, &a.about);
                let open = gtk::Button::with_label("App Center");
                open.set_valign(gtk::Align::Center);
                let page = a.page();
                open.connect_clicked(move |_| {
                    let _ =
                        gio::AppInfo::launch_default_for_uri(&page, None::<&gio::AppLaunchContext>);
                });
                row.add_suffix(&open);
                g.add(&row);
                continue;
            }
            let check = gtk::CheckButton::new();
            let row = {
                let r = adw::ActionRow::builder()
                    .use_markup(false)
                    .activatable_widget(&check)
                    .build();
                r.set_title(&a.name);
                r.set_subtitle(&a.about);
                r
            };
            row.add_prefix(&check);
            let (chosen, id) = (chosen.clone(), a.id.clone());
            check.connect_toggled(move |c| {
                let mut v = chosen.borrow_mut();
                v.retain(|x| x != &id);
                if c.is_active() {
                    v.push(id.clone());
                }
            });
            g.add(&row);
        }
        out.push(g);
    }
    let install = group("Install", "");
    let row = info_row(
        "Install the selected apps",
        "From Flathub; asks for your password once",
    );
    let status = status_label();
    let b = gtk::Button::with_label("Install");
    b.add_css_class("suggested-action");
    b.set_valign(gtk::Align::Center);
    let st = status.clone();
    b.connect_clicked(move |b| {
        let ids = chosen.borrow().clone();
        if ids.is_empty() {
            st.set_text("Tick at least one app first");
            return;
        }
        b.set_sensitive(false);
        st.set_text(&format!(
            "Installing {} app{}…",
            ids.len(),
            if ids.len() == 1 { "" } else { "s" }
        ));
        let mut argv = vec!["flatpak", "install", "-y", "--noninteractive", "flathub"];
        argv.extend(ids.iter().map(String::as_str));
        let (b, st) = (b.clone(), st.clone());
        run_async(&argv, move |ok| {
            b.set_sensitive(true);
            st.set_text(if ok {
                "Installed: they're in the app grid"
            } else {
                "Couldn't install (no internet, or the password was cancelled?)"
            });
        });
    });
    row.add_suffix(&status);
    row.add_suffix(&b);
    install.add(&row);
    out.push(install);
    out
}

fn finish_step() -> Vec<adw::PreferencesGroup> {
    let done = group(
        "You're all set",
        "You can close this window. Ostrich Settings is in the app grid whenever you want to change something.",
    );
    let g = group("Handy shortcuts", "The ones you'll use most.");
    let ds = ext_settings("drawer");
    let fs = ext_settings("focus");
    let ws = ext_settings("workspaces");
    for (title, accel) in [
        (
            "Ostrich Drawer",
            accel_of(ds.as_ref(), "toggle-drawer", "<Super><Alt>d"),
        ),
        (
            "Focus",
            accel_of(fs.as_ref(), "toggle-focus", "<Super><Alt>f"),
        ),
        (
            "New workspace",
            accel_of(ws.as_ref(), "new-workspace", "<Super><Alt>n"),
        ),
        ("Tile left / right", "<Super>Left <Super>Right".to_string()),
        ("Maximize / restore", "<Super>Up <Super>Down".to_string()),
        ("Your windows, then all apps", "<Super>".to_string()),
    ] {
        g.add(&shortcut_row(title, &accel));
    }
    vec![done, g]
}

// ---- window ----

/// The sidebar icon of each page.
fn step_icon(step: Step) -> &'static str {
    match step {
        Step::Welcome => "view-app-grid-symbolic",
        Step::Theme => "preferences-desktop-appearance-symbolic",
        Step::TopBar => "utilities-system-monitor-symbolic",
        Step::Dock => "view-grid-symbolic",
        Step::Windows => "view-dual-symbolic",
        Step::Blur => "weather-fog-symbolic",
        Step::Notifications => "preferences-system-notifications-symbolic",
        Step::Drawer => "web-browser-symbolic",
        Step::Focus => "weather-clear-night-symbolic",
        Step::Graphics => "video-display-symbolic",
        Step::Power => "battery-good-symbolic",
        Step::Speakers => "audio-speakers-symbolic",
        Step::Touchscreen => "input-touchpad-symbolic",
        Step::Apps => "system-software-install-symbolic",
        Step::Finish => "emblem-ok-symbolic",
    }
}

/// Ostrich Settings: a sidebar of every page and the chosen page beside it. On the first login it
/// runs as the tour (`tour`): Back, Next and Skip the tour at the bottom, and Finish at the end.
fn build(app: &adw::Application, only: Option<Step>, tour: bool) {
    let hw = Hardware::detect(std::path::Path::new("/"));
    // The tour ends on its "All set" page; as settings, that page isn't needed.
    let list: Vec<Step> = steps(&hw)
        .into_iter()
        .filter(|s| tour || *s != Step::Finish)
        .collect();
    // 170 ms: the shell's "standard" (_lib/motion.js); GtkStack cuts when gtk-enable-animations is off.
    let stack = gtk::Stack::builder()
        .transition_type(gtk::StackTransitionType::Crossfade)
        .transition_duration(170)
        .vexpand(true)
        .build();
    let mut index: Vec<Entry> = Vec::new();
    for (i, s) in list.iter().enumerate() {
        let p = page(*s, &hw);
        collect_rows(p.upcast_ref(), i, s.title(), &mut index);
        stack.add_titled(&p, Some(&i.to_string()), s.title());
    }

    // The sidebar.
    let sidebar = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::Single)
        .css_classes(["navigation-sidebar"])
        .build();
    for s in &list {
        let row = gtk::Box::builder()
            .spacing(12)
            .margin_start(6)
            .margin_end(6)
            .margin_top(6)
            .margin_bottom(6)
            .build();
        row.append(&gtk::Image::from_icon_name(step_icon(*s)));
        let label = gtk::Label::new(Some(s.title()));
        label.set_xalign(0.0);
        row.append(&label);
        sidebar.append(&row);
    }
    let side_toolbar = adw::ToolbarView::new();
    side_toolbar.add_top_bar(&adw::HeaderBar::new());
    let side_scroll = gtk::ScrolledWindow::builder()
        .child(&sidebar)
        .vexpand(true)
        .build();
    side_toolbar.set_content(Some(&side_scroll));
    let side_page = adw::NavigationPage::builder()
        .title("Ostrich Settings")
        .child(&side_toolbar)
        .build();

    // The page, with the tour's buttons at the bottom.
    let back = gtk::Button::with_label("Back");
    let next = gtk::Button::with_label("Next");
    next.add_css_class("suggested-action");
    let skip = gtk::Button::with_label("Skip the tour");
    skip.set_tooltip_text(Some("Go to the last page; everything stays as it is now"));
    let progress = gtk::Label::new(None);
    progress.add_css_class("dimmed");
    let bar = gtk::Box::builder()
        .spacing(6)
        .margin_top(6)
        .margin_bottom(6)
        .margin_start(12)
        .margin_end(12)
        .build();
    let spacer = gtk::Box::builder().hexpand(true).build();
    bar.append(&back);
    bar.append(&progress);
    bar.append(&spacer);
    bar.append(&skip);
    bar.append(&next);
    // Ctrl+F: a search bar over the pages; while there is a query, a list of matching rows replaces them.
    let search_entry = gtk::SearchEntry::builder()
        .hexpand(true)
        .placeholder_text("Search settings")
        .build();
    let search_bar = gtk::SearchBar::builder().child(&search_entry).build();
    search_bar.connect_entry(&search_entry);
    let results = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .css_classes(["boxed-list"])
        .margin_top(12)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .build();
    let results_scroll = gtk::ScrolledWindow::builder()
        .child(&results)
        .vexpand(true)
        .build();
    let no_results = adw::StatusPage::builder()
        .icon_name("edit-find-symbolic")
        .title("No matches")
        .description("Try another word.")
        .build();
    let results_stack = gtk::Stack::new();
    results_stack.add_named(&results_scroll, Some("list"));
    results_stack.add_named(&no_results, Some("none"));
    let content_stack = gtk::Stack::new();
    content_stack.add_named(&stack, Some("pages"));
    content_stack.add_named(&results_stack, Some("results"));
    let content_toolbar = adw::ToolbarView::new();
    content_toolbar.add_top_bar(&adw::HeaderBar::new());
    content_toolbar.add_top_bar(&search_bar);
    content_toolbar.set_content(Some(&content_stack));
    if tour {
        content_toolbar.add_bottom_bar(&bar);
    }
    let content_page = adw::NavigationPage::builder()
        .title(list[0].title())
        .child(&content_toolbar)
        .build();
    let split = adw::NavigationSplitView::builder()
        .sidebar(&side_page)
        .content(&content_page)
        .min_sidebar_width(220.0)
        .build();

    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("Ostrich Settings")
        .default_width(1000)
        .default_height(720)
        .content(&split)
        .build();
    window.connect_close_request(|_| {
        run_leave_hooks();
        glib::Propagation::Proceed
    });

    let pos = std::rc::Rc::new(std::cell::Cell::new(usize::MAX));
    let n = list.len();
    let show = {
        let side_scroll = side_scroll.clone();
        let content_stack = content_stack.clone();
        let (stack, content_page, sidebar, back, next, skip, progress, pos, list, split) = (
            stack.clone(),
            content_page.clone(),
            sidebar.clone(),
            back.clone(),
            next.clone(),
            skip.clone(),
            progress.clone(),
            pos.clone(),
            list.clone(),
            split.clone(),
        );
        move |i: usize| {
            if i == pos.get() {
                return;
            }
            if pos.get() != usize::MAX {
                run_leave_hooks();
            }
            pos.set(i);
            // A page picked from the sidebar, Back or Next replaces a search's results.
            content_stack.set_visible_child_name("pages");
            stack.set_visible_child_name(&i.to_string());
            content_page.set_title(list[i].title());
            if let Some(row) = sidebar.row_at_index(i as i32) {
                sidebar.select_row(Some(&row));
                // Keep it on screen: a short window shows only some of the sidebar.
                if let Some(b) = row.compute_bounds(&sidebar) {
                    let adj = side_scroll.vadjustment();
                    let (top, bottom) = (f64::from(b.y()), f64::from(b.y() + b.height()));
                    if top < adj.value() {
                        adj.set_value(top);
                    } else if bottom > adj.value() + adj.page_size() {
                        adj.set_value(bottom - adj.page_size());
                    }
                }
            }
            split.set_show_content(true);
            back.set_visible(i > 0);
            skip.set_visible(i + 1 < n);
            progress.set_text(&format!("{} of {n}", i + 1));
            next.set_label(if i + 1 == n { "Finish" } else { "Next" });
        }
    };
    let start = only
        .and_then(|o| list.iter().position(|s| *s == o))
        .unwrap_or(0);
    show(start);
    // Typing in the search bar: matching rows replace the pages; picking one opens its page.
    let index = std::rc::Rc::new(index);
    {
        let (results, content_stack, results_stack, search_bar, entry, show) = (
            results.clone(),
            content_stack.clone(),
            results_stack.clone(),
            search_bar.clone(),
            search_entry.clone(),
            show.clone(),
        );
        search_entry.connect_search_changed(move |e| {
            while let Some(r) = results.first_child() {
                results.remove(&r);
            }
            let query = e.text();
            if query.trim().is_empty() {
                content_stack.set_visible_child_name("pages");
                return;
            }
            let hits = search(&query, &index);
            content_stack.set_visible_child_name("results");
            results_stack.set_visible_child_name(if hits.is_empty() { "none" } else { "list" });
            for h in hits.into_iter().take(40) {
                let row = adw::ActionRow::builder()
                    .use_markup(false)
                    .activatable(true)
                    .title(h.title.as_str())
                    .subtitle(format!("{}: {}", h.page, h.subtitle))
                    .subtitle_lines(2)
                    .build();
                row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
                let (show, bar, entry, step) =
                    (show.clone(), search_bar.clone(), entry.clone(), h.step);
                row.connect_activated(move |_| {
                    entry.set_text("");
                    bar.set_search_mode(false);
                    show(step);
                });
                results.append(&row);
            }
        });
    }
    {
        let entry = search_entry.clone();
        search_bar.connect_search_mode_enabled_notify(move |b| {
            if !b.is_search_mode() {
                entry.set_text("");
            }
        });
    }
    let search_action = gio::SimpleAction::new("search", None);
    {
        let (bar, entry) = (search_bar.clone(), search_entry.clone());
        search_action.connect_activate(move |_, _| {
            bar.set_search_mode(true);
            entry.grab_focus();
        });
    }
    window.add_action(&search_action);
    app.set_accels_for_action("win.search", &["<Control>f"]);
    // win.goto("dock"): the page a later `--step` asks for (main's command line). A page this
    // window doesn't have (hidden hardware, "All set" outside the tour) leaves it where it is.
    let goto = gio::SimpleAction::new("goto", Some(glib::VariantTy::STRING));
    {
        let (s, list) = (show.clone(), list.clone());
        goto.connect_activate(move |_, v| {
            if let Some(i) = v
                .and_then(|v| v.str())
                .and_then(Step::from_id)
                .and_then(|o| list.iter().position(|s| *s == o))
            {
                s(i);
            }
        });
    }
    window.add_action(&goto);
    let s = show.clone();
    sidebar.connect_row_selected(move |_, row| {
        if let Some(r) = row {
            s(r.index() as usize);
        }
    });
    let s = show.clone();
    let p = pos.clone();
    back.connect_clicked(move |_| s(p.get().saturating_sub(1)));
    let s = show.clone();
    skip.connect_clicked(move |_| s(n - 1));
    let w = window.clone();
    next.connect_clicked(move |_| {
        if pos.get() + 1 < n {
            show(pos.get() + 1);
            return;
        }
        if let Err(e) = Paths::new(&glib::user_config_dir()).finish() {
            eprintln!("welcome: could not record that setup is done: {e}");
        }
        w.close();
    });
    window.present();
}

fn main() -> glib::ExitCode {
    let app = adw::Application::builder()
        .application_id(APP_ID)
        .flags(gio::ApplicationFlags::HANDLES_COMMAND_LINE)
        .build();
    // Our icon (modules/tools/icons) for windows the shell can't match to the desktop entry.
    app.connect_startup(|_| gtk::Window::set_default_icon_name("ostrich-settings"));
    app.connect_command_line(|app, cmd| {
        let args: Vec<String> = cmd
            .arguments()
            .iter()
            .skip(1)
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        let (only, force_tour) = match args.as_slice() {
            [] => (None, false),
            [flag] if flag == "--tour" => (None, true),
            [flag, name] if flag == "--step" => match Step::from_id(name) {
                Some(s) => (Some(s), false),
                None => {
                    eprintln!("welcome: no page {name:?}");
                    return glib::ExitCode::FAILURE;
                }
            },
            _ => {
                eprintln!("usage: ostrich-setup [--tour | --step NAME]");
                return glib::ExitCode::FAILURE;
            }
        };
        // The tour until it's been finished once (or when asked); settings after that.
        let tour =
            force_tour || (only.is_none() && !Paths::new(&glib::user_config_dir()).is_done());
        // One window: a second launch (the quick-settings and monitor buttons pass --step) goes to
        // that page in the open window instead of opening another (note 20261101-225220).
        match (app.active_window(), only) {
            (Some(w), Some(o)) => {
                let _ = w.activate_action("win.goto", Some(&o.id().to_variant()));
                w.present();
            }
            (Some(w), None) => w.present(),
            (None, _) => build(app, only, tour),
        }
        glib::ExitCode::SUCCESS
    });
    app.run()
}
