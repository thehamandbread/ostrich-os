//! `ostrich config`: every Ostrich OS setting from the terminal, and a settings file for the
//! dotfiles. Values go through `gsettings` with each extension's own schema (so they're checked
//! against its types and ranges); export and import use `dconf` on our one path.
//!
//! A key that holds a command (its name has "command" in it, like the drawer's host-command) is
//! never exported or imported: a settings file someone hands you must not be able to make your
//! desktop run a program.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

pub const BASE: &str = "/org/gnome/shell/extensions/ostrich-os/";

pub const USAGE: &str = "Usage: ostrich config <command>

  list [EXT]              every setting (of one extension), with its value
  get EXT KEY             one setting
  set EXT KEY VALUE       change it (VALUE as gsettings takes it: true, 48, 'text', ['a', 'b'])
  reset EXT [KEY]         back to the default (the whole extension without KEY)
  diff                    only what you've changed from the defaults
  export [FILE]           what you've changed, as a settings file (to stdout without FILE)
  import FILE             apply a settings file (refuses one that sets a command)
  disable EXT / enable EXT  switch one extension off or on (works over SSH)

EXT is an extension's short name: blur, dock, drawer, focus, monitor, tiling, tweaks, workspaces.
To keep your settings in your dotfiles:
  ostrich config export \"$(chezmoi source-path)/dot_config/ostrich-os/settings.dconf\"
";

fn extensions_dir() -> PathBuf {
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/share")
        })
        .join("gnome-shell/extensions")
}

/// An extension's short name is ours and installed: its schemas folder, and its schema id.
fn schema(ext: &str) -> Result<(PathBuf, String), String> {
    if !valid_name(ext) {
        return Err(format!("`{ext}` isn't an extension name"));
    }
    let dir = extensions_dir().join(format!("{ext}@ostrich-os/schemas"));
    if !dir.is_dir() {
        return Err(format!(
            "there's no `{ext}` extension installed (see `ostrich config list`)"
        ));
    }
    Ok((dir, format!("org.gnome.shell.extensions.ostrich-os.{ext}")))
}

/// Our installed extensions that have settings, by short name.
fn installed() -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(extensions_dir())
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let short = name.strip_suffix("@ostrich-os")?.to_string();
            e.path().join("schemas").is_dir().then_some(short)
        })
        .collect();
    names.sort();
    names
}

pub fn valid_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 40
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// A key that runs something: never exported, never imported.
pub fn is_command_key(key: &str) -> bool {
    key.contains("command")
}

/// Machine-local state the extensions write for themselves: never exported, never imported
/// (tiling and monitor write these back into GNOME's own settings).
const INTERNAL_KEYS: [&str; 3] = ["overridden-settings", "saved-desktop", "migrated"];

fn output(cmd: &mut Command) -> Result<String, String> {
    let out = cmd
        .output()
        .map_err(|e| format!("couldn't run {:?}: {e}", cmd.get_program()))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

fn gsettings(ext: &str, args: &[&str]) -> Result<String, String> {
    let (dir, id) = schema(ext)?;
    let mut cmd = Command::new("gsettings");
    cmd.arg("--schemadir").arg(dir).arg(args[0]).arg(&id);
    cmd.args(&args[1..]);
    output(&mut cmd)
}

/// `dconf dump` text → only the lines a settings file may carry: our sections, no command keys.
/// Returns the kept text and the keys left out.
pub fn filter_dump(text: &str) -> (String, Vec<String>) {
    let mut kept = String::new();
    let mut dropped = Vec::new();
    let mut section = String::new();
    for line in text.lines() {
        let t = line.trim();
        if let Some(s) = t.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
            section = s.to_string();
            if valid_name(&section) {
                kept.push_str(line);
                kept.push('\n');
            }
            continue;
        }
        if t.is_empty() || t.starts_with('#') {
            if valid_name(&section) || section.is_empty() {
                kept.push_str(line);
                kept.push('\n');
            }
            continue;
        }
        let key = t.split('=').next().unwrap_or("").trim();
        if !valid_name(&section) {
            dropped.push(format!("[{section}] {key}"));
        } else if is_command_key(key) || INTERNAL_KEYS.contains(&key) {
            dropped.push(format!("{section}/{key}"));
        } else {
            kept.push_str(line);
            kept.push('\n');
        }
    }
    (kept, dropped)
}

fn dump() -> Result<String, String> {
    output(Command::new("dconf").args(["dump", BASE]))
}

pub fn run(args: &[String]) -> Result<String, String> {
    let a: Vec<&str> = args.iter().map(String::as_str).collect();
    match a.as_slice() {
        [] | ["help"] | ["--help"] | ["-h"] => Ok(USAGE.to_string()),
        ["list"] => {
            let mut s = String::new();
            for ext in installed() {
                s.push_str(&list(&ext)?);
            }
            Ok(s)
        }
        ["list", ext] => list(ext),
        ["get", ext, key] => gsettings(ext, &["get", key]),
        ["set", ext, key, value] => {
            if is_command_key(key) {
                return Err(format!(
                    "{ext}/{key} holds a command; change it in the file, not from here"
                ));
            }
            gsettings(ext, &["set", key, value]).map(|_| String::new())
        }
        ["reset", ext] => gsettings(ext, &["reset-recursively"]).map(|_| String::new()),
        ["reset", ext, key] => gsettings(ext, &["reset", key]).map(|_| String::new()),
        ["diff"] => dump(),
        ["export"] => export(),
        ["export", file] => {
            let text = export()?;
            std::fs::write(file, text).map_err(|e| format!("couldn't write {file}: {e}"))?;
            Ok(format!("Saved your changed settings to {file}\n"))
        }
        ["import", file] => import(file),
        [verb @ ("disable" | "enable"), ext] => {
            schema(ext)?;
            output(Command::new("gnome-extensions").args([*verb, &format!("{ext}@ostrich-os")]))
                .map(|_| format!("{ext}: {verb}d\n"))
        }
        _ => Err(format!("that isn't a config command.\n\n{USAGE}")),
    }
}

fn list(ext: &str) -> Result<String, String> {
    let out = gsettings(ext, &["list-recursively"])?;
    // "schema key value" → "ext key value"
    Ok(out
        .lines()
        .filter_map(|l| l.split_once(' ').map(|(_, rest)| format!("{ext} {rest}\n")))
        .collect())
}

fn export() -> Result<String, String> {
    let (kept, dropped) = filter_dump(&dump()?);
    let mut s = String::from(
        "# Ostrich OS settings: only what differs from the defaults.\n\
         # Apply with: ostrich config import FILE  (or keep it in your dotfiles; see `ostrich config help`)\n",
    );
    if !dropped.is_empty() {
        s.push_str(&format!(
            "# Left out (commands are never exported): {}\n",
            dropped.join(", ")
        ));
    }
    s.push_str(&kept);
    Ok(s)
}

fn import(file: &str) -> Result<String, String> {
    let text = std::fs::read_to_string(file).map_err(|e| format!("couldn't read {file}: {e}"))?;
    let (kept, dropped) = filter_dump(&text);
    if !dropped.is_empty() {
        return Err(format!(
            "{file} sets things a settings file may not ({}); nothing was changed",
            dropped.join(", ")
        ));
    }
    let mut child = Command::new("dconf")
        .args(["load", BASE])
        .stdin(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("couldn't run dconf: {e}"))?;
    child
        .stdin
        .take()
        .ok_or("dconf has no input")?
        .write_all(kept.as_bytes())
        .map_err(|e| e.to_string())?;
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(format!("Applied the settings in {file}\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_command_keys() {
        assert!(valid_name("dock") && valid_name("search-new-window"));
        assert!(!valid_name("../x") && !valid_name("Dock") && !valid_name(""));
        assert!(is_command_key("host-command") && !is_command_key("icon-size"));
    }

    #[test]
    fn a_settings_file_keeps_our_settings_and_drops_commands_and_strangers() {
        let dump = "[dock]\nicon-size=uint32 48\n\n[drawer]\nbar-max=uint32 3\nhost-command='rm -rf ~'\n\n[tiling]\noverridden-settings='{}'\n\n[../evil]\nx=1\n";
        let (kept, dropped) = filter_dump(dump);
        assert!(kept.contains("[dock]\nicon-size=uint32 48"));
        assert!(kept.contains("bar-max=uint32 3"));
        assert!(!kept.contains("host-command") && !kept.contains("evil"));
        assert!(!kept.contains("overridden-settings"));
        assert_eq!(
            dropped,
            vec![
                "drawer/host-command",
                "tiling/overridden-settings",
                "[../evil] x"
            ]
        );
    }
}
