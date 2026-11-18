//! drawer.toml: the user's services. Pure (no GTK), unit-tested.
//!
//! ```toml
//! idle_unload_minutes = 15
//!
//! [[service]]
//! id = "messages"
//! name = "Google Messages"
//! url = "https://messages.google.com/web"
//! keep_alive = true        # stays loaded in the background (messaging)
//! icon = "mail-message-new" # themed icon name or a file path (optional)
//! pinned = true            # has an icon in the top bar (default true)
//! shape = "narrow"         # narrow (phone-like, chat) or wide (default)
//! width = 0                # the size the user resized it to, in pixels (0: from the shape)
//! height = 0
//! muted = false            # this site's notifications are dropped
//! user_agent = "..."       # only for sites that turn WebKit's own away (optional)
//! ```

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct Service {
    pub id: String,
    pub name: String,
    pub url: String,
    #[serde(default)]
    pub keep_alive: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    pub pinned: bool,
    /// None: the recommended catalog's shape for this site, else wide.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shape: Option<Shape>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub width: u32,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub height: u32,
    #[serde(default, skip_serializing_if = "is_false")]
    pub muted: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_agent: Option<String>,
}

/// How a site opens before the user resizes it: chat sites narrow like a phone, the rest wide.
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Shape {
    Narrow,
    #[default]
    Wide,
}

impl Shape {
    pub fn as_str(&self) -> &'static str {
        match self {
            Shape::Narrow => "narrow",
            Shape::Wide => "wide",
        }
    }
}

fn yes() -> bool {
    true
}
fn is_true(b: &bool) -> bool {
    *b
}
fn is_false(b: &bool) -> bool {
    !*b
}
fn is_zero(n: &u32) -> bool {
    *n == 0
}

impl Service {
    /// How it opens: its own shape, else the recommended site's (by address), else wide.
    /// Configs written before shapes existed get the right shape this way.
    pub fn shape(&self) -> Shape {
        self.shape
            .or_else(|| crate::recommended::find(&self.url).map(|r| r.shape))
            .unwrap_or_default()
    }

    pub fn new(id: &str, name: &str, url: &str) -> Service {
        Service {
            id: id.into(),
            name: name.into(),
            url: url.into(),
            keep_alive: false,
            icon: None,
            pinned: true,
            shape: None,
            width: 0,
            height: 0,
            muted: false,
            user_agent: None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct Config {
    #[serde(default = "default_idle")]
    pub idle_unload_minutes: u32,
    #[serde(default, rename = "service")]
    pub services: Vec<Service>,
}

fn default_idle() -> u32 {
    15
}

impl Default for Config {
    fn default() -> Self {
        let s = |id: &str, name: &str, url: &str, keep: bool, icon: &str| Service {
            keep_alive: keep,
            icon: Some(icon.into()),
            // Messaging opens narrow, like a phone.
            shape: Some(if keep { Shape::Narrow } else { Shape::Wide }),
            ..Service::new(id, name, url)
        };
        Config {
            idle_unload_minutes: default_idle(),
            services: vec![
                s(
                    "messages",
                    "Google Messages",
                    "https://messages.google.com/web",
                    true,
                    "mail-message-new-symbolic",
                ),
                s(
                    "chat",
                    "Google Chat",
                    "https://chat.google.com",
                    true,
                    "user-available-symbolic",
                ),
                s(
                    "claude",
                    "Claude",
                    "https://claude.ai",
                    false,
                    "help-about-symbolic",
                ),
                s(
                    "youtube",
                    "YouTube",
                    "https://www.youtube.com",
                    false,
                    "video-x-generic-symbolic",
                ),
            ],
        }
    }
}

impl Config {
    pub fn parse(text: &str) -> Result<Config, String> {
        let c: Config = toml::from_str(text).map_err(|e| format!("drawer.toml: {e}"))?;
        c.validate()?;
        Ok(c)
    }

    pub fn to_toml(&self) -> String {
        toml::to_string_pretty(self).unwrap_or_default()
    }

    fn validate(&self) -> Result<(), String> {
        let mut seen = std::collections::HashSet::new();
        for s in &self.services {
            if !valid_id(&s.id) {
                return Err(format!(
                    "service id {:?}: use letters, digits and '-' only",
                    s.id
                ));
            }
            if !seen.insert(&s.id) {
                return Err(format!("service id {:?} is used twice", s.id));
            }
            if !web_url(&s.url) {
                return Err(format!("service {}: url must start with https://", s.id));
            }
            if s.width > 10000 || s.height > 10000 {
                return Err(format!("service {}: size too large", s.id));
            }
        }
        Ok(())
    }

    /// Adds a site from a URL the user typed; returns the new service id.
    pub fn add_site(&mut self, url: &str, name: Option<&str>) -> Result<String, String> {
        // A recommended site, by id ("whatsapp") or address: take its name, shape and settings.
        if let Some(r) = crate::recommended::find(url) {
            if r.status == crate::recommended::Status::Drm {
                return Err(format!(
                    "{} can't play in the drawer (it needs DRM video): open it in {} instead",
                    r.name,
                    if r.app.is_some() {
                        "its app"
                    } else {
                        "your browser"
                    }
                ));
            }
            if !self.services.iter().any(|s| s.id == r.id) {
                self.services.push(r.service());
                return Ok(r.id.clone());
            }
        }
        let bad = || format!("“{}” isn't a web address", url.trim());
        let url = normalise_url(url).ok_or_else(bad)?;
        let host = host_of(&url).ok_or_else(bad)?;
        // The label before the top-level domain: open.spotify.com → spotify.
        let labels: Vec<&str> = host.split('.').collect();
        let main = if labels.len() >= 2 {
            labels[labels.len() - 2]
        } else {
            labels[0]
        };
        let base: String = main
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
            .collect::<String>()
            .to_lowercase();
        let base = if base.is_empty() {
            "site".to_string()
        } else {
            base
        };
        let mut id = base.clone();
        let mut n = 2;
        while self.services.iter().any(|s| s.id == id) {
            id = format!("{base}-{n}");
            n += 1;
        }
        let name = name.map(str::to_string).unwrap_or_else(|| {
            let mut c = base.chars();
            c.next()
                .map(|f| f.to_uppercase().collect::<String>() + c.as_str())
                .unwrap_or_default()
        });
        self.services.push(Service::new(&id, &name, &url));
        Ok(id)
    }

    pub fn get_mut(&mut self, id: &str) -> Option<&mut Service> {
        self.services.iter_mut().find(|s| s.id == id)
    }

    pub fn remove(&mut self, id: &str) -> bool {
        let before = self.services.len();
        self.services.retain(|s| s.id != id);
        self.services.len() != before
    }
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 40 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// "example.com" → "https://example.com"; keeps https:// URLs; rejects anything else.
pub fn normalise_url(input: &str) -> Option<String> {
    let t = input.trim();
    if t.is_empty() || t.contains(char::is_whitespace) {
        return None;
    }
    let url = if web_url(t) {
        t.to_string()
    } else if t.contains("://") {
        return None;
    } else {
        format!("https://{t}")
    };
    // Bare names ("localhost", "intranet") aren't sites; http://localhost is allowed for testing.
    host_of(&url)
        .filter(|h| h.contains('.') || url.starts_with("http://"))
        .map(|_| url)
}

/// https://, or plain http:// to this machine only (for testing): not "localhost.evil.com" or
/// "localhost@evil.com".
fn web_url(url: &str) -> bool {
    url.starts_with("https://")
        || (url.starts_with("http://") && host_of(url).as_deref() == Some("localhost"))
}

pub fn host_of(url: &str) -> Option<String> {
    let rest = url.split_once("://")?.1;
    let host = rest
        .split(['/', '?', '#'])
        .next()?
        .split('@')
        .next_back()?
        .split(':')
        .next()?;
    (!host.is_empty()).then(|| host.to_lowercase())
}

/// The site a host belongs to (its registrable domain): "messages.google.com" → "google.com". A
/// small rule, not the Public Suffix List: the last two labels, or three under a two-letter country
/// code with a generic second level ("bbc.co.uk", "abc.net.au").
pub fn site_of(host: &str) -> String {
    let labels: Vec<&str> = host.trim_end_matches('.').split('.').collect();
    let n = labels.len();
    let generic = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"];
    let keep = if n >= 3 && labels[n - 1].len() == 2 && generic.contains(&labels[n - 2]) {
        3
    } else {
        2
    };
    labels[n.saturating_sub(keep)..].join(".")
}

/// Whether two addresses are on the same site.
pub fn same_site(a: &str, b: &str) -> bool {
    matches!((host_of(a), host_of(b)), (Some(x), Some(y)) if site_of(&x) == site_of(&y))
}

/// Hosts that sites send you to for signing in, on another domain than their own.
const SIGN_IN_HOSTS: &[&str] = &[
    "accounts.google.com",
    "login.microsoftonline.com",
    "login.microsoft.com",
    "login.live.com",
    "appleid.apple.com",
    "auth.openai.com",
    "www.facebook.com",
    "m.facebook.com",
    "github.com",
];

/// Whether a page load of a site may stay in the drawer: within the site or to a sign-in host. One
/// that leaves the site opens in the browser instead. Non-web addresses (about:, data:, blob:) stay.
pub fn stays_in_drawer(service_url: &str, target: &str) -> bool {
    if !(target.starts_with("https://") || target.starts_with("http://")) {
        return true;
    }
    same_site(service_url, target)
        || host_of(target).is_some_and(|h| SIGN_IN_HOSTS.contains(&h.as_str()))
}

/// Unread count from titles like "(3) Inbox" or "Chat (12)".
pub fn unread_from_title(title: &str) -> Option<u32> {
    let t = title.trim();
    let grab = |s: &str| s.parse::<u32>().ok().filter(|n| *n > 0);
    if let Some(rest) = t.strip_prefix('(') {
        if let Some((n, _)) = rest.split_once(')') {
            return grab(n.trim());
        }
    }
    if let Some(rest) = t.strip_suffix(')') {
        if let Some((_, n)) = rest.rsplit_once('(') {
            return grab(n.trim());
        }
    }
    None
}

/// A "Key:   1234 kB" field from /proc/meminfo, smaps_rollup or status, in kB.
pub fn kb_field(text: &str, key: &str) -> Option<u64> {
    text.lines()
        .find_map(|l| l.strip_prefix(key)?.strip_prefix(':'))?
        .split_whitespace()
        .next()?
        .parse()
        .ok()
}

/// The command name and parent pid from a /proc/PID/stat line ("12 (Web Content) S 1 ...").
/// The name can hold spaces and brackets, so it ends at the last ')'.
pub fn stat_comm_ppid(stat: &str) -> Option<(&str, u32)> {
    let open = stat.find('(')?;
    let close = stat.rfind(')')?;
    let ppid = stat
        .get(close + 1..)?
        .split_whitespace()
        .nth(1)?
        .parse()
        .ok()?;
    Some((stat.get(open + 1..close)?, ppid))
}

impl Config {
    /// The defaults for a first start: the messaging sites stay loaded only with about 12 GB of
    /// memory or more (the two cost about 500 MB; readiness council 2026-10-31, test 4). Their
    /// shape stays narrow. Unknown memory (0): kept, as before.
    pub fn for_memory(mem_total_kb: u64) -> Config {
        // MemTotal is a little under the memory fitted: a 12 GB machine reports about 11.7 GiB.
        const ABOUT_12_GB_KB: u64 = 11 * 1024 * 1024;
        let mut c = Config::default();
        if mem_total_kb != 0 && mem_total_kb < ABOUT_12_GB_KB {
            for s in &mut c.services {
                s.keep_alive = false;
            }
        }
        c
    }
}

/// The warning shown above two kept-loaded sites on 8 GB of memory or less, else None.
/// `site_mb`: about how much one loaded site uses (0: not measured yet).
pub fn memory_warning(kept: usize, site_mb: u32, mem_total_kb: u64) -> Option<String> {
    const EIGHT_GB_KB: u64 = 8 * 1024 * 1024;
    if kept <= 2 || mem_total_kb == 0 || mem_total_kb > EIGHT_GB_KB {
        return None;
    }
    // MemTotal is a little under the memory fitted (the kernel keeps some): round to whole GB.
    let gb = (mem_total_kb + 512 * 1024) / (1024 * 1024);
    let words = ["Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"];
    let count = words
        .get(kept - 3)
        .map(|w| w.to_string())
        .unwrap_or_else(|| kept.to_string());
    let usage = if site_mb > 0 {
        format!(" use about {} MB", site_mb as usize * kept)
    } else {
        String::new()
    };
    Some(format!(
        "{count} sites kept loaded{usage}; on {gb} GB that can slow things down."
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_round_trips() {
        let c = Config::default();
        assert_eq!(Config::parse(&c.to_toml()).unwrap(), c);
        assert!(c
            .services
            .iter()
            .any(|s| s.id == "messages" && s.keep_alive));
    }

    #[test]
    fn parses_user_config() {
        let c = Config::parse("idle_unload_minutes = 5\n[[service]]\nid = \"spotify\"\nname = \"Spotify\"\nurl = \"https://open.spotify.com\"\n").unwrap();
        assert_eq!(c.idle_unload_minutes, 5);
        assert!(!c.services[0].keep_alive);
    }

    #[test]
    fn rejects_bad_configs() {
        assert!(Config::parse(
            "[[service]]\nid = \"a b\"\nname = \"x\"\nurl = \"https://x.com\"\n"
        )
        .is_err());
        assert!(
            Config::parse("[[service]]\nid = \"a\"\nname = \"x\"\nurl = \"http://x.com\"\n")
                .is_err()
        );
        let dup = "[[service]]\nid = \"a\"\nname = \"x\"\nurl = \"https://x.com\"\n[[service]]\nid = \"a\"\nname = \"y\"\nurl = \"https://y.com\"\n";
        assert!(Config::parse(dup).is_err());
    }

    #[test]
    fn adds_sites_with_unique_ids() {
        let mut c = Config::default();
        assert_eq!(c.add_site("open.example.com", None).unwrap(), "example");
        assert_eq!(
            c.add_site("https://www.youtube.com/feed", Some("Feed"))
                .unwrap(),
            "youtube-2"
        );
        assert_eq!(c.services.last().unwrap().name, "Feed");
        assert!(c.add_site("ftp://x.com", None).is_err());
        assert!(c.add_site("not a url", None).is_err());
        assert_eq!(
            c.services.iter().find(|s| s.id == "example").unwrap().name,
            "Example"
        );
        assert!(c.remove("example") && !c.remove("example"));
    }

    #[test]
    fn new_fields_default_and_round_trip() {
        let c = Config::parse("[[service]]\nid = \"a\"\nname = \"A\"\nurl = \"https://a.com\"\n")
            .unwrap();
        let s = &c.services[0];
        assert!(s.pinned && !s.muted && s.shape() == Shape::Wide && s.width == 0);
        // Defaults aren't written out, so old files and new ones look the same.
        assert!(!c.to_toml().contains("pinned"));
        let mut c = c;
        let s = c.get_mut("a").unwrap();
        s.pinned = false;
        s.shape = Some(Shape::Narrow);
        s.width = 420;
        s.height = 700;
        s.user_agent = Some("UA".into());
        let text = c.to_toml();
        assert!(text.contains("shape = \"narrow\"") && text.contains("pinned = false"));
        assert_eq!(Config::parse(&text).unwrap(), c);
        assert!(Config::default()
            .services
            .iter()
            .all(|s| (s.shape() == Shape::Narrow) == s.keep_alive));
        // An old file with no shapes: chat sites still open narrow.
        let old = Config::parse(
            "[[service]]\nid = \"chat\"\nname = \"Chat\"\nurl = \"https://chat.google.com\"\n",
        )
        .unwrap();
        assert_eq!(old.services[0].shape(), Shape::Narrow);
        assert!(Config::parse(
            "[[service]]\nid = \"a\"\nname = \"A\"\nurl = \"https://a.com\"\nwidth = 99999\n"
        )
        .is_err());
    }

    #[test]
    fn adds_recommended_sites_with_their_settings() {
        let mut c = Config::default();
        assert_eq!(c.add_site("whatsapp", None).unwrap(), "whatsapp");
        let w = c.services.iter().find(|s| s.id == "whatsapp").unwrap();
        assert!(w.keep_alive && w.shape() == Shape::Narrow && w.name == "WhatsApp");
        assert_eq!(c.add_site("https://chatgpt.com/", None).unwrap(), "chatgpt");
        assert!(c.add_site("open.spotify.com", None).is_err());
        // Already there: a second copy gets its own id, like any other address.
        assert_eq!(c.add_site("web.whatsapp.com", None).unwrap(), "whatsapp-2");
    }

    #[test]
    fn sites_and_navigation() {
        assert_eq!(site_of("messages.google.com"), "google.com");
        assert_eq!(site_of("www.bbc.co.uk"), "bbc.co.uk");
        assert_eq!(site_of("localhost"), "localhost");
        assert!(same_site(
            "https://mail.google.com/",
            "https://accounts.google.com/x"
        ));
        assert!(!same_site("http://localhost:8099/", "http://example.org/"));
        let chat = "https://chat.google.com/";
        assert!(stays_in_drawer(chat, "https://chat.google.com/room/1"));
        assert!(stays_in_drawer(chat, "https://accounts.google.com/signin"));
        assert!(stays_in_drawer(
            "https://teams.microsoft.com/",
            "https://login.microsoftonline.com/x"
        ));
        // A link or a script that leaves the site goes to the browser.
        assert!(!stays_in_drawer(chat, "https://example.org/"));
        assert!(!stays_in_drawer(
            "http://localhost:8099/index.html",
            "http://example.org/"
        ));
        assert!(stays_in_drawer(chat, "about:blank"));
    }

    #[test]
    fn urls_and_hosts() {
        assert_eq!(
            normalise_url("example.com/a").as_deref(),
            Some("https://example.com/a")
        );
        assert_eq!(
            host_of("https://user@Mail.Example.com:8443/x").as_deref(),
            Some("mail.example.com")
        );
        assert!(normalise_url("localhost").is_none());
        assert!(normalise_url("http://localhost:8765/t").is_some());
        assert!(normalise_url("http://localhost.evil.com/").is_none());
        assert!(normalise_url("http://localhost@evil.com/").is_none());
    }

    #[test]
    fn unread_counts() {
        assert_eq!(unread_from_title("(3) Inbox - Gmail"), Some(3));
        assert_eq!(unread_from_title("Chat (12)"), Some(12));
        assert_eq!(unread_from_title("(0) Inbox"), None);
        assert_eq!(unread_from_title("Messages"), None);
        assert_eq!(unread_from_title("(beta) app"), None);
    }

    #[test]
    fn memory_fields_and_warning() {
        let kept = |c: Config| c.services.iter().filter(|s| s.keep_alive).count();
        assert_eq!(kept(Config::for_memory(7_949_132)), 0); // 8 GB: nothing loads at login
        assert_eq!(kept(Config::for_memory(16_116_084)), 2); // 16 GB: the messaging sites do
        assert_eq!(kept(Config::for_memory(0)), 2); // unknown: as before
        let meminfo = "MemTotal:        7949132 kB\nMemFree:  100 kB\n";
        assert_eq!(kb_field(meminfo, "MemTotal"), Some(7949132));
        assert_eq!(kb_field(meminfo, "Mem"), None);
        assert_eq!(kb_field("Pss:  2048 kB", "Pss"), Some(2048));
        assert_eq!(
            stat_comm_ppid("812 (WebKitWebProces) S 790 812 0"),
            Some(("WebKitWebProces", 790))
        );
        assert_eq!(stat_comm_ppid("9 (a) b) S 4 9"), Some(("a) b", 4)));
        assert_eq!(stat_comm_ppid("garbage"), None);
        // Two kept sites, or more than 8 GB: no warning.
        assert_eq!(memory_warning(2, 300, 7949132), None);
        assert_eq!(memory_warning(3, 300, 16 * 1024 * 1024), None);
        assert_eq!(
            memory_warning(3, 300, 7949132).as_deref(),
            Some("Three sites kept loaded use about 900 MB; on 8 GB that can slow things down.")
        );
        assert_eq!(
            memory_warning(12, 0, 3900000).as_deref(),
            Some("12 sites kept loaded; on 4 GB that can slow things down.")
        );
    }
}
