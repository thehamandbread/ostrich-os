//! ostrich theme: theme accents from the wallpaper (Ubuntu Ostrich).
//!
//!   ostrich theme [list] [--wallpaper PATH]          numbered swatches: wallpaper picks, then GNOME's accents
//!   ostrich theme apply <N | #rrggbb | NAME> [--wallpaper PATH] [--dry-run]
//!
//! `apply` writes, keeping everything outside its marked block:
//!   ~/.config/gtk-4.0/gtk.css, ~/.config/gtk-3.0/gtk.css   accent override
//!   ~/.config/ghostty/themes/ubuntu-ostrich        cursor/selection accent
//!   ~/.config/ubuntu-ostrich/palette.json           for the shell extensions
//! and sets org.gnome.desktop.interface accent-color to the nearest standard accent.
//!
//!   ostrich theme scheme [list] [--tsv]           the colour schemes (built in, then your own);
//!                                                 --tsv: id, name, accent, solid, text, yours, current
//!   ostrich theme scheme show ID                  a scheme's file
//!   ostrich theme scheme check ID|FILE            what's missing, and text under 4.5:1
//!   ostrich theme scheme apply ID [--dry-run]     its extension colours (live), accent, icon theme
//!                                                 and wallpaper
//!   ostrich theme scheme new ID [--from BASE]     your own, copied from BASE (default: the current
//!                                                 one) into ~/.config/ubuntu-ostrich/schemes/
//!   ostrich theme scheme delete ID                one of your own

mod color;
mod extract;
mod output;
mod scheme;

use color::{Lab, Rgb};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::{env, fs};

const MAX_WALLPAPER_ACCENTS: usize = 6;

fn gsettings_get(schema: &str, key: &str) -> Option<String> {
    let out = Command::new("gsettings")
        .args(["get", schema, key])
        .output()
        .ok()?;
    out.status.success().then(|| {
        String::from_utf8_lossy(&out.stdout)
            .trim()
            .trim_matches('\'')
            .to_string()
    })
}

/// file:///home/u/My%20Wall.jpg → /home/u/My Wall.jpg
fn uri_to_path(uri: &str) -> Option<PathBuf> {
    let rest = uri.strip_prefix("file://")?;
    let bytes = rest.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(v) = u8::from_str_radix(&rest[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    Some(PathBuf::from(String::from_utf8_lossy(&out).into_owned()))
}

fn current_wallpaper() -> Option<PathBuf> {
    let dark = gsettings_get("org.gnome.desktop.interface", "color-scheme").as_deref()
        == Some("prefer-dark");
    let key = if dark {
        "picture-uri-dark"
    } else {
        "picture-uri"
    };
    gsettings_get("org.gnome.desktop.background", key).and_then(|u| uri_to_path(&u))
}

fn open_image(path: &Path) -> Result<image::DynamicImage, String> {
    let jxl = path
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("jxl"));
    if jxl {
        let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
        let decoder = jxl_oxide::integration::JxlDecoder::new(std::io::BufReader::new(file))
            .map_err(|e| e.to_string())?;
        return image::DynamicImage::from_decoder(decoder).map_err(|e| e.to_string());
    }
    image::open(path).map_err(|e| e.to_string())
}

fn wallpaper_accents(path: &Path) -> Result<Vec<Rgb>, String> {
    let img = open_image(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    // 128 px is plenty for colour clusters and keeps this well under a second.
    let small = img.thumbnail(128, 128).to_rgb8();
    let samples: Vec<Lab> = small
        .pixels()
        .map(|p| Rgb::from_u8(p[0], p[1], p[2]).to_lab())
        .collect();
    let clusters = extract::kmeans(&samples, 12, 20);
    Ok(extract::accents(&clusters, MAX_WALLPAPER_ACCENTS))
}

/// All choices, numbered from 1: wallpaper picks first, then GNOME's accents.
fn choices(wallpaper: Option<&Path>) -> Vec<(String, Rgb)> {
    let mut list = Vec::new();
    if let Some(p) = wallpaper {
        match wallpaper_accents(p) {
            Ok(a) => list.extend(a.into_iter().map(|c| ("wallpaper".to_string(), c))),
            Err(e) => eprintln!("ostrich theme: {e}"),
        }
    }
    for (name, hex) in output::GNOME_ACCENTS {
        list.push((name.to_string(), Rgb::from_hex(hex).unwrap()));
    }
    list
}

/// A colour block on a terminal; nothing when the output goes to a file or a pipe, or NO_COLOR is set.
fn swatch(c: Rgb) -> String {
    use std::io::IsTerminal;
    if !std::io::stdout().is_terminal() || env::var_os("NO_COLOR").is_some() {
        return String::new();
    }
    let (r, g, b) = c.to_u8();
    format!("\x1b[48;2;{r};{g};{b}m      \x1b[0m")
}

fn config_dir() -> PathBuf {
    env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(".config"))
}

/// Writes `content` (or only reports it in a dry run). Backs up a file the first time it is changed.
fn write(path: &Path, content: &str, dry_run: bool) -> Result<(), String> {
    let existing = fs::read_to_string(path).unwrap_or_default();
    if existing == content {
        return Ok(());
    }
    if dry_run {
        println!("would write {}", path.display());
        return Ok(());
    }
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    if !existing.is_empty() && !existing.contains(output::BEGIN) {
        let backup = path.with_extension("css.before-palette");
        if !backup.exists() {
            fs::write(&backup, &existing).map_err(|e| format!("{}: {e}", backup.display()))?;
            println!("backed up {}", backup.display());
        }
    }
    fs::write(path, content).map_err(|e| format!("{}: {e}", path.display()))?;
    println!("wrote {}", path.display());
    Ok(())
}

/// Writes a file of ours (no backup: nobody else writes it), or reports it in a dry run.
fn put(path: &Path, content: &str, dry_run: bool) -> Result<(), String> {
    if fs::read_to_string(path).ok().as_deref() == Some(content) {
        return Ok(());
    }
    if dry_run {
        println!("would write {}", path.display());
        return Ok(());
    }
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    fs::write(path, content).map_err(|e| format!("{}: {e}", path.display()))
}

fn apply(
    accent: Rgb,
    candidates: &[Rgb],
    wallpaper: Option<&Path>,
    dry_run: bool,
) -> Result<(), String> {
    let cfg = config_dir();
    for (dir, css) in [
        ("gtk-4.0", output::gtk4_css(accent)),
        ("gtk-3.0", output::gtk3_css(accent)),
    ] {
        let path = cfg.join(dir).join("gtk.css");
        let merged = output::merge_block(&fs::read_to_string(&path).unwrap_or_default(), &css);
        write(&path, &merged, dry_run)?;
    }
    put(
        &cfg.join("ghostty/themes/ubuntu-ostrich"),
        &output::ghostty_theme(accent),
        dry_run,
    )?;
    let wp = wallpaper
        .map(|p| p.display().to_string())
        .unwrap_or_default();
    put(
        &cfg.join("ubuntu-ostrich/palette.json"),
        &output::palette_json(accent, candidates, &wp),
        dry_run,
    )?;

    let name = output::nearest_gnome_accent(accent);
    if gsettings_get("org.gnome.desktop.interface", "accent-color").as_deref() != Some(name) {
        if dry_run {
            println!("would set accent-color to {name}");
        } else {
            let ok = Command::new("gsettings")
                .args(["set", "org.gnome.desktop.interface", "accent-color", name])
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if !ok {
                return Err("could not set accent-color".into());
            }
            println!("set accent-color to {name}");
        }
    }
    Ok(())
}

fn data_dir() -> PathBuf {
    env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(".local/share")
        })
}

/// /home/u/My Wall.svg → file:///home/u/My%20Wall.svg
fn path_to_uri(p: &Path) -> String {
    let mut out = String::from("file://");
    for b in p.to_string_lossy().bytes() {
        if b.is_ascii_alphanumeric() || b"/-._~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Sets a string gsetting when it differs (or says so in a dry run).
fn gs_set(schema: &str, key: &str, value: &str, dry_run: bool) -> Result<(), String> {
    if gsettings_get(schema, key).as_deref() == Some(value) {
        return Ok(());
    }
    if dry_run {
        println!("would set {key} to {value}");
        return Ok(());
    }
    let ok = Command::new("gsettings")
        .args(["set", schema, key, value])
        .status()
        .is_ok_and(|s| s.success());
    if !ok {
        return Err(format!("could not set {key}"));
    }
    println!("set {key} to {value}");
    Ok(())
}

fn scheme_dir() -> PathBuf {
    config_dir().join("ubuntu-ostrich/scheme")
}

fn current_scheme() -> Option<String> {
    fs::read_to_string(scheme_dir().join("current"))
        .ok()
        .map(|s| s.trim().to_string())
}

/// What a scheme changes outside its own files, saved before the first one is applied, so Classic
/// (a scheme with no desktop part) can put it back: these settings, and these files as they were.
const BEFORE_SETTINGS: [(&str, &str); 4] = [
    ("org.gnome.desktop.interface", "accent-color"),
    ("org.gnome.desktop.interface", "icon-theme"),
    ("org.gnome.desktop.background", "picture-uri"),
    ("org.gnome.desktop.background", "picture-uri-dark"),
];

fn before_files() -> [(&'static str, PathBuf); 4] {
    let cfg = config_dir();
    [
        ("gtk4.css", cfg.join("gtk-4.0/gtk.css")),
        ("gtk3.css", cfg.join("gtk-3.0/gtk.css")),
        ("ghostty", cfg.join("ghostty/themes/ubuntu-ostrich")),
        ("palette.json", cfg.join("ubuntu-ostrich/palette.json")),
    ]
}

fn remember_before(dry_run: bool) -> Result<(), String> {
    let dir = scheme_dir().join("before");
    if dir.exists() || dry_run {
        return Ok(());
    }
    fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let settings: String = BEFORE_SETTINGS
        .iter()
        .filter_map(|(schema, key)| {
            gsettings_get(schema, key).map(|v| format!("{schema}\t{key}\t{v}\n"))
        })
        .collect();
    fs::write(dir.join("settings"), settings).map_err(|e| e.to_string())?;
    for (name, path) in before_files() {
        if path.exists() {
            fs::copy(&path, dir.join(name)).map_err(|e| format!("{}: {e}", path.display()))?;
        }
    }
    Ok(())
}

/// Classic: everything a scheme changed goes back to how it was before the first one.
fn restore_before(dry_run: bool) -> Result<(), String> {
    let dir = scheme_dir().join("before");
    let Ok(settings) = fs::read_to_string(dir.join("settings")) else {
        return Ok(()); // no scheme was applied since the last Classic
    };
    for line in settings.lines() {
        if let [schema, key, value] = line.splitn(3, '\t').collect::<Vec<_>>().as_slice() {
            if BEFORE_SETTINGS.contains(&(*schema, *key)) {
                gs_set(schema, key, value, dry_run)?;
            }
        }
    }
    for (name, path) in before_files() {
        let saved = dir.join(name);
        if dry_run {
            println!("would put back {}", path.display());
        } else if name.ends_with(".css") {
            // gtk.css is shared with the user: only our block goes back to how it was.
            let now = fs::read_to_string(&path).unwrap_or_default();
            let old = fs::read_to_string(&saved).unwrap_or_default();
            let back = match output::our_block(&old) {
                Some(block) => output::merge_block(&now, block),
                None => output::strip_block(&now),
            };
            if back.trim().is_empty() && !saved.exists() {
                let _ = fs::remove_file(&path);
            } else if back != now {
                fs::write(&path, back).map_err(|e| format!("{}: {e}", path.display()))?;
            }
        } else if saved.exists() {
            fs::copy(&saved, &path).map_err(|e| format!("{}: {e}", path.display()))?;
        } else {
            let _ = fs::remove_file(&path);
        }
    }
    if !dry_run {
        fs::remove_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    Ok(())
}

fn apply_scheme(s: &scheme::Scheme, dry_run: bool) -> Result<(), String> {
    let (errors, warnings) = scheme::check(s);
    if !errors.is_empty() {
        return Err(format!(
            "{} can't be applied: {}",
            s.name(),
            errors.join("; ")
        ));
    }
    for w in &warnings {
        eprintln!("ostrich theme: warning: {w}");
    }
    let desktop = ["ui_accent", "icon_theme", "wallpaper", "wall_top"]
        .iter()
        .any(|k| s.get(k).is_some());
    if desktop {
        remember_before(dry_run)?;
    } else {
        restore_before(dry_run)?;
    }
    // The extensions watch these and reload them: the tmp-and-rename keeps them from reading half.
    let dir = scheme_dir();
    for (ext, template) in scheme::TEMPLATES {
        let path = dir.join(format!("{ext}.css"));
        if fs::read_to_string(&path).ok().as_deref() == Some(scheme::fill(template, s).as_str()) {
            continue;
        }
        if dry_run {
            println!("would write {}", path.display());
            continue;
        }
        fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        let tmp = dir.join(format!(".{ext}.css.new"));
        fs::write(&tmp, scheme::fill(template, s))
            .map_err(|e| format!("{}: {e}", tmp.display()))?;
        fs::rename(&tmp, &path).map_err(|e| format!("{}: {e}", path.display()))?;
    }
    // The wallpaper: drawn from the scheme's colours, or the pictures it names (if installed).
    let mut walls: Vec<(&str, PathBuf)> = Vec::new();
    if let Some((dark, light)) = scheme::wallpaper_svgs(s) {
        let out = data_dir().join("backgrounds/ubuntu-ostrich");
        let (d, l) = (
            out.join(format!("{}.svg", s.id)),
            out.join(format!("{}-light.svg", s.id)),
        );
        put(&d, &dark, dry_run)?;
        put(&l, &light, dry_run)?;
        walls = vec![("picture-uri", l), ("picture-uri-dark", d)];
    } else if let Some(w) = s.get("wallpaper") {
        let dark = s.get("wallpaper_dark").unwrap_or(w);
        for (key, file) in [("picture-uri", w), ("picture-uri-dark", dark)] {
            if Path::new(file).is_file() {
                walls.push((key, PathBuf::from(file)));
            } else {
                eprintln!("ostrich theme: {file} isn't installed; keeping that wallpaper");
            }
        }
    }
    for (key, file) in &walls {
        gs_set(
            "org.gnome.desktop.background",
            key,
            &path_to_uri(file),
            dry_run,
        )?;
    }
    if let Some(theme) = s.get("icon_theme") {
        let dark = gsettings_get("org.gnome.desktop.interface", "color-scheme").as_deref()
            == Some("prefer-dark");
        let theme = if dark {
            format!("{theme}-dark")
        } else {
            theme.to_string()
        };
        gs_set("org.gnome.desktop.interface", "icon-theme", &theme, dry_run)?;
    }
    if let Some(accent) = s.get("ui_accent").and_then(Rgb::from_hex) {
        let wp = walls.first().map(|(_, p)| p.as_path());
        apply(accent, &[], wp, dry_run)?;
    }
    put(&dir.join("current"), &format!("{}\n", s.id), dry_run)?;
    if !dry_run {
        println!("applied {}", s.name());
    }
    Ok(())
}

fn scheme_main(args: &[String], dry_run: bool) -> ExitCode {
    let cfg = config_dir();
    let all = scheme::all(&cfg);
    let find = |id: &str| all.iter().find(|s| s.id == id);
    let fail = |e: String| {
        eprintln!("ostrich theme: {e}");
        ExitCode::FAILURE
    };
    let id = args.get(1).map(String::as_str);
    match (args.first().map(String::as_str), id) {
        (None | Some("list"), _) => {
            let current = current_scheme();
            if args.iter().any(|a| a == "--tsv") {
                for s in &all {
                    let cur = current.as_deref() == Some(s.id.as_str());
                    println!(
                        "{}\t{}\t{}\t{}\t{}\t{}\t{}",
                        s.id,
                        s.name().replace(['\t', '\n'], " "),
                        s.get("ui_accent").unwrap_or(""),
                        s.get("solid").unwrap_or(""),
                        s.get("text").unwrap_or(""),
                        !s.built_in,
                        cur
                    );
                }
                return ExitCode::SUCCESS;
            }
            for s in &all {
                let mark = if current.as_deref() == Some(s.id.as_str()) {
                    "*"
                } else {
                    " "
                };
                let accent = s
                    .get("ui_accent")
                    .and_then(Rgb::from_hex)
                    .map(swatch)
                    .unwrap_or_else(|| "      ".into());
                let own = if s.built_in { "" } else { "  (yours)" };
                println!("{mark} {accent}  {:<16} {}{own}", s.id, s.name());
            }
            ExitCode::SUCCESS
        }
        (Some("show"), Some(id)) => match find(id) {
            Some(s) => {
                print!("{}", scheme::to_text(&s.values));
                ExitCode::SUCCESS
            }
            None => fail(format!("no scheme called {id}")),
        },
        (Some("check"), Some(id)) => match find(id)
            .map(|s| (s.id.clone(), s.values.clone()))
            .or_else(|| {
                // A file (the Settings editor's draft): checked, not listed.
                id.contains('/')
                    .then(|| fs::read_to_string(id).ok())
                    .flatten()
                    .map(|t| ("draft".to_string(), scheme::parse(&t)))
            }) {
            Some((sid, values)) => {
                let s = &scheme::Scheme {
                    id: sid,
                    built_in: false,
                    values,
                };
                let (errors, warnings) = scheme::check(s);
                for e in &errors {
                    println!("error: {e}");
                }
                for w in &warnings {
                    println!("warning: {w}");
                }
                if errors.is_empty() && warnings.is_empty() {
                    println!("{}: complete, and its text reads 4.5:1 or better", s.name());
                }
                if errors.is_empty() {
                    ExitCode::SUCCESS
                } else {
                    ExitCode::FAILURE
                }
            }
            None => fail(format!("no scheme called {id}")),
        },
        (Some("apply"), Some(id)) => match find(id) {
            Some(s) => match apply_scheme(s, dry_run) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => fail(e),
            },
            None => fail(format!("no scheme called {id}")),
        },
        (Some("new"), Some(id)) => {
            if !scheme::valid_id(id) {
                return fail(format!("{id}: use letters, digits and '-' only"));
            }
            let path = scheme::user_dir(&cfg).join(format!("{id}.toml"));
            if path.exists() {
                return fail(format!("{} exists already", path.display()));
            }
            let base = args
                .iter()
                .position(|a| a == "--from")
                .and_then(|i| args.get(i + 1).cloned())
                .or_else(current_scheme)
                .unwrap_or_else(|| "classic".into());
            let Some(b) = find(&base) else {
                return fail(format!("no scheme called {base}"));
            };
            let mut values = b.values.clone();
            values.insert("name".into(), id.to_string());
            match write(&path, &scheme::to_text(&values), dry_run) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => fail(e),
            }
        }
        (Some("delete"), Some(id)) => match find(id) {
            Some(s) if !s.built_in => {
                let path = scheme::user_dir(&cfg).join(format!("{id}.toml"));
                match fs::remove_file(&path) {
                    Ok(()) => {
                        println!("deleted {}", path.display());
                        ExitCode::SUCCESS
                    }
                    Err(e) => fail(format!("{}: {e}", path.display())),
                }
            }
            Some(_) => fail(format!("{id} is built in")),
            None => fail(format!("no scheme called {id}")),
        },
        _ => usage(),
    }
}

const USAGE: &str = "usage: ostrich theme [list] [--wallpaper PATH]\n       ostrich theme apply <N | #rrggbb | NAME> [--wallpaper PATH] [--dry-run]\n       ostrich theme scheme [list | show ID | check ID | apply ID | new ID [--from BASE] | delete ID]";

fn usage() -> ExitCode {
    eprintln!("{USAGE}");
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let mut args: Vec<String> = env::args().skip(1).collect();
    if matches!(
        args.first().map(String::as_str),
        Some("-h" | "--help" | "help")
    ) {
        println!("{USAGE}");
        return ExitCode::SUCCESS;
    }
    let dry_run = args.iter().any(|a| a == "--dry-run");
    args.retain(|a| a != "--dry-run");
    if args.first().map(String::as_str) == Some("scheme") {
        return scheme_main(&args[1..], dry_run);
    }
    let mut wallpaper: Option<PathBuf> = None;
    if let Some(i) = args.iter().position(|a| a == "--wallpaper") {
        if i + 1 >= args.len() {
            return usage();
        }
        wallpaper = Some(PathBuf::from(args.remove(i + 1)));
        args.remove(i);
    }
    let wallpaper = wallpaper.or_else(current_wallpaper);
    let list = choices(wallpaper.as_deref());

    match args.first().map(String::as_str) {
        None | Some("list") => {
            match &wallpaper {
                Some(p) => println!("Wallpaper: {}", p.display()),
                None => println!("Wallpaper: (none found)"),
            }
            for (i, (source, c)) in list.iter().enumerate() {
                println!("{:>3}  {}  {}  {}", i + 1, swatch(*c), c.hex(), source);
            }
            println!("\nApply one with: ostrich theme apply <number>");
            ExitCode::SUCCESS
        }
        Some("apply") => {
            let Some(choice) = args.get(1) else {
                return usage();
            };
            let accent = if let Ok(n) = choice.parse::<usize>() {
                list.get(n.wrapping_sub(1)).map(|(_, c)| *c)
            } else if choice.starts_with('#') {
                Rgb::from_hex(choice)
            } else {
                list.iter().find(|(s, _)| s == choice).map(|(_, c)| *c)
            };
            let Some(accent) = accent else {
                eprintln!("ostrich theme: no such choice: {choice}");
                return ExitCode::from(2);
            };
            let candidates: Vec<Rgb> = list
                .iter()
                .filter(|(s, _)| s == "wallpaper")
                .map(|(_, c)| *c)
                .collect();
            match apply(accent, &candidates, wallpaper.as_deref(), dry_run) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    eprintln!("ostrich theme: {e}");
                    ExitCode::FAILURE
                }
            }
        }
        _ => usage(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Forest, then Classic, against a fake gsettings (a flat "schema key value" file) in a temporary
    /// home: Classic puts the accent and the GTK file back as they were.
    #[test]
    fn classic_undoes_a_scheme() {
        use std::os::unix::fs::PermissionsExt;
        let root = env::temp_dir().join(format!("ost-scheme-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let bin = root.join("bin");
        fs::create_dir_all(&bin).unwrap();
        let db = root.join("gsettings.db");
        fs::write(
            &db,
            "org.gnome.desktop.interface accent-color teal\norg.gnome.desktop.interface icon-theme Yaru\norg.gnome.desktop.interface color-scheme default\norg.gnome.desktop.background picture-uri file:///a.png\norg.gnome.desktop.background picture-uri-dark file:///a.png\n",
        )
        .unwrap();
        let fake = bin.join("gsettings");
        fs::write(
            &fake,
            format!(
                "#!/bin/sh\ndb={}\ncase $1 in\nget) v=$(grep -m1 \"^$2 $3 \" \"$db\" | cut -d' ' -f3-); [ -n \"$v\" ] && echo \"'$v'\" ;;\nset) grep -v \"^$2 $3 \" \"$db\" >\"$db.n\"; echo \"$2 $3 $4\" >>\"$db.n\"; mv \"$db.n\" \"$db\" ;;\nesac\n",
                db.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
        env::set_var(
            "PATH",
            format!("{}:{}", bin.display(), env::var("PATH").unwrap_or_default()),
        );
        env::set_var("XDG_CONFIG_HOME", root.join("config"));
        env::set_var("XDG_DATA_HOME", root.join("data"));
        let gtk = root.join("config/gtk-4.0/gtk.css");
        fs::create_dir_all(gtk.parent().unwrap()).unwrap();
        fs::write(&gtk, "mine { }\n").unwrap();
        let ghostty = root.join("config/ghostty/themes/ubuntu-ostrich");
        fs::create_dir_all(ghostty.parent().unwrap()).unwrap();
        fs::write(&ghostty, "from an earlier ostrich theme apply\n").unwrap();

        let all = scheme::all(&config_dir());
        let pick = |id: &str| all.iter().find(|s| s.id == id).unwrap();
        apply_scheme(pick("forest"), false).unwrap();
        assert_eq!(
            gsettings_get("org.gnome.desktop.interface", "accent-color").as_deref(),
            Some("green")
        );
        assert!(fs::read_to_string(&gtk).unwrap().contains(output::BEGIN));
        assert!(scheme_dir().join("blur.css").exists());
        apply_scheme(pick("night-glass"), false).unwrap(); // a second scheme keeps the first "before"
        let gtk3 = root.join("config/gtk-3.0/gtk.css");
        let with_mine = format!("{}added later {{ }}\n", fs::read_to_string(&gtk).unwrap());
        fs::write(&gtk, with_mine).unwrap(); // written after the first scheme: Classic must keep it
        apply_scheme(pick("classic"), false).unwrap();
        assert!(!gtk3.exists()); // created by the scheme, nothing of the user's in it
        assert_eq!(
            gsettings_get("org.gnome.desktop.interface", "accent-color").as_deref(),
            Some("teal")
        );
        assert_eq!(
            gsettings_get("org.gnome.desktop.background", "picture-uri").as_deref(),
            Some("file:///a.png")
        );
        assert_eq!(
            fs::read_to_string(&gtk).unwrap(),
            "mine { }\nadded later { }\n"
        );
        assert!(!scheme_dir().join("before").exists());
        // Our own files are never "backed up" as if they were the user's.
        assert!(!ghostty.with_extension("css.before-palette").exists());
        assert!(!root
            .join("config/ubuntu-ostrich/palette.css.before-palette")
            .exists());
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn uri_decoding() {
        assert_eq!(
            uri_to_path("file:///home/u/My%20Wall.jpg").unwrap(),
            PathBuf::from("/home/u/My Wall.jpg")
        );
        assert!(uri_to_path("https://x/y.png").is_none());
        let p = Path::new("/home/u/My Wall's.svg");
        assert_eq!(uri_to_path(&path_to_uri(p)).unwrap(), p);
    }
}
