//! Downloaded images (app screenshots) kept in a cache folder, so a page opened twice fetches once.
//! `prune` deletes the ones not used for a month.

use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// Largest image the store will download (Flathub's thumbnails are well under 1 MB).
const MAX_BYTES: &str = "20000000";

/// Where `url` is cached in `dir`: a hash of the link, keeping its extension.
pub fn path_for(dir: &Path, url: &str) -> PathBuf {
    let hash: String = Sha256::digest(url.as_bytes())
        .iter()
        .take(12)
        .map(|b| format!("{b:02x}"))
        .collect();
    let ext = url
        .rsplit('/')
        .next()
        .and_then(|name| name.rsplit_once('.'))
        .map(|(_, e)| e.to_ascii_lowercase())
        .filter(|e| matches!(e.as_str(), "png" | "jpg" | "jpeg" | "webp"))
        .unwrap_or_else(|| "img".to_string());
    dir.join(format!("{hash}.{ext}"))
}

/// The cached copy of an https image, downloading it first if needed (blocking: run it off the UI thread).
pub fn fetch(dir: &Path, url: &str) -> Result<PathBuf, String> {
    if !url.starts_with("https://") {
        return Err(format!("not an https link: {url}"));
    }
    let dest = path_for(dir, url);
    if dest.exists() {
        // Used again: its time restarts, so `prune` keeps it.
        let _ = std::fs::File::options()
            .append(true)
            .open(&dest)
            .and_then(|f| f.set_modified(std::time::SystemTime::now()));
        return Ok(dest);
    }
    std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let part = dest.with_extension("part");
    let part_s = part.to_str().ok_or("bad cache path")?;
    let r = crate::github::curl(&["--max-filesize", MAX_BYTES, "-o", part_s, url]);
    if let Err(e) = r {
        let _ = std::fs::remove_file(&part);
        return Err(e);
    }
    std::fs::rename(&part, &dest).map_err(|e| e.to_string())?;
    Ok(dest)
}

/// Deletes cached images not used for `max_age`, and downloads that never finished. Returns how many.
pub fn prune(dir: &Path, max_age: std::time::Duration) -> usize {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    let now = std::time::SystemTime::now();
    entries
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .filter(|e| {
            e.metadata()
                .and_then(|m| m.modified())
                .is_ok_and(|t| now.duration_since(t).unwrap_or_default() > max_age)
        })
        .filter(|e| std::fs::remove_file(e.path()).is_ok())
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cache_names_are_stable_and_keep_image_extensions() {
        let d = Path::new("/c");
        let a = path_for(d, "https://dl.flathub.org/media/x/624x351/shot.PNG");
        assert_eq!(
            a,
            path_for(d, "https://dl.flathub.org/media/x/624x351/shot.PNG")
        );
        assert!(a.to_str().unwrap().ends_with(".png"));
        assert_ne!(
            a,
            path_for(d, "https://dl.flathub.org/media/y/624x351/shot.png")
        );
        assert!(path_for(d, "https://example.org/noext")
            .to_str()
            .unwrap()
            .ends_with(".img"));
        assert!(path_for(d, "https://example.org/a.exe")
            .to_str()
            .unwrap()
            .ends_with(".img"));
    }

    #[test]
    fn only_https_is_fetched() {
        assert!(fetch(Path::new("/nonexistent"), "http://example.org/a.png").is_err());
    }

    #[test]
    fn prune_drops_only_old_files() {
        let d = std::env::temp_dir().join(format!("ost-cache-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let (old, new) = (d.join("old.png"), d.join("new.png"));
        std::fs::write(&old, b"x").unwrap();
        std::fs::write(&new, b"x").unwrap();
        let month = std::time::Duration::from_secs(30 * 86400);
        std::fs::File::options()
            .append(true)
            .open(&old)
            .unwrap()
            .set_modified(std::time::SystemTime::now() - month * 2)
            .unwrap();
        assert_eq!(prune(&d, month), 1);
        assert!(!old.exists() && new.exists());
        std::fs::remove_dir_all(&d).unwrap();
    }
}
