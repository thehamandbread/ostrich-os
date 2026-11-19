//! AppArmor profiles that let an app installed from GitHub by Ostrich Store use user namespaces.
//!
//! Ubuntu sets kernel.apparmor_restrict_unprivileged_userns=1, so an Electron app (Upscayl, …)
//! can't build its namespace sandbox and aborts. Ubuntu's answer is a profile that allows `userns`
//! for that program; the owner chose that over launching with --no-sandbox (2026-11-18).
//! The profile covers the app's unpacked folder, a glob, so updates don't need a new one.
//! The cost: anything the user puts in that folder may make user namespaces, as on stock Ubuntu
//! before 24.04.

use std::path::{Path, PathBuf};
use std::process::Command;

const DIR: &str = "/etc/apparmor.d";

/// The app's folder name as the store makes it (`owner_name`): GitHub's characters only, and no
/// leading dot, so it can't name `.` or `..` or anything outside the store's folder.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('.')
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
}

pub fn profile_name(name: &str) -> String {
    format!("ubuntu-ostrich-github-{name}")
}

/// shortcut: assumes the default XDG_DATA_HOME (~/.local/share), as the store does on Ubuntu;
/// pass the data dir through if anyone moves it.
pub fn profile(name: &str) -> String {
    let p = profile_name(name);
    format!(
        "# Ubuntu Ostrich: lets {name}, installed from GitHub by Ostrich Store, use its sandbox.\n\
         abi <abi/4.0>,\n\
         include <tunables/global>\n\
         \n\
         profile {p} @{{HOME}}/.local/share/ubuntu-ostrich/github/{name}/app/** flags=(default_allow) {{\n\
         \x20 userns,\n\
         }}\n"
    )
}

fn path(name: &str) -> PathBuf {
    Path::new(DIR).join(profile_name(name))
}

pub fn allow(name: &str) -> Result<String, String> {
    let f = path(name);
    std::fs::write(&f, profile(name)).map_err(|e| format!("{}: {e}", f.display()))?;
    let ok = Command::new("apparmor_parser")
        .arg("-r")
        .arg(&f)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if ok {
        Ok(format!("{name} may use its sandbox"))
    } else {
        let _ = std::fs::remove_file(&f);
        Err(format!("apparmor_parser couldn't load {}", f.display()))
    }
}

pub fn remove(name: &str) -> Result<String, String> {
    let f = path(name);
    if !f.exists() {
        return Ok(format!("no profile for {name}"));
    }
    // Unload first (it fails harmlessly if it isn't loaded), then the file.
    let _ = Command::new("apparmor_parser").arg("-R").arg(&f).status();
    std::fs::remove_file(&f).map_err(|e| format!("{}: {e}", f.display()))?;
    Ok(format!("removed the profile for {name}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_stay_inside_the_store_folder() {
        assert!(valid_name("upscayl_upscayl"));
        assert!(valid_name("a-b_c.d"));
        for bad in ["", ".", "..", ".hidden", "a/b", "a b", "a\nb", "a*"] {
            assert!(!valid_name(bad), "{bad:?}");
        }
    }

    #[test]
    fn profile_covers_the_unpacked_app_only() {
        let p = profile("upscayl_upscayl");
        assert!(p.contains(
            "profile ubuntu-ostrich-github-upscayl_upscayl @{HOME}/.local/share/ubuntu-ostrich/github/upscayl_upscayl/app/** flags=(default_allow) {\n  userns,\n}\n"
        ));
        assert!(p.starts_with("# Ubuntu Ostrich") && p.contains("abi <abi/4.0>,\n"));
    }
}
