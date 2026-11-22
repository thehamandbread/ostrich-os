//! `ostrich env`: environments (saved desktops), driven through the shell's
//! ostrich_os.Environments D-Bus interface (the focus extension) with `gdbus`.

use std::process::Command;

const DEST: &str = "ostrich_os.Environments";
const PATH: &str = "/ostrich_os/Environments";

pub const USAGE: &str = "Usage: ostrich workspace <command>   (or: ostrich env)

  list              your saved workspaces
  save NAME         save the apps and windows on this workspace as NAME
  open NAME         open NAME on a fresh workspace named NAME
  close NAME        save where you left off, close its windows and go back
  delete NAME       forget NAME

  drawer NAME                    its Ostrich Drawer sites (saved with the desktop)
  drawer NAME add SITE [--keep]  add a drawer site to it (--keep: kept loaded, for notifications)
  drawer NAME remove SITE        take one out
  drawer NAME clear              use the normal drawer sites in it

A saved workspace can also turn on focus with only its apps, a power mode and Do Not Disturb:
edit ~/.config/ostrich-os/environments/NAME.json, or use Ostrich Settings.
Drawer site ids are the ones `ostrich drawer --list` prints.
";

/// The file id for a name, the same rule as the extension: "Video editing" -> "video-editing".
pub fn env_id(name: &str) -> Option<String> {
    let mut id = String::new();
    for c in name.trim().to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            id.push(c);
        } else if !id.ends_with('-') {
            id.push('-');
        }
    }
    let id: String = id.trim_matches('-').chars().take(40).collect();
    let id = id.trim_end_matches('-').to_string();
    (!id.is_empty()).then_some(id)
}

/// The string inside gdbus's reply `('...',)`, unescaped. A string with a `'` in it comes
/// back as `("...",)` instead.
pub fn reply_string(out: &str) -> Option<String> {
    let t = out.trim();
    let inner = (t.strip_prefix("('").and_then(|r| r.strip_suffix("',)")))
        .or_else(|| t.strip_prefix("(\"")?.strip_suffix("\",)"))?;
    let mut s = String::new();
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next()? {
                'n' => s.push('\n'),
                't' => s.push('\t'),
                other => s.push(other),
            }
        } else {
            s.push(c);
        }
    }
    Some(s)
}

/// A GVariant string literal for gdbus's command line.
pub fn gvariant_string(s: &str) -> String {
    format!("'{}'", s.replace('\\', "\\\\").replace('\'', "\\'"))
}

/// An environment's drawer set: the top-bar sites in order, and the ones kept loaded.
#[derive(Debug, Default, PartialEq)]
pub struct DrawerSet {
    pub sites: Vec<String>,
    pub keep: Vec<String>,
}

impl DrawerSet {
    /// From the extension's JSON, `{"sites":[...],"keep":[...]}` or `null` (None).
    pub fn parse(json: &str) -> Option<DrawerSet> {
        let t = json.trim();
        if t == "null" || !t.starts_with('{') {
            return None;
        }
        let list = |key: &str| -> Vec<String> {
            let Some(rest) = t.split(&format!("\"{key}\":")).nth(1) else {
                return Vec::new();
            };
            let inner = rest.trim_start().trim_start_matches('[');
            let inner = inner.split(']').next().unwrap_or("");
            inner
                .split(',')
                .map(|x| x.trim().trim_matches('"').to_string())
                .filter(|x| !x.is_empty())
                .collect()
        };
        Some(DrawerSet {
            sites: list("sites"),
            keep: list("keep"),
        })
    }

    pub fn to_json(&self) -> String {
        let arr = |v: &[String]| {
            v.iter()
                .map(|x| format!("\"{x}\""))
                .collect::<Vec<_>>()
                .join(",")
        };
        format!(
            "{{\"sites\":[{}],\"keep\":[{}]}}",
            arr(&self.sites),
            arr(&self.keep)
        )
    }

    pub fn describe(set: Option<&DrawerSet>) -> String {
        match set {
            None => "uses the normal drawer sites\n".into(),
            Some(s) if s.sites.is_empty() => "no drawer sites\n".into(),
            Some(s) => s
                .sites
                .iter()
                .map(|id| {
                    let kept = if s.keep.contains(id) {
                        "  (kept loaded)"
                    } else {
                        ""
                    };
                    format!("  {id}{kept}\n")
                })
                .collect(),
        }
    }
}

/// A drawer site id, the same rule as drawer-host's config::valid_id.
fn site_id(s: &str) -> Option<String> {
    (!s.is_empty() && s.len() <= 40 && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'))
        .then(|| s.to_string())
}

fn call(method: &str, arg: Option<&str>) -> Result<String, String> {
    call_args(method, arg.into_iter().collect())
}

fn call_args(method: &str, args: Vec<&str>) -> Result<String, String> {
    let mut cmd = Command::new("gdbus");
    cmd.args([
        "call",
        "--session",
        "--dest",
        DEST,
        "--object-path",
        PATH,
        "--method",
        &format!("{DEST}.{method}"),
    ]);
    for a in args {
        cmd.arg(gvariant_string(a));
    }
    let out = cmd
        .output()
        .map_err(|e| format!("could not run gdbus: {e}"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        if err.contains("ServiceUnknown") || err.contains("was not provided") {
            return Err(
                "saved workspaces need the Focus extension, and a desktop session (log in first)"
                    .into(),
            );
        }
        // GNOME's error text after the D-Bus error name is the useful part.
        let msg = err.rsplit(": ").next().unwrap_or(&err).trim().to_string();
        return Err(msg);
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Runs `ostrich env ARGS`; returns what to print, or the error.
pub fn run(args: &[String]) -> Result<String, String> {
    let need = |a: Option<&String>| -> Result<String, String> {
        let name = a.ok_or_else(|| format!("which saved workspace?\n\n{USAGE}"))?;
        env_id(name).ok_or_else(|| "use letters or numbers in the name".to_string())
    };
    match args.first().map(String::as_str) {
        None | Some("list") => {
            let json = reply_string(&call("List", None)?).unwrap_or_default();
            Ok(format_list(&json))
        }
        Some("save") => {
            let name = args
                .get(1..)
                .map(|r| r.join(" "))
                .filter(|n| !n.trim().is_empty())
                .ok_or_else(|| format!("give it a name\n\n{USAGE}"))?;
            let id = reply_string(&call("Save", Some(&name))?).unwrap_or_default();
            Ok(format!(
                "saved \"{name}\" (open it with: ostrich env open {id})\n"
            ))
        }
        Some("open") => call("Open", Some(&need(args.get(1))?)).map(|_| String::new()),
        Some("close") => call("Close", Some(&need(args.get(1))?)).map(|_| String::new()),
        Some("delete") => call("Delete", Some(&need(args.get(1))?)).map(|_| String::new()),
        Some("drawer") => {
            let id = need(args.get(1))?;
            let current =
                DrawerSet::parse(&reply_string(&call("GetDrawer", Some(&id))?).unwrap_or_default());
            let site = || {
                args.get(3)
                    .and_then(|s| site_id(s))
                    .ok_or_else(|| format!("which drawer site?\n\n{USAGE}"))
            };
            let new = match args.get(2).map(String::as_str) {
                None | Some("list") => return Ok(DrawerSet::describe(current.as_ref())),
                Some("clear") => None,
                Some("add") => {
                    let site = site()?;
                    let mut set = current.unwrap_or_default();
                    if !set.sites.contains(&site) {
                        set.sites.push(site.clone());
                    }
                    if args.iter().any(|a| a == "--keep") && !set.keep.contains(&site) {
                        set.keep.push(site);
                    }
                    Some(set)
                }
                Some("remove") => {
                    let site = site()?;
                    let mut set = current.unwrap_or_default();
                    set.sites.retain(|s| s != &site);
                    set.keep.retain(|s| s != &site);
                    Some(set)
                }
                Some(other) => return Err(format!("no env drawer command `{other}`\n\n{USAGE}")),
            };
            let json = new.as_ref().map_or("null".to_string(), DrawerSet::to_json);
            call_args("SetDrawer", vec![&id, &json])?;
            Ok(DrawerSet::describe(new.as_ref()))
        }
        Some("-h" | "--help" | "help") => Ok(USAGE.into()),
        Some(other) => Err(format!("no env command `{other}`\n\n{USAGE}")),
    }
}

/// `[{"id":"school","name":"School","apps":2,"open":false}]` -> one line each.
pub fn format_list(json: &str) -> String {
    // Flat objects only: each entry is its keys and values in order, strings unescaped.
    let mut entries: Vec<Vec<String>> = Vec::new();
    let mut chars = json.chars().peekable();
    while let Some(c) = chars.next() {
        let token = match c {
            '{' => {
                entries.push(Vec::new());
                continue;
            }
            '"' => {
                let mut s = String::new();
                while let Some(c) = chars.next() {
                    match c {
                        '"' => break,
                        '\\' => s.extend(chars.next()),
                        c => s.push(c),
                    }
                }
                s
            }
            c if c.is_ascii_alphanumeric() || c == '-' => {
                let mut s = c.to_string();
                while let Some(c) = chars.next_if(|c| c.is_ascii_alphanumeric() || *c == '.') {
                    s.push(c);
                }
                s
            }
            _ => continue,
        };
        if let Some(e) = entries.last_mut() {
            e.push(token);
        }
    }
    entries.retain(|e| e.iter().step_by(2).any(|k| k == "id"));
    if entries.is_empty() {
        return "No saved workspaces yet. Arrange a workspace, then: ostrich workspace save NAME\n"
            .into();
    }
    let field = |e: &[String], k: &str| -> String {
        e.chunks(2)
            .find(|p| p[0] == k)
            .and_then(|p| p.get(1))
            .cloned()
            .unwrap_or_default()
    };
    entries
        .iter()
        .map(|e| {
            let open = if field(e, "open") == "true" {
                "  (open)"
            } else {
                ""
            };
            format!(
                "  {:<20} {} app(s){open}\n",
                field(e, "name"),
                field(e, "apps")
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_match_the_extension() {
        assert_eq!(env_id("Video editing").as_deref(), Some("video-editing"));
        assert_eq!(env_id("  School/Uni!! ").as_deref(), Some("school-uni"));
        assert_eq!(env_id("!!!"), None);
    }

    #[test]
    fn gdbus_strings_both_ways() {
        assert_eq!(gvariant_string("it's"), "'it\\'s'");
        assert_eq!(
            reply_string("('[{\"id\":\"a\"}]',)\n").as_deref(),
            Some("[{\"id\":\"a\"}]")
        );
        assert_eq!(reply_string("(\"it's\",)").as_deref(), Some("it's"));
        assert_eq!(
            reply_string(r#"("[{\"name\":\"Sam's\"}]",)"#).as_deref(),
            Some(r#"[{"name":"Sam's"}]"#)
        );
        assert_eq!(reply_string("nonsense"), None);
    }

    #[test]
    fn drawer_sets() {
        let s = DrawerSet::parse(r#"{"sites":["claude","gmail"],"keep":["gmail"]}"#).unwrap();
        assert_eq!(s.sites, ["claude", "gmail"]);
        assert_eq!(s.keep, ["gmail"]);
        assert_eq!(DrawerSet::parse(&s.to_json()), Some(s));
        assert_eq!(DrawerSet::parse("null"), None);
        assert_eq!(
            DrawerSet::parse(r#"{"sites":[],"keep":[]}"#),
            Some(DrawerSet::default())
        );
        assert!(DrawerSet::describe(None).contains("normal"));
        assert!(
            DrawerSet::describe(DrawerSet::parse(r#"{"sites":["a"],"keep":["a"]}"#).as_ref())
                .contains("a  (kept loaded)")
        );
        assert_eq!(site_id("../x"), None);
    }

    #[test]
    fn list_formatting() {
        let s = format_list(
            r#"[{"id":"school","name":"School","apps":2,"open":false},{"id":"video","name":"Video editing","apps":3,"open":true}]"#,
        );
        assert!(
            s.contains("School")
                && s.contains("2 app(s)")
                && !s.lines().next().unwrap().contains("(open)")
        );
        assert!(s.lines().nth(1).unwrap().contains("(open)"));
        assert!(format_list("[]").contains("No saved workspaces yet"));
        let s = format_list(r#"[{"id":"a","name":"Work, \"home\"},","apps":1,"open":true}]"#);
        assert!(s.contains("Work, \"home\"},") && s.contains("1 app(s)  (open)"));
    }
}
