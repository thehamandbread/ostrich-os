//! The welcome wizard's model (DESIGN.md: welcome). Pure (no GTK), unit-tested: hardware
//! detection, which steps apply, the recommended-apps list and the "done" bookkeeping.

use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};

/// What the machine has, for hiding steps that don't apply. Read from sysfs/udev under `root`
/// (`/` normally; a fixture directory in tests).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Hardware {
    pub hybrid_graphics: bool,
    pub touchscreen: bool,
    pub battery: bool,
    pub sound: bool,
}

fn read(path: &Path) -> String {
    fs::read_to_string(path)
        .unwrap_or_default()
        .trim()
        .to_string()
}

fn entries(dir: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = fs::read_dir(dir)
        .map(|it| it.flatten().map(|e| e.path()).collect())
        .unwrap_or_default();
    v.sort();
    v
}

impl Hardware {
    pub fn detect(root: &Path) -> Hardware {
        // Display controllers are PCI class 0x03xxxx; hybrid = NVIDIA plus an Intel or AMD GPU.
        let vendors: Vec<String> = entries(&root.join("sys/bus/pci/devices"))
            .into_iter()
            .filter(|d| read(&d.join("class")).starts_with("0x03"))
            .map(|d| read(&d.join("vendor")))
            .collect();
        let nvidia = vendors.iter().any(|v| v == "0x10de");
        let other = vendors.iter().any(|v| v == "0x8086" || v == "0x1002");
        Hardware {
            hybrid_graphics: nvidia && other,
            touchscreen: entries(&root.join("run/udev/data"))
                .iter()
                .any(|f| read(f).lines().any(|l| l == "E:ID_INPUT_TOUCHSCREEN=1")),
            battery: entries(&root.join("sys/class/power_supply"))
                .iter()
                .any(|d| read(&d.join("type")) == "Battery"),
            sound: entries(&root.join("proc/asound")).iter().any(|d| {
                d.file_name()
                    .is_some_and(|n| n.to_string_lossy().starts_with("card"))
            }),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Step {
    Welcome,
    Theme,
    TopBar,
    Dock,
    Windows,
    Blur,
    Notifications,
    Drawer,
    Focus,
    Graphics,
    Power,
    Speakers,
    Touchscreen,
    Apps,
    Finish,
}

pub const ALL: [Step; 15] = [
    Step::Welcome,
    Step::Theme,
    Step::TopBar,
    Step::Dock,
    Step::Windows,
    Step::Blur,
    Step::Notifications,
    Step::Drawer,
    Step::Focus,
    Step::Graphics,
    Step::Power,
    Step::Speakers,
    Step::Touchscreen,
    Step::Apps,
    Step::Finish,
];

impl Step {
    /// Name for `--step NAME` (run one step on its own).
    pub fn id(self) -> &'static str {
        match self {
            Step::Welcome => "welcome",
            Step::Theme => "theme",
            Step::TopBar => "top-bar",
            Step::Dock => "dock",
            Step::Windows => "windows",
            Step::Blur => "blur",
            Step::Notifications => "notifications",
            Step::Drawer => "drawer",
            Step::Focus => "focus",
            Step::Graphics => "graphics",
            Step::Power => "power",
            Step::Speakers => "speakers",
            Step::Touchscreen => "touchscreen",
            Step::Apps => "apps",
            Step::Finish => "finish",
        }
    }

    pub fn from_id(id: &str) -> Option<Step> {
        ALL.into_iter().find(|s| s.id() == id)
    }

    pub fn title(self) -> &'static str {
        match self {
            Step::Welcome => "What's included",
            Step::Theme => "Theme",
            Step::TopBar => "Top bar",
            Step::Dock => "Dock",
            Step::Windows => "Workspaces and tiling",
            Step::Blur => "Blur",
            Step::Notifications => "Notifications",
            Step::Drawer => "Ostrich Drawer",
            Step::Focus => "Focus mode",
            Step::Graphics => "Graphics",
            Step::Power => "Power",
            Step::Speakers => "Speakers",
            Step::Touchscreen => "Touchscreen",
            Step::Apps => "Apps",
            Step::Finish => "All set",
        }
    }

    pub fn applies(self, hw: &Hardware) -> bool {
        match self {
            Step::Graphics => hw.hybrid_graphics,
            Step::Touchscreen => hw.touchscreen,
            Step::Speakers => hw.sound,
            _ => true,
        }
    }
}

/// The steps for this machine, in order.
pub fn steps(hw: &Hardware) -> Vec<Step> {
    ALL.into_iter().filter(|s| s.applies(hw)).collect()
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct App {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub about: String,
    /// A snap, not a Flathub app (`id` is its snap name): App Center installs it, from `page()`.
    #[serde(default)]
    pub snap: bool,
}

impl App {
    /// App Center's page for a snap.
    pub fn page(&self) -> String {
        format!("snap://{}", self.id)
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Category {
    pub name: String,
    pub apps: Vec<App>,
}

#[derive(Deserialize)]
struct Recommended {
    category: Vec<Category>,
}

pub fn recommended() -> Vec<Category> {
    parse_recommended(include_str!("../data/recommended.toml")).unwrap_or_default()
}

pub fn parse_recommended(text: &str) -> Result<Vec<Category>, String> {
    let r: Recommended = toml::from_str(text).map_err(|e| e.to_string())?;
    for a in r.category.iter().flat_map(|c| &c.apps) {
        // Reverse-DNS ids only: they go on a flatpak command line. Snap names go in a snap:// link.
        let ok = if a.snap {
            !a.id.is_empty()
                && a.id
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        } else {
            a.id.split('.').count() >= 3
                && a.id
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
        };
        if !ok {
            return Err(format!("not a Flathub app id or snap name: {:?}", a.id));
        }
    }
    Ok(r.category)
}

/// One colour from `palette list`: its number (for `palette apply N`), hex and source.
#[derive(Clone, Debug, PartialEq)]
pub struct Swatch {
    pub number: usize,
    pub hex: String,
    pub source: String,
}

/// Parses `palette list` lines like "  3  <ansi block>  #3584e4  blue".
pub fn parse_palette_list(text: &str) -> Vec<Swatch> {
    text.lines()
        .filter_map(|l| {
            let mut words = l.split_whitespace();
            let number = words.next()?.parse().ok()?;
            let rest: Vec<&str> = words.collect();
            let at = rest.iter().position(|w| {
                w.len() == 7 && w.starts_with('#') && w[1..].chars().all(|c| c.is_ascii_hexdigit())
            })?;
            Some(Swatch {
                number,
                hex: rest[at].to_string(),
                source: rest[at + 1..].join(" "),
            })
        })
        .collect()
}

/// A colour scheme, from `ostrich-theme scheme list --tsv`.
#[derive(Clone, Debug, PartialEq)]
pub struct SchemeEntry {
    pub id: String,
    pub name: String,
    /// #rrggbb, or empty (the scheme keeps your accent).
    pub accent: String,
    pub solid: String,
    pub text: String,
    pub own: bool,
    pub current: bool,
}

/// Parses `scheme list --tsv` (id, name, accent, solid, text, yours, current); colours that aren't
/// #rrggbb become empty, so they can go into CSS as they are.
pub fn parse_schemes(text: &str) -> Vec<SchemeEntry> {
    let hex = |v: &str| {
        let ok =
            v.len() == 7 && v.starts_with('#') && v[1..].chars().all(|c| c.is_ascii_hexdigit());
        if ok {
            v.to_string()
        } else {
            String::new()
        }
    };
    text.lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            let [id, name, accent, solid, text, own, current] = f.as_slice() else {
                return None;
            };
            Some(SchemeEntry {
                id: id.to_string(),
                name: name.to_string(),
                accent: hex(accent),
                solid: hex(solid),
                text: hex(text),
                own: *own == "true",
                current: *current == "true",
            })
        })
        .filter(|e| !e.id.is_empty() && e.id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'))
        .collect()
}

/// A site in Ostrich Drawer, from `ostrich-drawer --list` ("id\tname\turl\tpinned" lines; the
/// pinned column is "pinned" or empty, and older drawers leave it out).
#[derive(Clone, Debug, PartialEq)]
pub struct Site {
    pub id: String,
    pub name: String,
    pub url: String,
    pub pinned: bool,
    /// Kept loaded in the background (5th column "kept").
    pub kept: bool,
}

pub fn parse_drawer_list(text: &str) -> Vec<Site> {
    text.lines()
        .filter_map(|l| {
            let mut f = l.split('\t');
            let (id, name, url) = (f.next()?, f.next()?, f.next()?);
            let pinned = f.next().is_none_or(|p| p == "pinned");
            let kept = f.next() == Some("kept");
            (!id.is_empty()).then(|| Site {
                id: id.into(),
                name: name.into(),
                url: url.into(),
                pinned,
                kept,
            })
        })
        .collect()
}

/// A recommended site, from `ostrich-drawer --recommended` ("id\tname\turl\tgroup\tshape\tstatus").
#[derive(Clone, Debug, PartialEq)]
pub struct RecommendedSite {
    pub id: String,
    pub name: String,
    pub url: String,
    pub group: String,
    /// Needs DRM video, which the drawer can't play: opened elsewhere.
    pub drm: bool,
    /// For a DRM site: opened in its own app (else in the browser).
    pub app: bool,
}

pub const RECOMMENDED_GROUPS: [(&str, &str); 4] = [
    ("messaging", "Messaging"),
    ("ai", "AI"),
    ("mail", "Mail & calendar"),
    ("media", "Media & notes"),
];

pub fn parse_recommended_sites(text: &str) -> Vec<RecommendedSite> {
    text.lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            let [id, name, url, group, _shape, status] = f.as_slice() else {
                return None;
            };
            Some(RecommendedSite {
                id: id.to_string(),
                name: name.to_string(),
                url: url.to_string(),
                group: group.to_string(),
                drm: status.starts_with("drm"),
                app: *status == "drm-app",
            })
        })
        .collect()
}

/// An environment file's name and how many apps it opens.
pub fn env_summary(json: &str) -> Option<(String, usize)> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let name = v.get("name")?.as_str()?.to_string();
    let apps = v
        .get("apps")
        .and_then(|a| a.as_array())
        .map_or(0, |a| a.len());
    Some((name, apps))
}

/// An environment file's name and drawer sites (None: it uses the normal drawer sites).
pub fn env_drawer(json: &str) -> Option<(String, Option<Vec<String>>)> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let name = v.get("name")?.as_str()?.to_string();
    let sites = v
        .get("drawer")
        .and_then(|d| d.get("sites"))
        .and_then(|s| s.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(String::from))
                .collect()
        });
    Some((name, sites))
}

/// Where the wizard keeps state and how it autostarts.
pub struct Paths {
    pub config: PathBuf,
    pub autostart: PathBuf,
}

impl Paths {
    pub fn new(config_home: &Path) -> Paths {
        Paths {
            config: config_home.join("ostrich-os/welcome-done"),
            autostart: config_home.join("autostart/ostrich-setup.desktop"),
        }
    }

    pub fn is_done(&self) -> bool {
        self.config.exists()
    }

    /// Finishing: remember it and stop autostarting. Reopening from the app grid still works.
    pub fn finish(&self) -> std::io::Result<()> {
        if let Some(dir) = self.config.parent() {
            fs::create_dir_all(dir)?;
        }
        fs::write(&self.config, "done\n")?;
        match fs::remove_file(&self.autostart) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
            _ => Ok(()),
        }
    }
}

/// The monitor's top-bar pins with `id` switched on (added at the end, or left where it is) or off.
pub fn set_pin(pins: &[String], id: &str, on: bool) -> Vec<String> {
    let has = pins.iter().any(|p| p == id);
    match (on, has) {
        (true, false) => pins.iter().cloned().chain([id.to_string()]).collect(),
        (false, true) => pins.iter().filter(|p| *p != id).cloned().collect(),
        _ => pins.to_vec(),
    }
}

/// One searchable row of the settings pages (Ctrl+F in Ostrich Settings).
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    /// Index of its page in the sidebar.
    pub step: usize,
    pub page: String,
    pub title: String,
    pub subtitle: String,
}

/// The entries that match every word of the query, ignoring case, in the row's title or subtitle; rows
/// whose title matches come first, each group in page order. A page whose name matches but none of whose
/// rows do gives one entry that opens the page (a search for "speakers" lists the page, not every row on it).
pub fn search(query: &str, entries: &[Entry]) -> Vec<Entry> {
    let words: Vec<String> = query.split_whitespace().map(str::to_lowercase).collect();
    if words.is_empty() {
        return Vec::new();
    }
    let has = |text: &str| words.iter().all(|w| text.contains(w.as_str()));
    let mut hits: Vec<(bool, Entry)> = Vec::new();
    for e in entries {
        let title = e.title.to_lowercase();
        if has(&format!("{title} {}", e.subtitle.to_lowercase())) {
            hits.push((has(&title), e.clone()));
        }
    }
    let mut seen: Vec<usize> = Vec::new();
    for e in entries {
        if seen.contains(&e.step) {
            continue;
        }
        seen.push(e.step);
        if !hits.iter().any(|(_, h)| h.step == e.step) && has(&e.page.to_lowercase()) {
            hits.push((
                true,
                Entry {
                    step: e.step,
                    page: e.page.clone(),
                    title: e.page.clone(),
                    subtitle: "Open this page".into(),
                },
            ));
        }
    }
    hits.sort_by_key(|(in_title, _)| !*in_title); // stable: page order inside each group
    hits.into_iter().map(|(_, e)| e).collect()
}

#[cfg(test)]
mod tests {
    #[test]
    fn pins_switch_on_at_the_end_and_off_in_place() {
        let p = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(set_pin(&p(&["a", "b"]), "c", true), p(&["a", "b", "c"]));
        assert_eq!(set_pin(&p(&["a", "b"]), "a", true), p(&["a", "b"]));
        assert_eq!(set_pin(&p(&["a", "b", "c"]), "b", false), p(&["a", "c"]));
        assert_eq!(set_pin(&p(&["a"]), "z", false), p(&["a"]));
    }

    use super::*;

    fn fixture(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("ost-welcome-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        root
    }

    fn put(root: &Path, rel: &str, text: &str) {
        let p = root.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
    }

    #[test]
    fn detects_a_hybrid_laptop_with_touchscreen() {
        let r = fixture("laptop");
        put(&r, "sys/bus/pci/devices/0000:00:02.0/class", "0x030000\n");
        put(&r, "sys/bus/pci/devices/0000:00:02.0/vendor", "0x8086\n");
        put(&r, "sys/bus/pci/devices/0000:01:00.0/class", "0x030200\n");
        put(&r, "sys/bus/pci/devices/0000:01:00.0/vendor", "0x10de\n");
        put(&r, "sys/bus/pci/devices/0000:00:1f.3/class", "0x040380\n");
        put(&r, "sys/bus/pci/devices/0000:00:1f.3/vendor", "0x10de\n");
        put(
            &r,
            "run/udev/data/c13:70",
            "E:ID_INPUT=1\nE:ID_INPUT_TOUCHSCREEN=1\n",
        );
        put(&r, "sys/class/power_supply/BAT0/type", "Battery\n");
        put(&r, "proc/asound/card0/id", "sofhdadsp\n");
        let hw = Hardware::detect(&r);
        assert_eq!(
            hw,
            Hardware {
                hybrid_graphics: true,
                touchscreen: true,
                battery: true,
                sound: true
            }
        );
        assert_eq!(steps(&hw).len(), ALL.len());
    }

    #[test]
    fn a_plain_desktop_hides_the_hardware_steps() {
        let r = fixture("desktop");
        put(&r, "sys/bus/pci/devices/0000:00:02.0/class", "0x030000\n");
        put(&r, "sys/bus/pci/devices/0000:00:02.0/vendor", "0x8086\n");
        put(&r, "sys/class/power_supply/AC/type", "Mains\n");
        put(&r, "run/udev/data/c13:64", "E:ID_INPUT_TOUCHPAD=1\n");
        let hw = Hardware::detect(&r);
        assert_eq!(hw, Hardware::default());
        let s = steps(&hw);
        assert!(!s.contains(&Step::Graphics) && !s.contains(&Step::Touchscreen));
        assert!(!s.contains(&Step::Speakers));
        assert_eq!(s.first(), Some(&Step::Welcome));
        assert_eq!(s.last(), Some(&Step::Finish));
    }

    #[test]
    fn nvidia_only_is_not_hybrid() {
        let r = fixture("nvonly");
        put(&r, "sys/bus/pci/devices/0000:01:00.0/class", "0x030000\n");
        put(&r, "sys/bus/pci/devices/0000:01:00.0/vendor", "0x10de\n");
        assert!(!Hardware::detect(&r).hybrid_graphics);
    }

    #[test]
    fn step_ids_round_trip() {
        for s in ALL {
            assert_eq!(Step::from_id(s.id()), Some(s));
        }
        assert_eq!(Step::from_id("nope"), None);
    }

    #[test]
    fn recommended_list_parses_and_ids_are_checked() {
        let r = recommended();
        assert!(!r.is_empty() && r.iter().all(|c| !c.apps.is_empty()));
        assert!(parse_recommended(
            "[[category]]\nname = \"x\"\napps = [{ id = \"rm -rf\", name = \"bad\" }]\n"
        )
        .is_err());
        assert!(parse_recommended(
            "[[category]]\nname = \"x\"\napps = [{ id = \"a/b\", name = \"bad\", snap = true }]\n"
        )
        .is_err());
        // Media: Spotify (the verified snap, from App Center) first, then a Flathub music player.
        let media = &r.iter().find(|c| c.name == "Media").unwrap().apps;
        assert!(media[0].snap && media[0].page() == "snap://spotify");
        assert!(media.iter().skip(1).all(|a| !a.snap));
    }

    #[test]
    fn parses_scheme_list() {
        let s = parse_schemes("classic\tClassic\t\t#1d1d20\t#ffffff\tfalse\tfalse\nmine\tMy theme\t#4e7d5b\t#1a221c\tred;}\ttrue\ttrue\n../x\tBad\t\t\t\tfalse\tfalse\nshort\n");
        assert_eq!(s.len(), 2);
        assert_eq!(s[0].accent, "");
        assert!(s[1].own && s[1].current && s[1].name == "My theme");
        assert_eq!(s[1].text, ""); // not a colour: never put into CSS
    }

    #[test]
    fn parses_palette_list_output() {
        let out = "Wallpaper: /x.jpg\n  1  \u{1b}[48;2;53;132;228m  \u{1b}[0m  #3584e4  wallpaper\n  2  \u{1b}[48;2;1;2;3m  \u{1b}[0m  #010203  blue\n\nApply one with: palette apply <number>\n";
        let s = parse_palette_list(out);
        assert_eq!(s.len(), 2);
        assert_eq!(
            s[0],
            Swatch {
                number: 1,
                hex: "#3584e4".into(),
                source: "wallpaper".into()
            }
        );
        assert_eq!(s[1].source, "blue");
    }

    #[test]
    fn parses_drawer_list() {
        let s = parse_drawer_list("chat\tGoogle Chat\thttps://chat.google.com\nbad line\n\nyt\tYouTube\thttps://www.youtube.com\n");
        assert_eq!(s.len(), 2);
        assert_eq!(s[0].name, "Google Chat");
        assert_eq!(s[1].url, "https://www.youtube.com");
        assert!(s[0].pinned, "no pinned column: pinned");
        let s = parse_drawer_list("a\tA\thttps://a.com\tpinned\tkept\nb\tB\thttps://b.com\t\t\n");
        assert!(s[0].pinned && !s[1].pinned);
        assert!(s[0].kept && !s[1].kept);
    }

    #[test]
    fn parses_recommended_and_env_drawers() {
        let r = parse_recommended_sites(
            "whatsapp\tWhatsApp\thttps://web.whatsapp.com\tmessaging\tnarrow\tok\nspotify\tSpotify\thttps://open.spotify.com\tmedia\twide\tdrm-app\nbad\n",
        );
        assert_eq!(r.len(), 2);
        assert!(!r[0].drm && r[1].drm && r[1].app && r[0].group == "messaging");
        assert!(RECOMMENDED_GROUPS.iter().any(|(g, _)| *g == r[1].group));
        let (name, sites) =
            env_drawer(r#"{"name":"School","drawer":{"sites":["claude","gmail"],"keep":[]}}"#)
                .unwrap();
        assert_eq!((name.as_str(), sites.unwrap().len()), ("School", 2));
        assert_eq!(env_drawer(r#"{"name":"X","drawer":null}"#).unwrap().1, None);
        assert!(env_drawer("not json").is_none());
        assert_eq!(
            env_summary(r#"{"name":"School","apps":[{"app":"a.desktop"},{"app":"b.desktop"}]}"#),
            Some(("School".into(), 2))
        );
    }

    #[test]
    fn finishing_removes_the_autostart_entry() {
        let r = fixture("finish");
        let p = Paths::new(&r);
        put(&r, "autostart/ostrich-setup.desktop", "[Desktop Entry]\n");
        assert!(!p.is_done());
        p.finish().unwrap();
        assert!(p.is_done() && !p.autostart.exists());
        p.finish().unwrap(); // again: fine
    }

    fn entry(step: usize, page: &str, title: &str, subtitle: &str) -> Entry {
        Entry {
            step,
            page: page.into(),
            title: title.into(),
            subtitle: subtitle.into(),
        }
    }

    #[test]
    fn search_finds_words_in_title_or_subtitle_ignoring_case() {
        let e = vec![
            entry(1, "Theme", "Dark style", "Dark windows and menus"),
            entry(2, "Speakers", "Solo piano", "Bach, close up"),
            entry(3, "Dock", "Show badges", "Unread counts on icons"),
        ];
        let titles =
            |q: &str| -> Vec<String> { search(q, &e).iter().map(|x| x.title.clone()).collect() };
        assert_eq!(titles("PIANO"), ["Solo piano"]);
        assert_eq!(titles("unread"), ["Show badges"]);
        assert_eq!(titles("dark menus"), ["Dark style"]);
        assert!(titles("dark piano").is_empty());
        assert!(titles("   ").is_empty());
        assert!(titles("").is_empty());
    }

    #[test]
    fn a_page_name_gives_one_entry_that_opens_the_page() {
        let e = vec![
            entry(2, "Speakers", "Flat", "As they are"),
            entry(2, "Speakers", "Voice", "Clearer speech"),
            entry(3, "Dock", "Show badges", "Unread counts"),
        ];
        let hits = search("speakers", &e);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].step, 2);
        assert_eq!(hits[0].title, "Speakers");
        // A row that matches on its own words wins over the page's entry.
        let hits = search("voice", &e);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].title, "Voice");
    }

    #[test]
    fn search_puts_title_matches_first() {
        let e = vec![
            entry(1, "Top bar", "Clock", "Shows the speaker volume too"),
            entry(2, "Speakers", "Speaker tuning", "An equaliser"),
        ];
        let hits = search("speaker", &e);
        assert_eq!(hits[0].title, "Speaker tuning");
        assert_eq!(hits[1].title, "Clock");
    }
}
