//! Streaming parser for Flathub's AppStream catalogue (appstream.xml / .xml.gz).
//!
//! Keeps only what the store shows: untranslated name, summary, keywords, categories, links,
//! developer, licence, cached icon file, a plain-text description and screenshot links.

use flate2::read::GzDecoder;
use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;
use std::fs::File;
use std::io::{BufRead, BufReader, Read};
use std::path::Path;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct App {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub summary: String,
    pub description: String,
    pub developer: String,
    pub license: String,
    pub keywords: Vec<String>,
    pub categories: Vec<String>,
    pub homepage: Option<String>,
    pub vcs_browser: Option<String>,
    /// Cached icon file name (relative to the catalogue's icons/<size>/ folder) and its size.
    pub icon: Option<(String, u32)>,
    /// One image link per screenshot, in order: the thumbnail nearest 624 px wide, else the original.
    pub screenshots: Vec<String>,
}

/// At most this many screenshots per app are kept (the store shows a few, not all).
const MAX_SCREENSHOTS: usize = 6;

/// How well a screenshot image suits the store's app page (lower is better).
fn shot_score(source: bool, width: u32) -> u32 {
    if source {
        10_000
    } else {
        width.abs_diff(624)
    }
}

/// Opens a catalogue, transparently gunzipping `.gz` files.
pub fn load(path: &Path) -> Result<Vec<App>, String> {
    let file = File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let reader: Box<dyn Read> = if path.extension().is_some_and(|e| e == "gz") {
        Box::new(GzDecoder::new(file))
    } else {
        Box::new(file)
    };
    parse(BufReader::new(reader))
}

fn attr(e: &BytesStart, name: &[u8]) -> Option<String> {
    e.attributes()
        .flatten()
        .find(|a| a.key.as_ref() == name)
        .and_then(|a| a.unescape_value().ok().map(|v| v.into_owned()))
}

/// Elements whose text we want, by path below <component>.
#[derive(Clone, Copy, PartialEq)]
enum Field {
    Id,
    Name,
    Summary,
    License,
    DeveloperName,
    DeveloperNameLegacy,
    Keyword,
    Category,
    Url(bool), // true = vcs-browser, false = homepage
    Icon(u32),
    /// An <image> in a <screenshot>: whether it's the original, and its width.
    Shot(bool, u32),
    Description,
    Other,
}

pub fn parse<R: BufRead>(input: R) -> Result<Vec<App>, String> {
    let mut reader = Reader::from_reader(input);
    reader.config_mut().trim_text(true);
    let mut buf = Vec::new();
    let mut apps = Vec::new();
    let mut current: Option<App> = None;
    // Element stack below <component>, with the field each one feeds.
    let mut stack: Vec<(Vec<u8>, Field)> = Vec::new();
    let mut desc_depth: Option<usize> = None; // set while inside an untranslated <description>
    let mut shot: Option<(u32, String)> = None; // the best image so far of the current <screenshot>

    loop {
        match reader.read_event_into(&mut buf) {
            Err(e) => {
                return Err(format!(
                    "appstream: {e} at byte {}",
                    reader.buffer_position()
                ))
            }
            Ok(Event::Eof) => break,
            Ok(Event::Start(e)) => {
                let tag = e.name().as_ref().to_vec();
                if tag == b"component" && current.is_none() {
                    current = Some(App {
                        kind: attr(&e, b"type").unwrap_or_default(),
                        ..Default::default()
                    });
                    stack.clear();
                    continue;
                }
                let Some(_) = current.as_ref() else { continue };
                let translated = attr(&e, b"xml:lang").is_some();
                let parent = stack.last().map(|(t, _)| t.as_slice());
                let field = if translated {
                    Field::Other
                } else {
                    match (parent, tag.as_slice()) {
                        (None, b"id") => Field::Id,
                        (None, b"name") => Field::Name,
                        (None, b"summary") => Field::Summary,
                        (None, b"project_license") => Field::License,
                        (None, b"developer_name") => Field::DeveloperNameLegacy,
                        (Some(b"developer"), b"name") => Field::DeveloperName,
                        (Some(b"keywords"), b"keyword") => Field::Keyword,
                        (Some(b"categories"), b"category") => Field::Category,
                        (None, b"url") => match attr(&e, b"type").as_deref() {
                            Some("vcs-browser") => Field::Url(true),
                            Some("homepage") => Field::Url(false),
                            _ => Field::Other,
                        },
                        (None, b"icon") if attr(&e, b"type").as_deref() == Some("cached") => {
                            Field::Icon(
                                attr(&e, b"width").and_then(|w| w.parse().ok()).unwrap_or(0),
                            )
                        }
                        (None, b"description") => Field::Description,
                        (Some(b"screenshot"), b"image") => Field::Shot(
                            attr(&e, b"type").as_deref() != Some("thumbnail"),
                            attr(&e, b"width").and_then(|w| w.parse().ok()).unwrap_or(0),
                        ),
                        _ => Field::Other,
                    }
                };
                if field == Field::Description {
                    desc_depth = Some(stack.len());
                }
                // Paragraph and list breaks inside the description.
                if desc_depth.is_some() && matches!(tag.as_slice(), b"p" | b"li") {
                    let app = current.as_mut().unwrap();
                    if !app.description.is_empty() {
                        app.description.push('\n');
                    }
                    if tag == b"li" {
                        app.description.push_str("• ");
                    }
                }
                stack.push((tag, field));
            }
            Ok(Event::Text(t)) => {
                let (Some(app), Some((_, field))) = (current.as_mut(), stack.last()) else {
                    continue;
                };
                let text = t.unescape().map(|s| s.into_owned()).unwrap_or_default();
                if desc_depth.is_some() {
                    // Only the untranslated description: translated ones were marked Other at the top.
                    if stack.iter().any(|(_, f)| *f == Field::Description) {
                        app.description.push_str(
                            text.split_whitespace()
                                .collect::<Vec<_>>()
                                .join(" ")
                                .as_str(),
                        );
                    }
                    continue;
                }
                match *field {
                    Field::Id => app.id = text,
                    Field::Name => app.name = text,
                    Field::Summary => app.summary = text,
                    Field::License => app.license = text,
                    Field::DeveloperName => app.developer = text,
                    Field::DeveloperNameLegacy if app.developer.is_empty() => app.developer = text,
                    Field::Keyword => app.keywords.push(text),
                    Field::Category => app.categories.push(text),
                    Field::Url(true) => app.vcs_browser = Some(text),
                    Field::Url(false) => app.homepage = Some(text),
                    Field::Shot(source, width) => {
                        let score = shot_score(source, width);
                        if shot.as_ref().is_none_or(|(s, _)| score < *s) {
                            shot = Some((score, text));
                        }
                    }
                    Field::Icon(size) => {
                        // Prefer the 64 px icon, else the largest.
                        let better = match &app.icon {
                            None => true,
                            Some((_, s)) => (size == 64) || (*s != 64 && size > *s),
                        };
                        if better {
                            app.icon = Some((text, size));
                        }
                    }
                    _ => {}
                }
            }
            Ok(Event::End(e)) => {
                if e.name().as_ref() == b"component" && stack.is_empty() {
                    if let Some(app) = current.take() {
                        if !app.id.is_empty() {
                            apps.push(app);
                        }
                    }
                    desc_depth = None;
                    continue;
                }
                if e.name().as_ref() == b"screenshot" {
                    if let (Some(app), Some((_, url))) = (current.as_mut(), shot.take()) {
                        if app.screenshots.len() < MAX_SCREENSHOTS && url.starts_with("https://") {
                            app.screenshots.push(url);
                        }
                    }
                }
                if stack.pop().is_some() && desc_depth.is_some_and(|d| d == stack.len()) {
                    desc_depth = None;
                }
            }
            _ => {}
        }
        buf.clear();
    }
    Ok(apps)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<components version="0.8" origin="flatpak">
  <component type="desktop-application">
    <id>ai.jan.Jan</id>
    <name>Jan</name>
    <name xml:lang="pl">Jan PL</name>
    <summary>Private offline AI assistant</summary>
    <summary xml:lang="pl">Prywatny</summary>
    <project_license>Apache-2.0</project_license>
    <description>
      <p>Jan is an   open source alternative.</p>
      <ul><li>Local models</li><li>Optional cloud</li></ul>
    </description>
    <description xml:lang="pl"><p>Polski opis</p></description>
    <developer><name>Menlo Research</name></developer>
    <developer_name>Legacy Name</developer_name>
    <url type="homepage">https://jan.ai</url>
    <url type="vcs-browser">https://github.com/menloresearch/jan</url>
    <icon height="48" type="cached" width="48">ai.jan.Jan.png</icon>
    <icon height="64" type="cached" width="64">ai.jan.Jan64.png</icon>
    <icon height="128" type="cached" width="128">ai.jan.Jan128.png</icon>
    <categories><category>Utility</category><category>Development</category></categories>
    <keywords><keyword>llm</keyword><keyword xml:lang="pl">model</keyword></keywords>
    <screenshots>
      <screenshot type="default">
        <caption>Chat</caption>
        <image type="source" width="1920" height="1080">https://example.org/src1.png</image>
        <image type="thumbnail" width="1248" height="702">https://example.org/1248.png</image>
        <image type="thumbnail" width="624" height="351">https://example.org/624.png</image>
      </screenshot>
      <screenshot><image type="source">https://example.org/only-source.png</image></screenshot>
      <screenshot><image type="thumbnail" width="624">http://example.org/plain-http.png</image></screenshot>
    </screenshots>
  </component>
  <component type="runtime"><id>org.freedesktop.Platform</id><name>Freedesktop Platform</name></component>
</components>"#;

    #[test]
    fn parses_the_untranslated_fields() {
        let apps = parse(SAMPLE.as_bytes()).unwrap();
        assert_eq!(apps.len(), 2);
        let a = &apps[0];
        assert_eq!(a.id, "ai.jan.Jan");
        assert_eq!(a.kind, "desktop-application");
        assert_eq!(a.name, "Jan");
        assert_eq!(a.summary, "Private offline AI assistant");
        assert_eq!(a.license, "Apache-2.0");
        assert_eq!(a.developer, "Menlo Research");
        assert_eq!(a.keywords, vec!["llm"]);
        assert_eq!(a.categories, vec!["Utility", "Development"]);
        assert_eq!(a.homepage.as_deref(), Some("https://jan.ai"));
        assert_eq!(
            a.vcs_browser.as_deref(),
            Some("https://github.com/menloresearch/jan")
        );
        assert_eq!(a.icon, Some(("ai.jan.Jan64.png".to_string(), 64)));
    }

    #[test]
    fn description_is_plain_text_without_translations() {
        let a = &parse(SAMPLE.as_bytes()).unwrap()[0];
        assert_eq!(
            a.description,
            "Jan is an open source alternative.\n• Local models\n• Optional cloud"
        );
    }

    #[test]
    fn screenshots_prefer_the_624_thumbnail_and_https() {
        let a = &parse(SAMPLE.as_bytes()).unwrap()[0];
        assert_eq!(
            a.screenshots,
            vec![
                "https://example.org/624.png",
                "https://example.org/only-source.png"
            ]
        );
    }

    #[test]
    fn legacy_developer_name_is_a_fallback() {
        let xml = r#"<components><component type="desktop-application"><id>x</id><developer_name>Old</developer_name></component></components>"#;
        assert_eq!(parse(xml.as_bytes()).unwrap()[0].developer, "Old");
    }
}
