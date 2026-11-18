//! store-core: the shared engine for the terminal store (store-tui) and the GTK store (store-gtk).
//!
//! Everything works from local data: flatpak keeps Flathub's AppStream catalogue on disk, so
//! searching never touches the network. Installs and updates go through the `flatpak` CLI.

pub mod appstream;
pub mod cache;
pub mod flatpak;
pub mod ghinstall;
pub mod github;
pub mod search;

use std::path::PathBuf;

/// The catalogue flatpak keeps for a remote (system installation first, then the user one).
pub fn catalogue_path(remote: &str) -> Option<PathBuf> {
    let arch = std::env::consts::ARCH;
    let mut roots = vec![PathBuf::from("/var/lib/flatpak")];
    if let Some(home) = std::env::var_os("HOME") {
        roots.push(PathBuf::from(home).join(".local/share/flatpak"));
    }
    roots
        .into_iter()
        .map(|r| r.join("appstream").join(remote).join(arch).join("active"))
        .flat_map(|d| [d.join("appstream.xml.gz"), d.join("appstream.xml")])
        .find(|p| p.exists())
}

/// Icon file for an app from the same catalogue folder (icons/<size>x<size>/<file>).
pub fn icon_path(catalogue: &std::path::Path, icon: &(String, u32)) -> Option<PathBuf> {
    let dir = catalogue.parent()?;
    let p = dir
        .join("icons")
        .join(format!("{0}x{0}", icon.1))
        .join(&icon.0);
    p.exists().then_some(p)
}
