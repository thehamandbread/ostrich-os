//! The colour scheme picker (wizard and Ostrich Settings, Theme) and the editor for your own: both
//! go through `ostrich-theme scheme`, which checks and applies them; the shell follows at once.

use crate::{group, missing, output, run_async, status_label, tool};
use adw::prelude::*;
use gtk::{gdk, gio, glib};
use std::collections::BTreeMap;
use std::process::Command;
use std::rc::Rc;
use welcome::{parse_schemes, SchemeEntry};

fn theme_tool() -> String {
    tool("ostrich-theme").to_string_lossy().into_owned()
}

struct Picker {
    flow: gtk::FlowBox,
    status: gtk::Label,
    css: gtk::CssProvider,
}

pub fn scheme_group() -> adw::PreferencesGroup {
    let g = group(
        "Colour scheme",
        "The glass, accent, folders and wallpaper, together. It changes at once; yours are at the end.",
    );
    let css = gtk::CssProvider::new();
    if let Some(d) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &d,
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
    let p = Rc::new(Picker {
        flow: gtk::FlowBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .homogeneous(true)
            .min_children_per_line(2)
            .max_children_per_line(4)
            .column_spacing(8)
            .row_spacing(8)
            .margin_top(6)
            .margin_bottom(6)
            .build(),
        status: status_label(),
        css,
    });
    if !fill(&p) {
        missing(&g, "The theme tool (ostrich theme)");
        return g;
    }
    let new = gtk::Button::with_label("New scheme…");
    new.set_tooltip_text(Some("Start your own from the current scheme"));
    new.set_valign(gtk::Align::Center);
    let p2 = p.clone();
    new.connect_clicked(move |b| {
        let current = list()
            .into_iter()
            .find(|e| e.current)
            .map(|e| e.id)
            .unwrap_or_else(|| "classic".into());
        editor(b, &current, p2.clone());
    });
    let suffix = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    suffix.append(&p.status);
    suffix.append(&new);
    g.set_header_suffix(Some(&suffix));
    g.add(&p.flow);
    g
}

fn list() -> Vec<SchemeEntry> {
    output(Command::new(theme_tool()).args(["scheme", "list", "--tsv"]))
        .map(|t| parse_schemes(&t))
        .unwrap_or_default()
}

/// (Re)builds the cards; false when the tool lists nothing.
fn fill(p: &Rc<Picker>) -> bool {
    let schemes = list();
    p.flow.remove_all();
    // Colours are #rrggbb or empty (parse_schemes), so they're safe in CSS.
    let css: String = schemes
        .iter()
        .map(|e| {
            let or = |c: &str, d: &str| if c.is_empty() { d.to_string() } else { c.to_string() };
            format!(
                ".ost-scheme-{id} {{ background: {solid}; border-radius: 12px; min-height: 56px; }}\n\
                 .ost-scheme-{id} .ost-scheme-dot {{ background: {accent}; min-width: 18px; min-height: 18px; border-radius: 9px; }}\n\
                 .ost-scheme-{id} .ost-scheme-aa {{ color: {text}; font-weight: bold; }}\n",
                id = e.id,
                solid = or(&e.solid, "#1d1d20"),
                accent = or(&e.accent, "alpha(white, 0.25)"),
                text = or(&e.text, "#ffffff"),
            )
        })
        .collect();
    p.css.load_from_string(&css);
    for e in &schemes {
        let swatch = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .css_classes([format!("ost-scheme-{}", e.id)])
            .build();
        let inner = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        inner.set_margin_start(12);
        inner.set_valign(gtk::Align::Center);
        let dot = gtk::Box::builder()
            .css_classes(["ost-scheme-dot"])
            .valign(gtk::Align::Center)
            .build();
        let aa = gtk::Label::builder()
            .label("Aa")
            .css_classes(["ost-scheme-aa"])
            .build();
        inner.append(&dot);
        inner.append(&aa);
        swatch.append(&inner);
        let name = gtk::Label::builder()
            .label(&e.name)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        row.set_halign(gtk::Align::Center);
        if e.current {
            row.append(&gtk::Image::from_icon_name("object-select-symbolic"));
        }
        row.append(&name);
        // The swatch is the button that applies it; your own also get a menu by their name.
        let b = gtk::Button::builder()
            .child(&swatch)
            .css_classes(["flat"])
            .build();
        let what = if e.current {
            "the current scheme"
        } else {
            "apply it"
        };
        b.set_tooltip_text(Some(&format!("{}: {what}", e.name)));
        b.update_property(&[gtk::accessible::Property::Label(&format!(
            "{}{}",
            e.name,
            if e.current { ", current" } else { "" }
        ))]);
        let (p2, id) = (p.clone(), e.id.clone());
        b.connect_clicked(move |_| {
            p2.status.set_text("applying…");
            let p3 = p2.clone();
            run_async(&[&theme_tool(), "scheme", "apply", &id], move |ok| {
                p3.status
                    .set_text(if ok { "applied" } else { "couldn't apply it" });
                fill(&p3);
            });
        });
        let card = gtk::Box::new(gtk::Orientation::Vertical, 6);
        card.append(&b);
        card.append(&row);
        if e.own {
            let menu = gio::Menu::new();
            menu.append(Some("Edit…"), Some("scheme.edit"));
            menu.append(Some("Delete"), Some("scheme.delete"));
            let actions = gio::SimpleActionGroup::new();
            let (edit, delete) = (
                gio::SimpleAction::new("edit", None),
                gio::SimpleAction::new("delete", None),
            );
            let (p2, id, cw) = (p.clone(), e.id.clone(), card.downgrade());
            edit.connect_activate(move |_, _| {
                if let Some(c) = cw.upgrade() {
                    editor(&c, &id, p2.clone());
                }
            });
            let (p2, id) = (p.clone(), e.id.clone());
            delete.connect_activate(move |_, _| {
                let p3 = p2.clone();
                run_async(&[&theme_tool(), "scheme", "delete", &id], move |_| {
                    fill(&p3);
                });
            });
            actions.add_action(&edit);
            actions.add_action(&delete);
            card.insert_action_group("scheme", Some(&actions));
            let more = gtk::MenuButton::builder()
                .icon_name("view-more-symbolic")
                .menu_model(&menu)
                .css_classes(["flat", "circular"])
                .tooltip_text(format!("Edit or delete {}", e.name))
                .build();
            row.append(&more);
        }
        p.flow.insert(&card, -1);
    }
    !schemes.is_empty()
}

fn rgba(v: &str) -> Option<gdk::RGBA> {
    gdk::RGBA::parse(v).ok()
}

fn hex(c: &gdk::RGBA) -> String {
    let b = |x: f32| (x.clamp(0.0, 1.0) * 255.0).round() as u8;
    format!("#{:02x}{:02x}{:02x}", b(c.red()), b(c.green()), b(c.blue()))
}

fn rgba_text(c: &gdk::RGBA, alpha: f64) -> String {
    let b = |x: f32| (x.clamp(0.0, 1.0) * 255.0).round() as u8;
    format!(
        "rgba({}, {}, {}, {})",
        b(c.red()),
        b(c.green()),
        b(c.blue()),
        (alpha.clamp(0.0, 1.0) * 100.0).round() / 100.0
    )
}

/// "My Theme 2" → "my-theme-2"
fn slug(name: &str) -> String {
    let s: String = name
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    s.split('-')
        .filter(|w| !w.is_empty())
        .collect::<Vec<_>>()
        .join("-")
}

fn schemes_dir() -> std::path::PathBuf {
    glib::user_config_dir().join("ostrich-os/schemes")
}

/// The editor: a few colours you choose; the rest of the scheme follows from them (the glass tints
/// from one colour and a strength), and the tool checks it as you go.
fn editor(near: &impl IsA<gtk::Widget>, base: &str, picker: Rc<Picker>) {
    let Some(values) = output(Command::new(theme_tool()).args(["scheme", "show", base]))
        .and_then(|t| toml::from_str::<BTreeMap<String, String>>(&t).ok())
    else {
        picker.status.set_text("couldn't read that scheme");
        return;
    };
    let editing_own = list().into_iter().any(|e| e.id == base && e.own);
    let values = Rc::new(std::cell::RefCell::new(values));
    let get = |k: &str| values.borrow().get(k).cloned().unwrap_or_default();

    let page = adw::PreferencesPage::new();
    let about = adw::PreferencesGroup::new();
    let name = adw::EntryRow::builder().title("Name").build();
    name.set_text(&if editing_own {
        get("name")
    } else {
        format!("My {}", get("name"))
    });
    about.add(&name);
    page.add(&about);

    let colours = adw::PreferencesGroup::builder()
        .title("Colours")
        .description(
            "The glass tints come from one colour and a strength; keep it light so the blur shows.",
        )
        .build();
    let colour_row = |title: &str, subtitle: &str, value: &str| {
        let row = adw::ActionRow::builder()
            .title(title)
            .subtitle(subtitle)
            .build();
        let button = gtk::ColorDialogButton::new(Some(
            gtk::ColorDialog::builder().with_alpha(false).build(),
        ));
        button.set_valign(gtk::Align::Center);
        // The colour only: how see-through the glass is comes from its strength.
        if let Some(c) = rgba(value) {
            button.set_rgba(&gdk::RGBA::new(c.red(), c.green(), c.blue(), 1.0));
        }
        row.add_suffix(&button);
        colours.add(&row);
        button
    };
    let accent = colour_row(
        "Accent",
        "Buttons, switches and selections in apps",
        &get("ui_accent"),
    );
    let tint = colour_row(
        "Glass",
        "The tint over the blur, dark style",
        &get("glass_bar"),
    );
    let strength = adw::SpinRow::with_range(0.0, 0.6, 0.02);
    strength.set_title("Glass strength");
    strength.set_subtitle("How much tint: higher is darker and less see-through");
    strength.set_digits(2);
    strength.set_value(
        rgba(&get("glass_bar"))
            .map(|c| c.alpha() as f64)
            .unwrap_or(0.14),
    );
    colours.add(&strength);
    let text = colour_row("Text on dark glass", "", &get("text"));
    let light = colour_row(
        "Light glass",
        "Menus in the light style",
        &get("light_glass_menu"),
    );
    let light_text = colour_row("Text on light glass", "", &get("light_text"));
    let solid = colour_row(
        "Solid surfaces",
        "Where there's no blur (the lock screen, previews)",
        &get("solid"),
    );
    page.add(&colours);

    let desk = adw::PreferencesGroup::builder().title("Desktop").build();
    let wall = adw::ActionRow::builder().title("Wallpaper").build();
    let wall_path = Rc::new(std::cell::RefCell::new(None::<String>));
    wall.set_subtitle(
        &match (get("wallpaper").is_empty(), get("wall_top").is_empty()) {
            (false, _) => get("wallpaper"),
            (true, false) => "Drawn from the scheme's colours".to_string(),
            _ => "Unchanged".to_string(),
        },
    );
    let choose = gtk::Button::with_label("Choose…");
    choose.set_valign(gtk::Align::Center);
    let (ww, wp) = (wall.downgrade(), wall_path.clone());
    choose.connect_clicked(move |b| {
        let filter = gtk::FileFilter::new();
        filter.add_pixbuf_formats();
        filter.set_name(Some("Pictures"));
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        let dialog = gtk::FileDialog::builder()
            .title("Wallpaper")
            .filters(&filters)
            .build();
        let (ww, wp) = (ww.clone(), wp.clone());
        let win = b.root().and_downcast::<gtk::Window>();
        dialog.open(win.as_ref(), None::<&gio::Cancellable>, move |r| {
            if let Some(path) = r.ok().and_then(|f| f.path()) {
                let p = path.to_string_lossy().into_owned();
                if let Some(w) = ww.upgrade() {
                    w.set_subtitle(&p);
                }
                *wp.borrow_mut() = Some(p);
            }
        });
    });
    wall.add_suffix(&choose);
    desk.add(&wall);
    // Ubuntu's Yaru folder colours (each has a -dark twin, picked with the style).
    let mut themes: Vec<String> = std::fs::read_dir("/usr/share/icons")
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| n.starts_with("Yaru") && !n.ends_with("-dark"))
        .collect();
    themes.sort();
    let keep = get("icon_theme");
    if !keep.is_empty() && !themes.contains(&keep) {
        themes.insert(0, keep.clone());
    }
    let icons = adw::ComboRow::builder()
        .title("Folder colours")
        .subtitle("Ubuntu's icon theme")
        .model(&gtk::StringList::new(
            &themes.iter().map(String::as_str).collect::<Vec<_>>(),
        ))
        .build();
    if let Some(i) = themes.iter().position(|t| *t == keep) {
        icons.set_selected(i as u32);
    }
    if !themes.is_empty() {
        desk.add(&icons);
    }
    page.add(&desk);

    let check = adw::PreferencesGroup::new();
    let warnings = gtk::Label::builder().wrap(true).xalign(0.0).build();
    check.add(&warnings);
    page.add(&check);

    // The scheme as chosen: the base's values with the editor's on top.
    let collect = {
        let (
            values,
            name,
            accent,
            tint,
            strength,
            text,
            light,
            light_text,
            solid,
            icons,
            wall_path,
        ) = (
            values.clone(),
            name.clone(),
            accent.clone(),
            tint.clone(),
            strength.clone(),
            text.clone(),
            light.clone(),
            light_text.clone(),
            solid.clone(),
            icons.clone(),
            wall_path.clone(),
        );
        let themes = themes.clone();
        move || {
            let mut v = values.borrow().clone();
            v.insert("name".into(), name.text().trim().to_string());
            v.insert("ui_accent".into(), hex(&accent.rgba()));
            let (t, a) = (tint.rgba(), strength.value());
            v.insert("glass_bar".into(), rgba_text(&t, a));
            v.insert("glass_menu".into(), rgba_text(&t, a * 0.86));
            v.insert("glass_banner".into(), rgba_text(&t, a * 1.14));
            v.insert("glass_folder".into(), rgba_text(&t, (a * 1.7).min(0.95)));
            v.insert("text".into(), hex(&text.rgba()));
            let l = light.rgba();
            v.insert("light_glass_menu".into(), rgba_text(&l, 0.62));
            v.insert("light_glass_banner".into(), rgba_text(&l, 0.66));
            v.insert("light_glass_folder".into(), rgba_text(&l, 0.4));
            v.insert("light_text".into(), hex(&light_text.rgba()));
            let s = solid.rgba();
            v.insert("solid".into(), hex(&s));
            v.insert("popup_solid".into(), rgba_text(&s, 0.92));
            if let Some(t) = themes.get(icons.selected() as usize) {
                v.insert("icon_theme".into(), t.clone());
            }
            if let Some(p) = wall_path.borrow().clone() {
                v.retain(|k, _| !k.starts_with("wall_") && k != "wallpaper_dark");
                v.insert("wallpaper".into(), p);
            }
            v
        }
    };
    let collect = Rc::new(collect);
    // Checked as you go: the draft file goes through the same check `apply` makes.
    let recheck = {
        let (collect, warnings) = (collect.clone(), warnings.clone());
        move || {
            let draft = schemes_dir().join(".draft.toml");
            let _ = std::fs::create_dir_all(schemes_dir());
            let text = toml::to_string(&collect()).unwrap_or_default();
            let out = std::fs::write(&draft, text)
                .ok()
                .and_then(|_| {
                    Command::new(theme_tool())
                        .args(["scheme", "check"])
                        .arg(&draft)
                        .output()
                        .ok()
                })
                .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
                .unwrap_or_default();
            let _ = std::fs::remove_file(&draft);
            let problems: Vec<&str> = out
                .lines()
                .filter(|l| l.starts_with("warning") || l.starts_with("error"))
                .collect();
            if problems.is_empty() {
                warnings.set_text("All text reads 4.5:1 or better.");
                warnings.remove_css_class("warning");
            } else {
                warnings.set_text(&format!("Hard to read:\n{}", problems.join("\n")));
                warnings.add_css_class("warning");
            }
        }
    };
    let recheck = Rc::new(recheck);
    for b in [&accent, &tint, &text, &light, &light_text, &solid] {
        let r = recheck.clone();
        b.connect_rgba_notify(move |_| r());
    }
    let r = recheck.clone();
    strength.connect_value_notify(move |_| r());
    recheck();

    let dialog = adw::Dialog::builder()
        .title(if editing_own {
            "Edit scheme"
        } else {
            "New scheme"
        })
        .content_width(520)
        .content_height(680)
        .build();
    let header = adw::HeaderBar::new();
    let save = gtk::Button::with_label("Save and apply");
    save.add_css_class("suggested-action");
    header.pack_end(&save);
    let view = adw::ToolbarView::new();
    view.add_top_bar(&header);
    view.set_content(Some(&page));
    dialog.set_child(Some(&view));
    let (dw, base, note) = (dialog.downgrade(), base.to_string(), warnings.clone());
    save.connect_clicked(move |_| {
        let v = collect();
        // Your own keep their file when edited; a new one gets one named after it.
        let id = if editing_own { base.clone() } else { slug(v.get("name").map(String::as_str).unwrap_or("")) };
        if id.is_empty() {
            note.set_text("Give it a name first.");
            note.add_css_class("warning");
            return;
        }
        let path = schemes_dir().join(format!("{id}.toml"));
        if !editing_own && path.exists() {
            note.set_text("You have a scheme with that name already: give this one another name.");
            note.add_css_class("warning");
            return;
        }
        let text = format!(
            "# Your Ostrich OS colour scheme (Ostrich Settings > Theme; `ostrich theme scheme`).\n{}",
            toml::to_string(&v).unwrap_or_default()
        );
        if std::fs::create_dir_all(schemes_dir()).and_then(|_| std::fs::write(&path, text)).is_err() {
            picker.status.set_text("couldn't save it");
            return;
        }
        picker.status.set_text("applying…");
        let p = picker.clone();
        run_async(&[&theme_tool(), "scheme", "apply", &id], move |ok| {
            p.status.set_text(if ok { "applied" } else { "saved, but it couldn't be applied" });
            fill(&p);
        });
        if let Some(d) = dw.upgrade() {
            d.close();
        }
    });
    dialog.present(Some(near));
}
