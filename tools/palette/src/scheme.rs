//! Colour schemes: the built-in ones (tools/icons/palette.toml and tools/icons/schemes/, compiled
//! in) and the user's own (~/.config/ubuntu-ostrich/schemes/ID.toml, same format: `name = "value"`
//! lines). Applying one writes each extension's stylesheet, filled from the same template its
//! built-in stylesheet.css comes from, into ~/.config/ubuntu-ostrich/scheme/ (the extensions load it
//! and follow changes), and sets the accent, icon theme and wallpaper the scheme names.

use crate::color::{contrast, Rgb};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const BUILT_IN: [(&str, &str); 7] = [
    ("classic", include_str!("../../icons/palette.toml")),
    (
        "slate-glass",
        include_str!("../../icons/schemes/slate-glass.toml"),
    ),
    (
        "ubuntu-ember",
        include_str!("../../icons/schemes/ubuntu-ember.toml"),
    ),
    (
        "night-glass",
        include_str!("../../icons/schemes/night-glass.toml"),
    ),
    (
        "graphite",
        include_str!("../../icons/schemes/graphite.toml"),
    ),
    ("forest", include_str!("../../icons/schemes/forest.toml")),
    (
        "high-contrast",
        include_str!("../../icons/schemes/high-contrast.toml"),
    ),
];

/// The extension stylesheets a scheme fills (extension name, template).
pub const TEMPLATES: [(&str, &str); 4] = [
    (
        "blur",
        include_str!("../../../modules/gnome/extensions/blur/stylesheet.css.in"),
    ),
    (
        "dock",
        include_str!("../../../modules/gnome/extensions/dock/stylesheet.css.in"),
    ),
    (
        "tiling",
        include_str!("../../../modules/gnome/extensions/tiling/stylesheet.css.in"),
    ),
    (
        "workspaces",
        include_str!("../../../modules/gnome/extensions/workspaces/stylesheet.css.in"),
    ),
];

/// The sizes the templates use as [[name]]: corners, space, targets (tools/icons/tokens.toml).
const TOKENS: &str = include_str!("../../icons/tokens.toml");

/// `name = "value"` pairs of tokens.toml.
fn tokens() -> Vec<(String, String)> {
    TOKENS
        .lines()
        .filter_map(|l| {
            let (k, rest) = l.split_once('=')?;
            let k = k.trim();
            let v = rest.trim().strip_prefix('"')?.split_once('"')?.0;
            (!k.is_empty() && !k.starts_with('#')).then(|| (k.to_string(), v.to_string()))
        })
        .collect()
}

pub struct Scheme {
    pub id: String,
    pub built_in: bool,
    pub values: BTreeMap<String, String>,
}

impl Scheme {
    pub fn name(&self) -> &str {
        self.values
            .get("name")
            .map(String::as_str)
            .unwrap_or(&self.id)
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.values
            .get(key)
            .map(String::as_str)
            .filter(|v| !v.is_empty())
    }
}

/// `key = "value"` lines; comments and anything else are skipped.
pub fn parse(text: &str) -> BTreeMap<String, String> {
    text.lines()
        .filter_map(|l| {
            let (k, rest) = l.split_once('=')?;
            let k = k.trim();
            let rest = rest.trim().strip_prefix('"')?;
            let v = &rest[..rest.find('"')?];
            (!k.is_empty() && k.chars().all(|c| c.is_ascii_lowercase() || c == '_'))
                .then(|| (k.to_string(), v.to_string()))
        })
        .collect()
}

/// A scheme file written back: `name = "value"` lines in key order.
pub fn to_text(values: &BTreeMap<String, String>) -> String {
    let mut out = String::from(
        "# An Ubuntu Ostrich colour scheme (ostrich theme scheme; Ostrich Settings > Theme).\n",
    );
    for (k, v) in values {
        out.push_str(&format!("{k} = \"{v}\"\n"));
    }
    out
}

pub fn user_dir(config: &Path) -> PathBuf {
    config.join("ubuntu-ostrich/schemes")
}

/// Ids are file names: letters, digits and '-'.
pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// Every scheme: the built-in ones, then the user's (a user scheme with a built-in's id replaces it).
pub fn all(config: &Path) -> Vec<Scheme> {
    let mut list: Vec<Scheme> = BUILT_IN
        .iter()
        .map(|(id, text)| Scheme {
            id: id.to_string(),
            built_in: true,
            values: parse(text),
        })
        .collect();
    let mut own: Vec<Scheme> = std::fs::read_dir(user_dir(config))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let p = e.path();
            let id = p.file_stem()?.to_str()?.to_string();
            (p.extension()? == "toml" && valid_id(&id)).then_some(())?;
            Some(Scheme {
                id,
                built_in: false,
                values: parse(&std::fs::read_to_string(&p).ok()?),
            })
        })
        .collect();
    own.sort_by(|a, b| a.id.cmp(&b.id));
    for s in own {
        list.retain(|b| b.id != s.id);
        list.push(s);
    }
    list
}

/// A colour as a stylesheet may use it: #rrggbb, or rgba(r, g, b, a) with a in 0..1. Anything else is
/// refused, so a scheme file can't carry other CSS into the shell.
pub fn colour(v: &str) -> Option<(Rgb, f32)> {
    if let Some(c) = Rgb::from_hex(v).filter(|_| v.len() == 7) {
        return Some((c, 1.0));
    }
    let inner = v.strip_prefix("rgba(")?.strip_suffix(')')?;
    let parts: Vec<&str> = inner.split(',').map(str::trim).collect();
    let [r, g, b, a] = parts.as_slice() else {
        return None;
    };
    let (r, g, b) = (
        r.parse::<u8>().ok()?,
        g.parse::<u8>().ok()?,
        b.parse::<u8>().ok()?,
    );
    let a = a.parse::<f32>().ok().filter(|a| (0.0..=1.0).contains(a))?;
    Some((Rgb::from_u8(r, g, b), a))
}

/// The names the templates use ({{name}}).
pub fn colour_keys() -> Vec<String> {
    let mut keys: Vec<String> = TEMPLATES
        .iter()
        .flat_map(|(_, t)| {
            t.split("{{")
                .skip(1)
                .filter_map(|s| s.split_once("}}").map(|(k, _)| k.to_string()))
        })
        .collect();
    keys.sort();
    keys.dedup();
    keys
}

fn over(top: (Rgb, f32), under: Rgb) -> Rgb {
    let (c, a) = top;
    let mix = |x: f32, y: f32| x * a + y * (1.0 - a);
    Rgb {
        r: mix(c.r, under.r),
        g: mix(c.g, under.g),
        b: mix(c.b, under.b),
    }
}

/// What's wrong with a scheme: errors (it can't be applied) and warnings (text under 4.5:1).
pub fn check(s: &Scheme) -> (Vec<String>, Vec<String>) {
    let mut errors = Vec::new();
    for k in colour_keys() {
        match s.get(&k) {
            None => errors.push(format!("{k} is missing")),
            Some(v) if colour(v).is_none() => {
                errors.push(format!("{k} = \"{v}\" isn't #rrggbb or rgba(r, g, b, a)"))
            }
            _ => {}
        }
    }
    if let Some(a) = s.get("ui_accent") {
        if Rgb::from_hex(a).is_none() || a.len() != 7 {
            errors.push(format!("ui_accent = \"{a}\" isn't #rrggbb"));
        }
    }
    for k in ["icon_theme", "wallpaper", "wallpaper_dark"] {
        if let Some(v) = s.get(k) {
            let ok = if k == "icon_theme" {
                v.chars()
                    .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
            } else {
                v.starts_with('/') && !v.contains(['\'', '"', '\n'])
            };
            if !ok {
                errors.push(format!("{k} = \"{v}\" isn't usable"));
            }
        }
    }
    let mut warnings = Vec::new();
    if errors.is_empty() {
        let c = |k: &str| colour(s.get(k).unwrap()).unwrap();
        let solid = c("solid").0;
        let white = Rgb {
            r: 1.0,
            g: 1.0,
            b: 1.0,
        };
        // The worst cases with nothing busy behind: text on the solid colour, the empty workspace
        // numerals on the bar's glass over it, dark text on the light menu glass over white.
        for (what, fg, bg) in [
            ("text on solid surfaces", c("text").0, solid),
            (
                "empty workspace numerals on the top bar",
                over(c("ws_empty"), over(c("glass_bar"), solid)),
                over(c("glass_bar"), solid),
            ),
            (
                "text on light menus",
                c("light_text").0,
                over(c("light_glass_menu"), white),
            ),
        ] {
            let r = contrast(fg, bg);
            if r < 4.5 {
                warnings.push(format!("{what}: {r:.1}:1, under 4.5:1"));
            }
        }
    }
    (errors, warnings)
}

/// One template filled with the scheme's colours (check() has passed) and the sizes.
pub fn fill(template: &str, s: &Scheme) -> String {
    let mut out = template.to_string();
    for (k, v) in tokens() {
        out = out.replace(&format!("[[{k}]]"), &v);
    }
    for k in colour_keys() {
        if let Some(v) = s.get(&k) {
            out = out.replace(&format!("{{{{{k}}}}}"), v);
        }
    }
    out
}

/// The scheme's own wallpaper as SVG (dark, light), from its wall_* colours, if it has them.
pub fn wallpaper_svgs(s: &Scheme) -> Option<(String, String)> {
    let hex = |k: &str| {
        s.get(k)
            .filter(|v| Rgb::from_hex(v).is_some() && v.len() == 7)
    };
    let (top, bottom, bloom, warm) = (
        hex("wall_top")?,
        hex("wall_bottom")?,
        hex("wall_bloom")?,
        hex("wall_bloom_warm")?,
    );
    let (ltop, lbottom) = (hex("wall_light_top")?, hex("wall_light_bottom")?);
    let draw = |t: &str, b: &str, o: f32| {
        format!(
            r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 3840 2160" preserveAspectRatio="xMidYMid slice">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="0.35" y2="1"><stop offset="0" stop-color="{t}"/><stop offset="1" stop-color="{b}"/></linearGradient>
    <radialGradient id="a" cx="0.28" cy="0.34" r="0.5"><stop offset="0" stop-color="{bloom}" stop-opacity="{o}"/><stop offset="1" stop-color="{bloom}" stop-opacity="0"/></radialGradient>
    <radialGradient id="b" cx="0.78" cy="0.72" r="0.42"><stop offset="0" stop-color="{warm}" stop-opacity="{o}"/><stop offset="1" stop-color="{warm}" stop-opacity="0"/></radialGradient>
  </defs>
  <rect width="3840" height="2160" fill="url(#g)"/>
  <rect width="3840" height="2160" fill="url(#a)"/>
  <rect width="3840" height="2160" fill="url(#b)"/>
</svg>
"##
        )
    };
    Some((draw(top, bottom, 0.55), draw(ltop, lbottom, 0.35)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn built_in(id: &str) -> Scheme {
        let text = BUILT_IN.iter().find(|(i, _)| *i == id).unwrap().1;
        Scheme {
            id: id.into(),
            built_in: true,
            values: parse(text),
        }
    }

    #[test]
    fn tokens_are_read_and_filled() {
        let t = tokens();
        assert!(t.iter().any(|(k, v)| k == "radius_menu" && v == "20px"));
        assert_eq!(
            fill(
                "a { border-radius: [[radius_menu]]; }",
                &built_in("classic")
            ),
            "a { border-radius: 20px; }"
        );
    }

    #[test]
    fn every_built_in_scheme_is_complete_and_readable() {
        for (id, _) in BUILT_IN {
            let s = built_in(id);
            let (errors, warnings) = check(&s);
            assert!(errors.is_empty(), "{id}: {errors:?}");
            assert!(warnings.is_empty(), "{id}: {warnings:?}");
            for (ext, t) in TEMPLATES {
                let filled = fill(t, &s);
                assert!(
                    !filled.contains("{{") && !filled.contains("[["),
                    "{id} {ext}"
                );
            }
        }
        assert!(wallpaper_svgs(&built_in("slate-glass")).is_some());
        assert!(wallpaper_svgs(&built_in("ubuntu-ember")).is_none());
    }

    #[test]
    fn colours_are_strict() {
        assert!(colour("#1d1d20").is_some());
        assert_eq!(colour("rgba(255, 255, 255, 0.8)").unwrap().1, 0.8);
        for bad in [
            "red",
            "#fff",
            "rgba(1,2,3)",
            "rgba(1, 2, 3, 2)",
            "#000000; } * { color: red",
            "rgba(300, 0, 0, 1)",
        ] {
            assert!(colour(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn a_broken_or_hard_to_read_scheme_is_reported() {
        let mut s = built_in("classic");
        s.values.insert("solid".into(), "url(evil)".into());
        s.values.remove("text");
        let (errors, _) = check(&s);
        assert_eq!(errors.len(), 2, "{errors:?}");
        let mut s = built_in("classic");
        s.values.insert("text".into(), "#333333".into());
        assert!(check(&s).1.iter().any(|w| w.starts_with("text on solid")));
    }

    #[test]
    fn files_round_trip() {
        let s = built_in("night-glass");
        assert_eq!(parse(&to_text(&s.values)), s.values);
        assert!(valid_id("my-theme-2") && !valid_id("../x") && !valid_id(""));
    }
}
