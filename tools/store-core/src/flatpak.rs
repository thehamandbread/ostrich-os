//! Installed apps and actions through the `flatpak` CLI (no libflatpak bindings needed).

use std::process::{Child, Command, Stdio};

#[derive(Clone, Debug, PartialEq)]
pub struct Installed {
    pub id: String,
    pub version: String,
    pub origin: String,
    /// "system" or "user"
    pub installation: String,
}

/// Parses `flatpak list --app --columns=application,version,origin,installation` (tab-separated).
pub fn parse_list(text: &str) -> Vec<Installed> {
    text.lines()
        .filter_map(|line| {
            let mut f = line.split('\t');
            let id = f.next()?.trim();
            if id.is_empty() {
                return None;
            }
            Some(Installed {
                id: id.to_string(),
                version: f.next().unwrap_or("").trim().to_string(),
                origin: f.next().unwrap_or("").trim().to_string(),
                installation: f.next().unwrap_or("").trim().to_string(),
            })
        })
        .collect()
}

pub fn installed() -> Result<Vec<Installed>, String> {
    let out = Command::new("flatpak")
        .args([
            "list",
            "--app",
            "--columns=application,version,origin,installation",
        ])
        .output()
        .map_err(|e| format!("flatpak: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(parse_list(&String::from_utf8_lossy(&out.stdout)))
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Action {
    Install,
    Uninstall,
    Update,
}

/// The flatpak command line for an action (exposed for tests and for showing the user).
pub fn command_line(action: Action, remote: &str, id: &str) -> Vec<String> {
    let v: Vec<&str> = match action {
        Action::Install => vec!["flatpak", "install", "--noninteractive", "-y", remote, id],
        Action::Uninstall => vec!["flatpak", "uninstall", "--noninteractive", "-y", id],
        Action::Update => vec!["flatpak", "update", "--noninteractive", "-y", id],
    };
    v.into_iter().map(String::from).collect()
}

/// Starts an action; the caller reads its output (progress) and waits for it.
pub fn spawn(action: Action, remote: &str, id: &str) -> Result<Child, String> {
    let argv = command_line(action, remote, id);
    Command::new(&argv[0])
        .args(&argv[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("flatpak: {e}"))
}

/// The last percentage in a line of flatpak's progress output ("Installing 1/2… ███ 45%  3 MB/s").
pub fn parse_progress(line: &str) -> Option<f64> {
    let end = line.rfind('%')?;
    let digits: String = line[..end]
        .chars()
        .rev()
        .take_while(|c| c.is_ascii_digit())
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    let n: f64 = digits.parse().ok()?;
    (0.0..=100.0).contains(&n).then_some(n / 100.0)
}

/// Parses `flatpak remote-ls --updates --app --columns=application,version`: (id, new version).
pub fn parse_updates(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|line| {
            let mut f = line.split('\t');
            let id = f.next()?.trim();
            (!id.is_empty() && id.contains('.'))
                .then(|| (id.to_string(), f.next().unwrap_or("").trim().to_string()))
        })
        .collect()
}

/// Apps with an update waiting (asks the remotes: network).
pub fn updates() -> Result<Vec<(String, String)>, String> {
    let out = Command::new("flatpak")
        .args([
            "remote-ls",
            "--updates",
            "--app",
            "--columns=application,version",
        ])
        .output()
        .map_err(|e| format!("flatpak: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(parse_updates(&String::from_utf8_lossy(&out.stdout)))
}

/// What `flatpak remote-info` says about an app before it's installed.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RemoteInfo {
    pub version: String,
    pub download: String,
    pub installed: String,
    /// Plain-words permissions, from the app's metadata.
    pub permissions: Vec<String>,
}

/// Parses `flatpak remote-info REMOTE ID` ("    Download: 120.3 MB" lines).
pub fn parse_remote_info(text: &str) -> RemoteInfo {
    let mut info = RemoteInfo::default();
    for line in text.lines() {
        let Some((k, v)) = line.split_once(':') else {
            continue;
        };
        let v = v.trim().to_string();
        match k.trim() {
            "Version" => info.version = v,
            "Download" => info.download = v,
            "Installed" => info.installed = v,
            _ => {}
        }
    }
    info
}

/// The app's sandbox permissions in plain words, from its metadata keyfile
/// (`flatpak remote-info --show-metadata`). Routine ones (Wayland, the GPU, IPC) are left out.
pub fn parse_permissions(metadata: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut section = String::new();
    for line in metadata.lines().map(str::trim) {
        if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            section = name.to_string();
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let items = value.split(';').map(str::trim).filter(|v| !v.is_empty());
        match (section.as_str(), key.trim()) {
            ("Context", "shared") => {
                for v in items {
                    if v == "network" {
                        out.push("Network access".to_string());
                    }
                }
            }
            ("Context", "sockets") => {
                for v in items {
                    let s = match v {
                        "x11" => "The X11 display (older; it can see other X11 windows)",
                        "pulseaudio" => "Sound and the microphone",
                        "cups" => "Printing",
                        "ssh-auth" => "Your SSH keys (through the agent)",
                        "pcsc" => "Smart cards",
                        "gpg-agent" => "Your GPG keys (through the agent)",
                        "system-bus" => "All system services",
                        "session-bus" => "All session services",
                        _ => continue,
                    };
                    out.push(s.to_string());
                }
            }
            ("Context", "devices") => {
                for v in items {
                    let s = match v {
                        "all" => "All devices (webcam, USB, game controllers)",
                        "kvm" => "Virtual machines (KVM)",
                        "input" => "Input devices",
                        "usb" => "USB devices",
                        _ => continue,
                    };
                    out.push(s.to_string());
                }
            }
            ("Context", "filesystems") => {
                for v in items {
                    if v.starts_with('!') {
                        continue;
                    }
                    let (path, ro) = match v.rsplit_once(':') {
                        Some((p, "ro")) => (p, true),
                        Some((p, "rw" | "create")) => (p, false),
                        _ => (v, false),
                    };
                    let place = match path {
                        "host" => "All your files and the system's".to_string(),
                        "host-os" => "The system's programs and libraries".to_string(),
                        "host-etc" => "The system's settings (/etc)".to_string(),
                        "home" | "~" => "Your home folder".to_string(),
                        p if p.starts_with("xdg-") => {
                            let name = p.trim_start_matches("xdg-").split('/').next().unwrap_or("");
                            let mut c = name.chars();
                            match c.next() {
                                Some(f) => {
                                    format!("Your {}{} folder", f.to_uppercase(), c.as_str())
                                }
                                None => continue,
                            }
                        }
                        p => format!("Files in {p}"),
                    };
                    out.push(if ro {
                        format!("{place} (read only)")
                    } else {
                        place
                    });
                }
            }
            ("Session Bus Policy", "org.freedesktop.secrets") => {
                out.push("Your saved passwords (the keyring)".to_string());
            }
            ("System Bus Policy", name) if value.trim() == "talk" => {
                out.push(format!("A system service: {name}"));
            }
            _ => {}
        }
    }
    out.dedup();
    out
}

/// Size, version and permissions of an app on a remote (network; run it off the UI thread).
pub fn remote_info(remote: &str, id: &str) -> Result<RemoteInfo, String> {
    let run = |extra: &[&str]| -> Result<String, String> {
        let out = Command::new("flatpak")
            .arg("remote-info")
            .args(extra)
            .args([remote, id])
            .output()
            .map_err(|e| format!("flatpak: {e}"))?;
        if !out.status.success() {
            return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    };
    let mut info = parse_remote_info(&run(&[])?);
    info.permissions = parse_permissions(&run(&["--show-metadata"])?);
    Ok(info)
}

/// The app an `appstream://ID` (or `appstream:ID`) link names, as GNOME Software links do.
pub fn appstream_id(link: &str) -> Option<String> {
    let id = link
        .strip_prefix("appstream://")
        .or_else(|| link.strip_prefix("appstream:"))?
        .trim_end_matches('/')
        .trim_end_matches(".desktop");
    (id.split('.').count() >= 2
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')))
    .then(|| id.to_string())
}

/// What a `.flatpakref` file installs (its [Flatpak Ref] group).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FlatpakRef {
    pub name: String,
    pub title: String,
    pub url: String,
}

pub fn parse_flatpakref(text: &str) -> Option<FlatpakRef> {
    let mut r = FlatpakRef::default();
    let mut in_group = false;
    for line in text.lines().map(str::trim) {
        if line.starts_with('[') {
            in_group = line == "[Flatpak Ref]";
            continue;
        }
        let Some((k, v)) = line.split_once('=').filter(|_| in_group) else {
            continue;
        };
        match k.trim() {
            "Name" => r.name = v.trim().to_string(),
            "Title" => r.title = v.trim().to_string(),
            "Url" => r.url = v.trim().to_string(),
            _ => {}
        }
    }
    (!r.name.is_empty()).then_some(r)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_installed_list() {
        let text =
            "org.videolan.VLC\t3.0.21\tflathub\tsystem\ncom.spotify.Client\t1.2\tflathub\tuser\n\n";
        let l = parse_list(text);
        assert_eq!(l.len(), 2);
        assert_eq!(
            l[1],
            Installed {
                id: "com.spotify.Client".into(),
                version: "1.2".into(),
                origin: "flathub".into(),
                installation: "user".into()
            }
        );
    }

    #[test]
    fn command_lines() {
        assert_eq!(
            command_line(Action::Install, "flathub", "x.y")[1..],
            ["install", "--noninteractive", "-y", "flathub", "x.y"]
        );
        assert_eq!(
            command_line(Action::Uninstall, "flathub", "x.y")[1],
            "uninstall"
        );
    }

    #[test]
    fn progress_is_the_last_percentage() {
        assert_eq!(
            parse_progress("Installing 1/2… ████████   45%  3.1 MB/s"),
            Some(0.45)
        );
        assert_eq!(parse_progress("Installing… 100%"), Some(1.0));
        assert_eq!(parse_progress("Looking for matches…"), None);
        assert_eq!(parse_progress("odd %"), None);
    }

    #[test]
    fn updates_list() {
        let u = parse_updates("org.videolan.VLC\t3.0.22\n\nnot-an-id\t1\n");
        assert_eq!(
            u,
            vec![("org.videolan.VLC".to_string(), "3.0.22".to_string())]
        );
    }

    #[test]
    fn remote_info_sizes() {
        let text = "\nVLC - Video player\n\n          ID: org.videolan.VLC\n     Version: 3.0.21\n    Download: 52.1 MB\n   Installed: 120.4 MB\n";
        let i = parse_remote_info(text);
        assert_eq!(
            (
                i.version.as_str(),
                i.download.as_str(),
                i.installed.as_str()
            ),
            ("3.0.21", "52.1 MB", "120.4 MB")
        );
    }

    #[test]
    fn permissions_in_plain_words() {
        let meta = "[Application]\nname=x.y\n\n[Context]\nshared=network;ipc;\nsockets=x11;wayland;pulseaudio;\ndevices=dri;all;\nfilesystems=xdg-download;xdg-music:ro;home;!xdg-pictures;/media;\n\n[Session Bus Policy]\norg.freedesktop.secrets=talk\norg.freedesktop.Notifications=talk\n\n[System Bus Policy]\norg.freedesktop.UDisks2=talk\n";
        assert_eq!(
            parse_permissions(meta),
            vec![
                "Network access",
                "The X11 display (older; it can see other X11 windows)",
                "Sound and the microphone",
                "All devices (webcam, USB, game controllers)",
                "Your Download folder",
                "Your Music folder (read only)",
                "Your home folder",
                "Files in /media",
                "Your saved passwords (the keyring)",
                "A system service: org.freedesktop.UDisks2",
            ]
        );
        assert!(parse_permissions("[Context]\nsockets=wayland;\n").is_empty());
    }

    #[test]
    fn appstream_links() {
        assert_eq!(
            appstream_id("appstream://org.videolan.VLC").as_deref(),
            Some("org.videolan.VLC")
        );
        assert_eq!(
            appstream_id("appstream:org.gimp.GIMP.desktop").as_deref(),
            Some("org.gimp.GIMP")
        );
        assert_eq!(appstream_id("appstream://x; rm -rf /"), None);
        assert_eq!(appstream_id("https://flathub.org"), None);
    }

    #[test]
    fn flatpakref_files() {
        let text = "[Flatpak Ref]\nName=org.videolan.VLC\nBranch=stable\nTitle=VLC\nUrl=https://dl.flathub.org/repo/\nIsRuntime=false\n";
        let r = parse_flatpakref(text).unwrap();
        assert_eq!(
            (r.name.as_str(), r.title.as_str(), r.url.as_str()),
            ("org.videolan.VLC", "VLC", "https://dl.flathub.org/repo/")
        );
        assert!(parse_flatpakref("[Other]\nName=x\n").is_none());
    }
}
