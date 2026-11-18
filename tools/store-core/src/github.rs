//! "Paste a GitHub link, get an app" (DESIGN.md: store).
//!
//! 1. If a Flathub app's source link (AppStream vcs-browser) is that repo, use Flathub.
//! 2. Otherwise pick from the latest release's assets: .flatpak > AppImage > .deb > tarball.
//! 3. Verify the download against a published checksum when the release has one.
//! 4. Otherwise: not an installable app repo.
//!
//! Building from source is out of scope (v1).

use crate::appstream::App;
use sha2::{Digest, Sha256};
use std::path::Path;
use std::process::Command;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Repo {
    pub owner: String,
    pub name: String,
}

impl Repo {
    pub fn slug(&self) -> String {
        format!("{}/{}", self.owner, self.name)
    }
}

/// `https://github.com/o/r`, `github.com/o/r/releases`, `git@github.com:o/r.git`, `o/r` → Repo.
pub fn parse_repo(input: &str) -> Option<Repo> {
    let s = input.trim();
    let rest = s
        .strip_prefix("git@github.com:")
        .or_else(|| s.split_once("github.com/").map(|(_, r)| r))
        .unwrap_or(s);
    let mut parts = rest.split(['/', '?', '#']).filter(|p| !p.is_empty());
    let owner = parts.next()?.to_string();
    let name = parts.next()?.trim_end_matches(".git").to_string();
    let valid = |x: &str| {
        !x.is_empty()
            && x.chars()
                .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
    };
    (valid(&owner) && valid(&name)).then_some(Repo { owner, name })
}

/// The Flathub app whose source link is this repo, if any.
pub fn flathub_match<'a>(apps: &'a [App], repo: &Repo) -> Option<&'a App> {
    apps.iter().find(|a| {
        a.vcs_browser
            .as_deref()
            .and_then(parse_repo)
            .is_some_and(|r| {
                r.owner.eq_ignore_ascii_case(&repo.owner) && r.name.eq_ignore_ascii_case(&repo.name)
            })
    })
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    Flatpak,
    AppImage,
    /// Runs package scripts as root: the UI must warn before installing.
    Deb,
    Tarball,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Asset {
    pub name: String,
    pub url: String,
    pub size: u64,
}

fn is_x86_64(name: &str) -> bool {
    let n = name.to_lowercase();
    n.contains("x86_64") || n.contains("amd64") || n.contains("x64") || n.contains("linux64")
}

fn is_other_arch(name: &str) -> bool {
    let n = name.to_lowercase();
    [
        "aarch64", "arm64", "armhf", "armv7", "i386", "i686", "riscv", "ppc64", "s390",
    ]
    .iter()
    .any(|a| n.contains(a))
}

/// What kind of installable an asset is, for an x86_64 Linux desktop, or None.
pub fn classify(name: &str) -> Option<Kind> {
    let n = name.to_lowercase();
    if is_other_arch(&n)
        || n.ends_with(".sig")
        || n.ends_with(".asc")
        || n.ends_with(".sha256")
        || n.ends_with(".zsync")
    {
        return None;
    }
    if n.ends_with(".flatpak") || n.ends_with(".flatpakref") {
        return Some(Kind::Flatpak);
    }
    if n.ends_with(".appimage") {
        return Some(Kind::AppImage);
    }
    if n.ends_with(".deb") {
        return Some(Kind::Deb);
    }
    let tar = [".tar.gz", ".tgz", ".tar.xz", ".tar.zst", ".tar.bz2"]
        .iter()
        .any(|e| n.ends_with(e));
    if tar && n.contains("linux") && !n.contains("source") && !n.contains("src") {
        return Some(Kind::Tarball);
    }
    None
}

/// The best asset: by kind, then explicitly x86_64-named over unlabelled, then smaller.
/// Names that could escape the downloads folder are skipped.
pub fn choose_asset(assets: &[Asset]) -> Option<(Kind, &Asset)> {
    assets
        .iter()
        .filter(|a| !a.name.contains('/') && !a.name.starts_with('.'))
        .filter_map(|a| classify(&a.name).map(|k| (k, a)))
        .min_by(|(ka, a), (kb, b)| {
            ka.cmp(kb)
                .then_with(|| is_x86_64(&b.name).cmp(&is_x86_64(&a.name)))
                .then_with(|| a.size.cmp(&b.size))
        })
}

/// A checksum for `file` from a release's checksum files: `SHA256SUMS`-style text ("hash  name")
/// or a single `<file>.sha256`. Returns the lowercase hex digest.
pub fn find_checksum(file: &str, checksum_texts: &[(String, String)]) -> Option<String> {
    for (name, text) in checksum_texts {
        let single = name.eq_ignore_ascii_case(&format!("{file}.sha256"));
        for line in text.lines() {
            let mut f = line.split_whitespace();
            let (Some(hash), rest) = (f.next(), f.next()) else {
                continue;
            };
            let hash = hash.to_lowercase();
            if hash.len() != 64 || !hash.chars().all(|c| c.is_ascii_hexdigit()) {
                continue;
            }
            // `./App.AppImage` and `dist/App.AppImage` name the same asset.
            let listed = rest.and_then(|r| Path::new(r.trim_start_matches('*')).file_name());
            if single || listed.is_some_and(|l| l == file) {
                return Some(hash);
            }
        }
    }
    None
}

pub fn is_checksum_file(name: &str) -> bool {
    let n = name.to_lowercase();
    n.ends_with(".sha256")
        || n.contains("sha256sum")
        || n == "checksums.txt"
        || n.ends_with("_checksums.txt")
}

pub fn sha256_file(path: &Path) -> Result<String, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(Sha256::digest(&bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}

// ---- network (curl) --------------------------------------------------------------------------

pub(crate) fn curl(args: &[&str]) -> Result<Vec<u8>, String> {
    let out = Command::new("curl")
        .args([
            "-fsSL",
            "--proto",
            "=https",
            "-H",
            "User-Agent: ostrich-store",
        ])
        .args(args)
        .output()
        .map_err(|e| format!("curl: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "download failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(out.stdout)
}

#[derive(Clone, Debug)]
pub struct Release {
    pub tag: String,
    pub assets: Vec<Asset>,
}

pub fn latest_release(repo: &Repo) -> Result<Option<Release>, String> {
    let url = format!(
        "https://api.github.com/repos/{}/releases/latest",
        repo.slug()
    );
    let body = match curl(&[&url]) {
        Ok(b) => b,
        Err(e) if e.contains("404") => return Ok(None), // no releases
        Err(e) => return Err(e),
    };
    let v: serde_json::Value =
        serde_json::from_slice(&body).map_err(|e| format!("GitHub API: {e}"))?;
    let assets = v["assets"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| {
                    Some(Asset {
                        name: x["name"].as_str()?.to_string(),
                        url: x["browser_download_url"].as_str()?.to_string(),
                        size: x["size"].as_u64().unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(Some(Release {
        tag: v["tag_name"].as_str().unwrap_or("").to_string(),
        assets,
    }))
}

/// Downloads an asset to `dest` and verifies it against the release's checksum files if any.
/// Returns whether a checksum was verified (false = none published; the UI should say so).
pub fn download_verified(release: &Release, asset: &Asset, dest: &Path) -> Result<bool, String> {
    let dest_s = dest.to_str().ok_or("bad destination path")?;
    curl(&["-o", dest_s, &asset.url])?;
    let texts: Vec<(String, String)> = release
        .assets
        .iter()
        .filter(|a| is_checksum_file(&a.name) && a.size < 1_000_000)
        .map(|a| {
            // A checksum that exists but can't be fetched must not turn into "unverified".
            curl(&[&a.url])
                .map(|b| (a.name.clone(), String::from_utf8_lossy(&b).into_owned()))
                .map_err(|e| format!("couldn't fetch the checksum {}: {e}", a.name))
        })
        .collect::<Result<_, _>>()
        .inspect_err(|_| {
            let _ = std::fs::remove_file(dest);
        })?;
    let Some(expected) = find_checksum(&asset.name, &texts) else {
        return Ok(false);
    };
    let actual = sha256_file(dest)?;
    if actual != expected {
        let _ = std::fs::remove_file(dest);
        return Err(format!(
            "checksum mismatch for {}: expected {expected}, got {actual}",
            asset.name
        ));
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn asset(name: &str, size: u64) -> Asset {
        Asset {
            name: name.into(),
            url: format!("https://x/{name}"),
            size,
        }
    }

    #[test]
    fn parses_repo_links() {
        let r = Repo {
            owner: "neovim".into(),
            name: "neovim".into(),
        };
        for s in [
            "https://github.com/neovim/neovim",
            "https://github.com/neovim/neovim/releases/latest",
            "github.com/neovim/neovim.git",
            "git@github.com:neovim/neovim.git",
            "neovim/neovim",
            "https://github.com/neovim/neovim?tab=readme",
        ] {
            assert_eq!(parse_repo(s).as_ref(), Some(&r), "{s}");
        }
        assert!(parse_repo("https://github.com/onlyowner").is_none());
        assert!(parse_repo("https://github.com/a b/c").is_none());
    }

    #[test]
    fn flathub_wins_when_it_has_the_repo() {
        let apps = vec![App {
            id: "io.neovim.nvim".into(),
            vcs_browser: Some("https://github.com/Neovim/Neovim".into()),
            ..Default::default()
        }];
        assert_eq!(
            flathub_match(&apps, &parse_repo("neovim/neovim").unwrap())
                .unwrap()
                .id,
            "io.neovim.nvim"
        );
        assert!(flathub_match(&apps, &parse_repo("other/thing").unwrap()).is_none());
    }

    #[test]
    fn asset_preference() {
        let assets = vec![
            asset("app-1.0.tar.gz", 10), // source tarball (no "linux"): ignored
            asset("app-1.0-linux-x86_64.tar.gz", 50),
            asset("app_1.0_amd64.deb", 40),
            asset("App-1.0-aarch64.AppImage", 30), // other arch: ignored
            asset("App-1.0-x86_64.AppImage", 60),
            asset("SHA256SUMS", 1),
        ];
        let (k, a) = choose_asset(&assets).unwrap();
        assert_eq!(k, Kind::AppImage);
        assert_eq!(a.name, "App-1.0-x86_64.AppImage");
        let only_deb = vec![
            asset("app_1.0_amd64.deb", 40),
            asset("app_1.0_arm64.deb", 40),
        ];
        assert_eq!(choose_asset(&only_deb).unwrap().0, Kind::Deb);
        assert!(choose_asset(&[asset("app-src.tar.gz", 1), asset("notes.txt", 1)]).is_none());
        assert_eq!(
            choose_asset(&[asset("x.flatpak", 9), asset("x.AppImage", 1)])
                .unwrap()
                .0,
            Kind::Flatpak
        );
        // A hidden top candidate falls back to the next one.
        assert_eq!(
            choose_asset(&[asset(".x.flatpak", 9), asset("x.AppImage", 1)])
                .unwrap()
                .1
                .name,
            "x.AppImage"
        );
    }

    #[test]
    fn checksums_from_sums_file_or_single_file() {
        let h = "a".repeat(64);
        let sums = vec![(
            "SHA256SUMS".to_string(),
            format!("{h}  App-x86_64.AppImage\n{}  other.deb\n", "b".repeat(64)),
        )];
        assert_eq!(find_checksum("App-x86_64.AppImage", &sums), Some(h.clone()));
        assert_eq!(find_checksum("missing.deb", &sums), None);
        let single = vec![(
            "app.deb.sha256".to_string(),
            format!("{}\n", "C".repeat(64)),
        )];
        assert_eq!(find_checksum("app.deb", &single), Some("c".repeat(64)));
        let starred = vec![("checksums.txt".to_string(), format!("{h} *app.flatpak\n"))];
        assert_eq!(find_checksum("app.flatpak", &starred), Some(h.clone()));
        let pathed = vec![(
            "SHA256SUMS".to_string(),
            format!("{h}  ./App.AppImage\n{}  dist/app.deb\n", "b".repeat(64)),
        )];
        assert_eq!(find_checksum("App.AppImage", &pathed), Some(h));
        assert_eq!(find_checksum("app.deb", &pathed), Some("b".repeat(64)));
    }
}
