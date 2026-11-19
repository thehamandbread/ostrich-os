//! Installing what `github` found: a release asset, downloaded and verified, becomes an app.
//!
//! | kind      | how                                                     | where                      |
//! |-----------|---------------------------------------------------------|----------------------------|
//! | .flatpak  | `flatpak install --user --bundle` (.flatpakref: --from) | the user's flatpak         |
//! | AppImage  | unpacked (--appimage-extract), launcher on its AppRun   | ~/.local/share/…/github/   |
//! | .deb      | `pkexec apt-get install ./file.deb` (runs as root)      | the system                 |
//! | tarball   | extracted, the program found, launcher written          | ~/.local/share/…/github/   |
//!
//! Every install is recorded in github-apps.json (repo, release tag, asset, files, and a Flatpak's
//! or .deb's package name) so updates can be checked against the repo's latest release and the app
//! removed cleanly (`remove`).

use crate::github::{Kind, Repo};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct Dirs {
    /// Our data dir: ~/.local/share/ubuntu-ostrich
    pub data: PathBuf,
    /// Launchers: ~/.local/share/applications
    pub applications: PathBuf,
}

impl Dirs {
    pub fn from_env() -> Option<Dirs> {
        let share = std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))?;
        Some(Dirs {
            data: share.join("ubuntu-ostrich"),
            applications: share.join("applications"),
        })
    }

    /// `owner_name`: GitHub owners can't contain `_`, so `a-b/c` and `a/b-c` never share a folder
    /// (they did with `-`, and installing one replaced the other).
    pub fn app_dir(&self, repo: &Repo) -> PathBuf {
        self.data.join("github").join(dir_name(repo))
    }

    /// Where an install before the `_` names put it; removed on update and on remove.
    fn legacy_paths(&self, repo: &Repo) -> [PathBuf; 2] {
        [
            self.data
                .join("github")
                .join(format!("{}-{}", repo.owner, repo.name)),
            self.applications
                .join(format!("ost-github-{}-{}.desktop", repo.owner, repo.name)),
        ]
    }

    pub fn downloads(&self) -> PathBuf {
        self.data.join("downloads")
    }

    fn manifest(&self) -> PathBuf {
        self.data.join("github-apps.json")
    }

    fn desktop_file(&self, repo: &Repo) -> PathBuf {
        self.applications
            .join(format!("ost-github-{}_{}.desktop", repo.owner, repo.name))
    }
}

fn dir_name(repo: &Repo) -> String {
    format!("{}_{}", repo.owner, repo.name)
}

const HELPER: &str = "/usr/libexec/ubuntu-ostrich/system-helper";

/// The system helper's AppArmor profile for an app (tools/system-helper/src/apparmor.rs).
fn sandbox_profile(repo: &Repo) -> PathBuf {
    PathBuf::from(format!(
        "/etc/apparmor.d/ubuntu-ostrich-github-{}",
        dir_name(repo)
    ))
}

/// The folder and launcher an older version of the store used for this repo (`owner-name`).
fn remove_legacy(dirs: &Dirs, repo: &Repo) {
    for p in dirs.legacy_paths(repo) {
        let _ = if p.is_dir() {
            fs::remove_dir_all(&p)
        } else {
            fs::remove_file(&p)
        };
    }
}

/// The launcher for a program installed from a repo. Names come from `parse_repo`, which only
/// allows [A-Za-z0-9._-], so they're safe in a .desktop file.
/// `name` and `icon` come from the app itself when it has them (an AppImage's own .desktop and
/// .DirIcon); else the repo's name and a generic icon.
pub fn desktop_entry(
    repo: &Repo,
    tag: &str,
    exec: &Path,
    name: Option<&str>,
    icon: Option<&Path>,
) -> String {
    let exec = exec
        .to_string_lossy()
        .replace('\\', "\\\\")
        .replace('"', "\\\"");
    let icon = icon.map_or("application-x-executable".into(), |p| p.to_string_lossy());
    format!(
        "[Desktop Entry]\nType=Application\nName={}\nComment=Installed from github.com/{} ({})\nExec=\"{}\"\nIcon={}\nCategories=Utility;\nTerminal=false\n",
        name.unwrap_or(&repo.name),
        repo.slug(),
        tag,
        exec,
        icon
    )
}

/// The Name= of the .desktop file an AppImage carries at its top, if it has one.
fn appimage_name(app: &Path) -> Option<String> {
    let desktop = fs::read_dir(app)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .find(|p| p.extension().is_some_and(|x| x == "desktop"))?;
    fs::read_to_string(desktop)
        .ok()?
        .lines()
        .find_map(|l| l.strip_prefix("Name="))
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .map(str::to_string)
}

/// The program in an extracted tarball: named like the repo, else in bin/ named like it, else the
/// only executable near the top. `files` are (path relative to the extract dir, is executable).
pub fn find_program(files: &[(PathBuf, bool)], repo: &Repo) -> Option<PathBuf> {
    let want = repo.name.to_lowercase();
    let shallow: Vec<&Path> = files
        .iter()
        .filter(|(p, x)| *x && p.components().count() <= 3)
        .map(|(p, _)| p.as_path())
        .collect();
    let name_of = |p: &Path| {
        p.file_name()
            .map(|n| n.to_string_lossy().to_lowercase())
            .unwrap_or_default()
    };
    if let Some(p) = shallow.iter().find(|p| name_of(p) == want) {
        return Some(p.to_path_buf());
    }
    // Shared libraries and helper scripts are executable too, but they aren't the program.
    let candidates: Vec<&Path> = shallow
        .into_iter()
        .filter(|p| {
            let n = name_of(p);
            !n.contains(".so") && !n.ends_with(".sh")
        })
        .collect();
    match candidates.as_slice() {
        [only] => Some(only.to_path_buf()),
        _ => None,
    }
}

fn walk(root: &Path, dir: &Path, out: &mut Vec<(PathBuf, bool)>) {
    use std::os::unix::fs::PermissionsExt;
    let Ok(it) = fs::read_dir(dir) else { return };
    for e in it.flatten() {
        let p = e.path();
        let Ok(m) = fs::symlink_metadata(&p) else {
            continue;
        };
        if m.is_dir() {
            walk(root, &p, out);
        } else if m.is_file() {
            let rel = p.strip_prefix(root).unwrap_or(&p).to_path_buf();
            out.push((rel, m.permissions().mode() & 0o111 != 0));
        }
    }
}

fn run(argv: &[&str]) -> Result<(), String> {
    let status = Command::new(argv[0])
        .args(&argv[1..])
        .status()
        .map_err(|e| format!("{}: {e}", argv[0]))?;
    status
        .success()
        .then_some(())
        .ok_or_else(|| format!("{} failed ({status})", argv.join(" ")))
}

pub struct Installed {
    pub summary: String,
    /// Our files and launcher, empty for flatpak/deb (their own package managers track them).
    pub files: Vec<PathBuf>,
    /// A Flatpak's app id or a .deb's package name, for removing it.
    pub package: Option<String>,
}

/// Installs a downloaded asset. `file` is the verified download; `asset` its release file name.
pub fn install(
    dirs: &Dirs,
    repo: &Repo,
    tag: &str,
    kind: &Kind,
    asset: &str,
    file: &Path,
) -> Result<Installed, String> {
    let path = file.to_str().ok_or("bad download path")?;
    let result = match kind {
        Kind::Flatpak => {
            let how = if asset.ends_with(".flatpakref") {
                "--from"
            } else {
                "--bundle"
            };
            let before = flatpak_apps();
            run(&[
                "flatpak",
                "install",
                "--user",
                "-y",
                "--noninteractive",
                how,
                path,
            ])?;
            // The bundle's app id isn't in its name: the app that wasn't there before. (An update
            // adds none, and keeps the id recorded at the first install.)
            let new: Vec<String> = flatpak_apps()
                .into_iter()
                .filter(|a| !before.contains(a))
                .collect();
            Installed {
                summary: format!("installed {asset} into your Flatpak apps"),
                files: vec![],
                package: match new.as_slice() {
                    [one] => Some(one.clone()),
                    _ => None,
                },
            }
        }
        Kind::Deb => {
            run(&["pkexec", "apt-get", "install", "-y", path])?;
            Installed {
                summary: format!("installed {asset} with apt"),
                files: vec![],
                package: deb_field(file, "Package"),
            }
        }
        Kind::AppImage => {
            let (app, note) = unpack_appimage(dirs, repo, file)?;
            remove_legacy(dirs, repo);
            let icon = app.join(".DirIcon");
            let name = appimage_name(&app);
            let desktop = write_launcher(
                dirs,
                repo,
                tag,
                &app.join("AppRun"),
                name.as_deref(),
                icon.exists().then_some(icon.as_path()),
            )?;
            Installed {
                summary: format!(
                    "installed {asset}; it's in the app grid as {}{note}",
                    name.as_deref().unwrap_or(&repo.name)
                ),
                files: vec![dirs.app_dir(repo), desktop],
                package: None,
            }
        }
        Kind::Tarball => {
            let dir = dirs.app_dir(repo);
            // Extract next to the old version and swap only on success, so a failed update keeps it.
            let new = PathBuf::from(format!("{}.new", dir.display()));
            let _ = fs::remove_dir_all(&new);
            fs::create_dir_all(&new).map_err(|e| e.to_string())?;
            let d = new.to_str().ok_or("bad app dir")?;
            if let Err(e) = run(&["tar", "-xf", path, "-C", d, "--no-same-owner"]) {
                let _ = fs::remove_dir_all(&new);
                return Err(e);
            }
            let _ = fs::remove_dir_all(&dir);
            fs::rename(&new, &dir).map_err(|e| e.to_string())?;
            remove_legacy(dirs, repo);
            let mut files = Vec::new();
            walk(&dir, &dir, &mut files);
            match find_program(&files, repo) {
                Some(rel) => {
                    let desktop = write_launcher(dirs, repo, tag, &dir.join(&rel), None, None)?;
                    Installed {
                        summary: format!(
                            "installed {}; it's in the app grid as {}",
                            rel.display(),
                            repo.name
                        ),
                        files: vec![dir, desktop],
                        package: None,
                    }
                }
                None => Installed {
                    summary: format!(
                        "extracted to {}, but couldn't tell which file is the program; no launcher made",
                        dir.display()
                    ),
                    files: vec![dir],
                    package: None,
                },
            }
        }
    };
    record(dirs, repo, tag, kind, asset, &result)?;
    Ok(result)
}

fn write_launcher(
    dirs: &Dirs,
    repo: &Repo,
    tag: &str,
    exec: &Path,
    name: Option<&str>,
    icon: Option<&Path>,
) -> Result<PathBuf, String> {
    fs::create_dir_all(&dirs.applications).map_err(|e| e.to_string())?;
    let f = dirs.desktop_file(repo);
    fs::write(&f, desktop_entry(repo, tag, exec, name, icon)).map_err(|e| e.to_string())?;
    Ok(f)
}

/// Unpacks an AppImage into `<app dir>/app` and returns that folder, plus a note for the summary.
/// Unpacked rather than run as an AppImage: stock Ubuntu has no libfuse2 to mount one, and the
/// sandbox profile needs a fixed path (an AppImage runs from /tmp/.mount_<random>).
fn unpack_appimage(dirs: &Dirs, repo: &Repo, file: &Path) -> Result<(PathBuf, String), String> {
    use std::os::unix::fs::PermissionsExt;
    let dir = dirs.app_dir(repo);
    // Unpacked beside the old version, swapped in only once it worked: a failed update keeps it.
    let work = dir.join(".new");
    let _ = fs::remove_dir_all(&work);
    fs::create_dir_all(&work).map_err(|e| e.to_string())?;
    let image = work.join("image.AppImage");
    fs::copy(file, &image).map_err(|e| e.to_string())?;
    fs::set_permissions(&image, fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
    // A thread forking elsewhere while the copy was still open for writing leaves it "busy" for a
    // moment (ETXTBSY): try again shortly.
    let mut tries = 0;
    let unpacked = loop {
        let status = Command::new(&image)
            .arg("--appimage-extract")
            .current_dir(&work)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
        match status {
            Err(e) if e.raw_os_error() == Some(26) && tries < 20 => {
                tries += 1;
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            other => break other.is_ok_and(|s| s.success()),
        }
    };
    let root = work.join("squashfs-root");
    if !unpacked || !root.join("AppRun").exists() {
        let _ = fs::remove_dir_all(&work);
        return Err("couldn't unpack the AppImage (it may be an old type-1 AppImage)".into());
    }
    let app = dir.join("app");
    let _ = fs::remove_dir_all(&app);
    fs::rename(&root, &app).map_err(|e| e.to_string())?;
    // Everything else goes: the work folder, and the AppImage file earlier versions kept here.
    for old in fs::read_dir(&dir).map_err(|e| e.to_string())?.flatten() {
        let p = old.path();
        if p != app {
            let _ = if p.is_dir() {
                fs::remove_dir_all(&p)
            } else {
                fs::remove_file(&p)
            };
        }
    }
    // Electron apps ship chrome-sandbox: they need the profile, or they abort at start.
    let note = if !app.join("chrome-sandbox").exists() || sandbox_profile(repo).exists() {
        String::new()
    } else {
        match run(&["pkexec", HELPER, "apparmor", "allow", &dir_name(repo)]) {
            Ok(()) => String::new(),
            Err(_) => ". It won't start until it may use its sandbox: install it again and enter your password when asked".to_string(),
        }
    };
    Ok((app, note))
}

fn kind_name(k: &Kind) -> &'static str {
    match k {
        Kind::Flatpak => "flatpak",
        Kind::AppImage => "appimage",
        Kind::Deb => "deb",
        Kind::Tarball => "tarball",
    }
}

/// The manifest: { "owner/name": {tag, kind, asset, files} }.
/// The maintainer scripts a .deb carries (they run as root when it's installed), from `dpkg-deb -I`.
pub fn deb_scripts(path: &Path) -> Vec<String> {
    Command::new("dpkg-deb")
        .arg("-I")
        .arg(path)
        .output()
        .map(|o| parse_deb_scripts(&String::from_utf8_lossy(&o.stdout)))
        .unwrap_or_default()
}

/// `dpkg-deb -I` lists the control archive's members as "  N bytes,  M lines  [*] NAME  ...".
pub fn parse_deb_scripts(info: &str) -> Vec<String> {
    const SCRIPTS: [&str; 5] = ["preinst", "postinst", "prerm", "postrm", "config"];
    info.lines()
        .filter(|l| l.contains(" bytes,"))
        .filter_map(|l| {
            l.split_whitespace()
                .find(|w| SCRIPTS.contains(w))
                .map(str::to_string)
        })
        .collect()
}

pub fn read_manifest(dirs: &Dirs) -> Value {
    fs::read(dirs.manifest())
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}))
}

fn record(
    dirs: &Dirs,
    repo: &Repo,
    tag: &str,
    kind: &Kind,
    asset: &str,
    done: &Installed,
) -> Result<(), String> {
    let mut m = read_manifest(dirs);
    let package = done
        .package
        .clone()
        .or_else(|| m[repo.slug()]["package"].as_str().map(str::to_string));
    m[repo.slug()] = json!({
        "tag": tag,
        "kind": kind_name(kind),
        "asset": asset,
        "files": done.files.iter().map(|f| f.to_string_lossy()).collect::<Vec<_>>(),
        "package": package,
    });
    write_manifest(dirs, &m)
}

fn write_manifest(dirs: &Dirs, m: &Value) -> Result<(), String> {
    fs::create_dir_all(&dirs.data).map_err(|e| e.to_string())?;
    let text = serde_json::to_string_pretty(m).map_err(|e| e.to_string())?;
    fs::write(dirs.manifest(), text).map_err(|e| e.to_string())
}

/// How an app from GitHub is named in the store's list of updates, beside Flatpak app ids.
pub const UPDATE_PREFIX: &str = "github:";

/// Apps from GitHub whose latest release isn't the one installed: ("github:owner/name", new tag).
/// Asks GitHub (network); a repo it can't reach this time is left out.
pub fn updates(dirs: &Dirs) -> Vec<(String, String)> {
    let m = read_manifest(dirs);
    let Some(apps) = m.as_object() else {
        return Vec::new();
    };
    apps.iter()
        .filter_map(|(slug, v)| {
            let repo = crate::github::parse_repo(slug)?;
            let latest = crate::github::latest_release(&repo).ok()??;
            let newer = !latest.tag.is_empty() && v["tag"].as_str() != Some(latest.tag.as_str());
            (newer || needs_repair(dirs, &repo))
                .then(|| (format!("{UPDATE_PREFIX}{slug}"), latest.tag))
        })
        .collect()
}

/// An AppImage installed the way the store did before 0.4.1 (the file itself, which needs libfuse2
/// and can't get a sandbox profile), or an Electron one still without its profile (the password was
/// cancelled): installing it again, even the same release, fixes it.
pub fn needs_repair(dirs: &Dirs, repo: &Repo) -> bool {
    if read_manifest(dirs)[repo.slug()]["kind"].as_str() != Some("appimage") {
        return false;
    }
    let app = dirs.app_dir(repo).join("app");
    !app.join("AppRun").exists()
        || (app.join("chrome-sandbox").exists() && !sandbox_profile(repo).exists())
}

/// The release tag installed from a repo, if it was installed by the store.
pub fn installed_tag(dirs: &Dirs, repo: &Repo) -> Option<String> {
    read_manifest(dirs)[repo.slug()]["tag"]
        .as_str()
        .map(str::to_string)
}

/// Removes an app installed from a repo: an AppImage's or tarball's folder and launcher (found from
/// the repo, not from paths in the manifest), a Flatpak or .deb through its own package manager.
/// Then forgets it. Blocking (a .deb asks for a password): run it off the UI thread.
pub fn remove(dirs: &Dirs, repo: &Repo) -> Result<String, String> {
    let mut m = read_manifest(dirs);
    let entry = m[repo.slug()].clone();
    if entry.is_null() {
        return Err(format!("{} wasn't installed by the store", repo.slug()));
    }
    // A package name from the manifest goes on a command line: it must look like one.
    let package = entry["package"].as_str().filter(|p| {
        p.starts_with(|c: char| c.is_ascii_alphanumeric())
            && p.chars()
                .all(|c| c.is_ascii_alphanumeric() || "._+-".contains(c))
    });
    let summary = match (entry["kind"].as_str(), package) {
        (Some("flatpak"), Some(id)) => {
            run(&[
                "flatpak",
                "uninstall",
                "--user",
                "-y",
                "--noninteractive",
                id,
            ])?;
            format!("removed {id}")
        }
        (Some("deb"), Some(pkg)) => {
            run(&["pkexec", "apt-get", "remove", "-y", pkg])?;
            format!("removed the {pkg} package")
        }
        (Some("flatpak" | "deb"), None) => {
            return Err(format!(
                "the store didn't record which package {} installed; remove it with Flatpak or apt",
                repo.slug()
            ))
        }
        _ => {
            remove_legacy(dirs, repo);
            for p in [dirs.app_dir(repo), dirs.desktop_file(repo)] {
                let gone = if p.is_dir() {
                    fs::remove_dir_all(&p)
                } else {
                    fs::remove_file(&p)
                };
                if let Err(e) = gone {
                    if e.kind() != std::io::ErrorKind::NotFound {
                        return Err(format!("{}: {e}", p.display()));
                    }
                }
            }
            if sandbox_profile(repo).exists() {
                // Asks for a password; if it's cancelled the profile only covers an empty folder.
                let _ = run(&["pkexec", HELPER, "apparmor", "remove", &dir_name(repo)]);
            }
            format!("removed {} and its launcher", repo.name)
        }
    };
    if let Some(o) = m.as_object_mut() {
        o.remove(&repo.slug());
    }
    write_manifest(dirs, &m)?;
    Ok(summary)
}

/// The user's Flatpak apps (ids), to tell which one a bundle installed.
fn flatpak_apps() -> Vec<String> {
    Command::new("flatpak")
        .args(["list", "--user", "--app", "--columns=application"])
        .output()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

/// A field of a .deb's control file (`dpkg-deb -f`).
fn deb_field(path: &Path, field: &str) -> Option<String> {
    let out = Command::new("dpkg-deb")
        .arg("-f")
        .arg(path)
        .arg(field)
        .output()
        .ok()?;
    let v = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !v.is_empty()).then_some(v)
}

#[cfg(test)]
mod tests {
    #[test]
    fn deb_scripts_from_dpkg_deb_info() {
        let info = " new Debian package, version 2.0.\n size 1234 bytes: control archive=567 bytes.\n     412 bytes,    12 lines      control\n     250 bytes,     9 lines   *  postinst             #!/bin/sh\n     180 bytes,     7 lines   *  prerm                #!/bin/sh\n Package: tool\n";
        assert_eq!(super::parse_deb_scripts(info), vec!["postinst", "prerm"]);
        assert!(super::parse_deb_scripts(" Package: tool\n").is_empty());
    }

    use super::*;

    fn repo(name: &str) -> Repo {
        Repo {
            owner: "someone".into(),
            name: name.into(),
        }
    }

    fn files(list: &[(&str, bool)]) -> Vec<(PathBuf, bool)> {
        list.iter().map(|(p, x)| (PathBuf::from(p), *x)).collect()
    }

    #[test]
    fn finds_the_program_by_name() {
        let f = files(&[
            ("Tool-1.2/README", false),
            ("Tool-1.2/libfoo.so.1", true),
            ("Tool-1.2/tool", true),
            ("Tool-1.2/helper", true),
        ]);
        assert_eq!(
            find_program(&f, &repo("Tool")),
            Some(PathBuf::from("Tool-1.2/tool"))
        );
    }

    #[test]
    fn falls_back_to_the_only_executable() {
        let f = files(&[
            ("app/bin/myapp-gui", true),
            ("app/lib/libx.so", true),
            ("app/README", false),
        ]);
        assert_eq!(
            find_program(&f, &repo("other")),
            Some(PathBuf::from("app/bin/myapp-gui"))
        );
        let two = files(&[("a/one", true), ("a/two", true)]);
        assert_eq!(find_program(&two, &repo("other")), None);
        let deep = files(&[("a/b/c/d/tool", true)]);
        assert_eq!(find_program(&deep, &repo("tool")), None);
    }

    #[test]
    fn launcher_quotes_the_path() {
        let d = desktop_entry(
            &repo("tool"),
            "v1.0",
            Path::new("/home/u/My Apps/tool"),
            None,
            None,
        );
        assert!(d.contains("Exec=\"/home/u/My Apps/tool\"\n"));
        assert!(d.contains("Name=tool\n") && d.contains("github.com/someone/tool (v1.0)"));
        assert!(d.contains("Icon=application-x-executable\n"));
        let own = desktop_entry(
            &repo("tool"),
            "v1.0",
            Path::new("/x/AppRun"),
            Some("Tool Pro"),
            Some(Path::new("/x/.DirIcon")),
        );
        assert!(own.contains("Name=Tool Pro\n") && own.contains("Icon=/x/.DirIcon\n"));
    }

    /// A stand-in AppImage: a script that unpacks like one (`--appimage-extract` → squashfs-root/).
    fn fake_appimage(root: &Path) -> PathBuf {
        fs::create_dir_all(root).unwrap();
        let dl = root.join("Tool-x86_64.AppImage");
        fs::write(
            &dl,
            "#!/bin/sh\n[ \"$1\" = --appimage-extract ] || exit 1\nmkdir -p squashfs-root\nprintf '#!/bin/sh\\n' > squashfs-root/AppRun\nprintf '[Desktop Entry]\\nName=Tool Pro\\n' > squashfs-root/tool.desktop\ntouch squashfs-root/.DirIcon\n",
        )
        .unwrap();
        dl
    }

    #[test]
    fn a_file_that_does_not_unpack_is_refused_and_the_old_app_kept() {
        let root = std::env::temp_dir().join(format!("ost-ghbad-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let dirs = Dirs {
            data: root.join("data"),
            applications: root.join("apps"),
        };
        let r = repo("tool");
        let good = fake_appimage(&root);
        install(
            &dirs,
            &r,
            "v1",
            &Kind::AppImage,
            "Tool-x86_64.AppImage",
            &good,
        )
        .unwrap();
        let bad = root.join("bad.AppImage");
        fs::write(&bad, "#!/bin/sh\nexit 1\n").unwrap();
        assert!(install(&dirs, &r, "v2", &Kind::AppImage, "bad.AppImage", &bad).is_err());
        assert!(dirs.app_dir(&r).join("app/AppRun").exists());
        assert!(!dirs.app_dir(&r).join(".new").exists());
        assert_eq!(installed_tag(&dirs, &r).as_deref(), Some("v1"));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn appimage_install_writes_launcher_and_manifest() {
        let root = std::env::temp_dir().join(format!("ost-ghinst-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let dirs = Dirs {
            data: root.join("data"),
            applications: root.join("apps"),
        };
        fs::create_dir_all(&root).unwrap();
        let dl = fake_appimage(&root);
        let r = repo("tool");
        let got = install(
            &dirs,
            &r,
            "v2",
            &Kind::AppImage,
            "Tool-x86_64.AppImage",
            &dl,
        )
        .unwrap();
        let exe = dirs.app_dir(&r).join("app/AppRun");
        assert!(exe.exists());
        // Only the unpacked app is kept: no copy of the AppImage, no work folder.
        let kept: Vec<_> = fs::read_dir(dirs.app_dir(&r))
            .unwrap()
            .flatten()
            .map(|e| e.file_name())
            .collect();
        assert_eq!(kept, vec![std::ffi::OsString::from("app")]);
        let launcher = fs::read_to_string(dirs.desktop_file(&r)).unwrap();
        assert!(launcher.contains("Name=Tool Pro\n"), "{launcher}");
        assert!(launcher.contains("app/.DirIcon\n"), "{launcher}");
        assert!(fs::read_to_string(dirs.desktop_file(&r))
            .unwrap()
            .contains(&exe.to_string_lossy().to_string()));
        assert_eq!(got.files.len(), 2);
        let m = read_manifest(&dirs);
        assert_eq!(m["someone/tool"]["tag"], "v2");
        assert_eq!(m["someone/tool"]["kind"], "appimage");
        assert_eq!(installed_tag(&dirs, &r).as_deref(), Some("v2"));
        assert!(!needs_repair(&dirs, &r));
        // The way 0.4.0 left it (the AppImage file itself, no unpacked app): installing again fixes it.
        fs::remove_dir_all(dirs.app_dir(&r).join("app")).unwrap();
        fs::write(dirs.app_dir(&r).join("Tool-x86_64.AppImage"), "old").unwrap();
        assert!(needs_repair(&dirs, &r));

        // Removing it takes the folder and launcher, and forgets it; other apps' files stay.
        let other = dirs.data.join("github/someone-other");
        fs::create_dir_all(&other).unwrap();
        remove(&dirs, &r).unwrap();
        assert!(!dirs.app_dir(&r).exists() && !dirs.desktop_file(&r).exists());
        assert!(other.exists());
        assert!(installed_tag(&dirs, &r).is_none());
        assert!(remove(&dirs, &r).is_err());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn repos_whose_names_join_alike_get_their_own_folders() {
        let dirs = Dirs {
            data: PathBuf::from("/d"),
            applications: PathBuf::from("/a"),
        };
        let ab_c = Repo {
            owner: "a-b".into(),
            name: "c".into(),
        };
        let a_bc = Repo {
            owner: "a".into(),
            name: "b-c".into(),
        };
        assert_ne!(dirs.app_dir(&ab_c), dirs.app_dir(&a_bc));
        assert_ne!(dirs.desktop_file(&ab_c), dirs.desktop_file(&a_bc));
    }

    #[test]
    fn an_install_from_before_the_new_names_is_cleaned_up() {
        let root = std::env::temp_dir().join(format!("ost-ghlegacy-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let dirs = Dirs {
            data: root.join("data"),
            applications: root.join("apps"),
        };
        let r = repo("tool");
        let [old_dir, old_desktop] = dirs.legacy_paths(&r);
        fs::create_dir_all(&old_dir).unwrap();
        fs::create_dir_all(&dirs.applications).unwrap();
        fs::write(&old_desktop, "[Desktop Entry]\n").unwrap();
        let dl = fake_appimage(&root);
        install(
            &dirs,
            &r,
            "v3",
            &Kind::AppImage,
            "Tool-x86_64.AppImage",
            &dl,
        )
        .unwrap();
        assert!(!old_dir.exists() && !old_desktop.exists());
        assert!(dirs.app_dir(&r).join("app/AppRun").exists());
        let _ = fs::remove_dir_all(&root);
    }
}
