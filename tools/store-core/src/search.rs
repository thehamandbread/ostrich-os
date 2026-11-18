//! Fuzzy search over the catalogue. Exact and prefix name matches rank first, then fuzzy matches
//! on the name, then on id / keywords / summary.

use crate::appstream::App;
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};

pub struct Searcher {
    matcher: Matcher,
}

impl Default for Searcher {
    fn default() -> Self {
        Searcher {
            matcher: Matcher::new(Config::DEFAULT),
        }
    }
}

impl Searcher {
    /// Indices into `apps`, best first, at most `limit`. Only desktop and console applications.
    pub fn search(&mut self, apps: &[App], query: &str, limit: usize) -> Vec<usize> {
        let q = query.trim();
        let is_app = |a: &App| a.kind == "desktop-application" || a.kind == "console-application";
        if q.is_empty() {
            return apps
                .iter()
                .enumerate()
                .filter(|(_, a)| is_app(a))
                .map(|(i, _)| i)
                .take(limit)
                .collect();
        }
        let pattern = Pattern::parse(q, CaseMatching::Ignore, Normalization::Smart);
        let ql = q.to_lowercase();
        let mut buf = Vec::new();
        let mut scored: Vec<(u32, usize)> = Vec::new();
        for (i, app) in apps.iter().enumerate() {
            if !is_app(app) {
                continue;
            }
            let name = app.name.to_lowercase();
            let mut score = if name == ql {
                1_000_000
            } else if name.starts_with(&ql) {
                500_000
            } else {
                0
            };
            let mut fuzzy = |text: &str, weight: u32| -> u32 {
                pattern
                    .score(Utf32Str::new(text, &mut buf), &mut self.matcher)
                    .map(|s| s * weight)
                    .unwrap_or(0)
            };
            score += fuzzy(&app.name, 4);
            if score == 0 {
                let others = format!("{} {} {}", app.id, app.keywords.join(" "), app.summary);
                score += fuzzy(&others, 1);
            }
            if score > 0 {
                scored.push((score, i));
            }
        }
        scored.sort_by(|a, b| {
            b.0.cmp(&a.0)
                .then_with(|| apps[a.1].name.cmp(&apps[b.1].name))
        });
        scored.into_iter().take(limit).map(|(_, i)| i).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app(id: &str, name: &str, summary: &str, keywords: &[&str]) -> App {
        App {
            id: id.into(),
            kind: "desktop-application".into(),
            name: name.into(),
            summary: summary.into(),
            keywords: keywords.iter().map(|s| s.to_string()).collect(),
            ..Default::default()
        }
    }

    fn catalogue() -> Vec<App> {
        vec![
            app("org.videolan.VLC", "VLC", "Media player", &["video"]),
            app(
                "com.spotify.Client",
                "Spotify",
                "Music streaming",
                &["music"],
            ),
            app(
                "org.gnome.Podcasts",
                "Podcasts",
                "Listen to your favourite shows",
                &["music"],
            ),
            app(
                "org.signal.Signal",
                "Signal",
                "Private messenger",
                &["chat"],
            ),
            App {
                id: "org.freedesktop.Platform".into(),
                kind: "runtime".into(),
                name: "Platform".into(),
                ..Default::default()
            },
        ]
    }

    #[test]
    fn exact_name_first() {
        let apps = catalogue();
        let r = Searcher::default().search(&apps, "signal", 10);
        assert_eq!(apps[r[0]].id, "org.signal.Signal");
    }

    #[test]
    fn fuzzy_name_match() {
        let apps = catalogue();
        let r = Searcher::default().search(&apps, "spfy", 10);
        assert_eq!(apps[r[0]].id, "com.spotify.Client");
    }

    #[test]
    fn keywords_and_summary_match_when_name_doesnt() {
        let apps = catalogue();
        let r: Vec<&str> = Searcher::default()
            .search(&apps, "music", 10)
            .iter()
            .map(|&i| apps[i].id.as_str())
            .collect();
        assert!(r.contains(&"com.spotify.Client") && r.contains(&"org.gnome.Podcasts"));
    }

    #[test]
    fn runtimes_are_never_listed() {
        let apps = catalogue();
        let mut s = Searcher::default();
        assert!(s.search(&apps, "platform", 10).is_empty());
        assert_eq!(s.search(&apps, "", 10).len(), 4);
    }
}
