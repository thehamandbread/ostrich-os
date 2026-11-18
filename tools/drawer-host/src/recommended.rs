//! The recommended sites (data/recommended.toml, built in). Pure, unit-tested.

use crate::config::{host_of, normalise_url, Service, Shape};
use serde::Deserialize;
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    #[default]
    Ok,
    Drm,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Site {
    pub id: String,
    pub name: String,
    pub url: String,
    pub group: String,
    #[serde(default)]
    pub shape: Shape,
    #[serde(default)]
    pub keep_alive: bool,
    #[serde(default)]
    pub status: Status,
    #[serde(default)]
    pub user_agent: Option<String>,
    /// For a DRM site: the snap of its own app, opened instead (the drawer can't play it).
    #[serde(default)]
    pub app: Option<String>,
    /// The same app's Flatpak id, when that's the one installed.
    #[serde(default)]
    pub flatpak: Option<String>,
}

impl Site {
    pub fn service(&self) -> Service {
        Service {
            shape: Some(self.shape),
            keep_alive: self.keep_alive,
            user_agent: self.user_agent.clone(),
            ..Service::new(&self.id, &self.name, &self.url)
        }
    }
}

#[derive(Deserialize)]
struct Catalog {
    site: Vec<Site>,
}

pub fn all() -> &'static [Site] {
    static SITES: OnceLock<Vec<Site>> = OnceLock::new();
    SITES.get_or_init(|| {
        toml::from_str::<Catalog>(include_str!("../data/recommended.toml"))
            .map(|c| c.site)
            .unwrap_or_default()
    })
}

/// Whether a site's page may announce itself as a media player (MPRIS, so GNOME's media card can
/// control it): the recommended media sites and sites people add themselves. Messaging, AI and mail
/// pages otherwise show up as empty "Stopped" players with a play button that does nothing.
pub fn media_controls(url: &str) -> bool {
    find(url).is_none_or(|s| s.group == "media")
}

/// A recommended site by id ("whatsapp") or by address ("web.whatsapp.com/…").
pub fn find(input: &str) -> Option<&'static Site> {
    let t = input.trim();
    if let Some(s) = all().iter().find(|s| s.id == t) {
        return Some(s);
    }
    let host = normalise_url(t).and_then(|u| host_of(&u))?;
    all()
        .iter()
        .find(|s| host_of(&s.url).as_deref() == Some(host.as_str()))
}

/// For `--recommended`: id, name, url, group, shape, status, one tab-separated line each. Status is
/// ok, drm (opens in the browser) or drm-app (opens in its own app).
pub fn listing() -> String {
    all()
        .iter()
        .map(|s| {
            format!(
                "{}\t{}\t{}\t{}\t{}\t{}\n",
                s.id,
                s.name,
                s.url,
                s.group,
                s.shape.as_str(),
                match (s.status, &s.app) {
                    (Status::Ok, _) => "ok",
                    (Status::Drm, None) => "drm",
                    (Status::Drm, Some(_)) => "drm-app",
                }
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::valid_id;

    #[test]
    fn catalog_is_valid() {
        let sites = all();
        assert!(sites.len() >= 20, "catalog failed to parse");
        let mut ids = std::collections::HashSet::new();
        for s in sites {
            assert!(valid_id(&s.id), "{}", s.id);
            assert!(ids.insert(&s.id), "duplicate {}", s.id);
            assert!(s.url.starts_with("https://"), "{}", s.url);
            assert!(
                ["messaging", "ai", "mail", "media"].contains(&s.group.as_str()),
                "{}",
                s.group
            );
        }
        // Messaging is narrow and stays loaded; DRM sites are flagged.
        assert!(sites
            .iter()
            .filter(|s| s.group == "messaging")
            .all(|s| s.shape == Shape::Narrow && s.keep_alive));
        assert_eq!(find("spotify").unwrap().status, Status::Drm);
        assert_eq!(find("spotify").unwrap().app.as_deref(), Some("spotify"));
    }

    #[test]
    fn starters_are_recommended() {
        for s in crate::config::Config::default().services {
            let r = find(&s.id).unwrap();
            assert_eq!(
                (r.url.as_str(), r.keep_alive),
                (s.url.as_str(), s.keep_alive)
            );
        }
    }

    #[test]
    fn finds_by_id_or_address() {
        assert_eq!(find("web.whatsapp.com").unwrap().id, "whatsapp");
        assert_eq!(find("https://chatgpt.com/c/1").unwrap().id, "chatgpt");
        assert_eq!(find("gmail").unwrap().name, "Gmail");
        assert!(find("example.com").is_none());
        assert!(media_controls("https://www.youtube.com/"));
        assert!(media_controls("http://localhost:8099/"));
        assert!(!media_controls("https://messages.google.com/web/"));
        assert!(!media_controls("https://mail.google.com/"));
        assert!(listing()
            .lines()
            .any(|l| l.starts_with("spotify\t") && l.ends_with("\tdrm-app")));
        assert!(listing()
            .lines()
            .any(|l| l.starts_with("netflix\t") && l.ends_with("\tdrm")));
    }
}
