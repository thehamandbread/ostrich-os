//! Touchscreen on/off by unbinding its driver (proven in spike (d), docs/spikes/touchscreen.md).
//!
//! - Touchscreens are found by the udev property ID_INPUT_TOUCHSCREEN=1 (never by name).
//! - "transport" level: the driver above the HID driver (e.g. i2c_hid_acpi) when that device has
//!   exactly one bound child, so the controller can power down; otherwise the HID level.
//! - The state file records exactly what was unbound, so `on` rebinds the same thing.
//! - Persisting writes a udev rule that unbinds it again whenever it appears (boot, rebind).

use std::fs;
use std::path::{Path, PathBuf};

pub struct Paths {
    pub sys: PathBuf,
    pub udev_data: PathBuf,
    pub state: PathBuf,
    pub rule: PathBuf,
}

impl Default for Paths {
    fn default() -> Self {
        Paths {
            sys: PathBuf::from("/sys"),
            udev_data: PathBuf::from("/run/udev/data"),
            state: PathBuf::from("/var/lib/ubuntu-ostrich/touchscreen.state"),
            rule: PathBuf::from("/etc/udev/rules.d/90-ubuntu-ostrich-touchscreen.rules"),
        }
    }
}

#[derive(Debug, PartialEq)]
pub struct Target {
    pub device: PathBuf,
    pub driver: PathBuf,
}

/// Real paths of input event nodes whose udev record says ID_INPUT_TOUCHSCREEN=1.
pub fn touchscreens(p: &Paths) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(entries) = fs::read_dir(p.sys.join("class/input")) else {
        return out;
    };
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if !name.starts_with("event") {
            continue;
        }
        // udev data for char devices is keyed "c<major>:<minor>"
        let Ok(dev) = fs::read_to_string(e.path().join("dev")) else {
            continue;
        };
        let record = p.udev_data.join(format!("c{}", dev.trim()));
        let is_touch = fs::read_to_string(record)
            .map(|t| t.lines().any(|l| l == "E:ID_INPUT_TOUCHSCREEN=1"))
            .unwrap_or(false);
        if is_touch {
            if let Ok(real) = fs::canonicalize(e.path()) {
                out.push(real);
            }
        }
    }
    out.sort();
    out
}

/// Bound ancestors of a sysfs path, nearest first.
pub fn bound_ancestors(p: &Paths, path: &Path) -> Vec<Target> {
    let mut out = Vec::new();
    let mut cur = path.to_path_buf();
    while cur.starts_with(&p.sys) && cur != p.sys {
        if let Ok(driver) = fs::canonicalize(cur.join("driver")) {
            if cur.join("driver").is_symlink() {
                out.push(Target {
                    device: cur.clone(),
                    driver,
                });
            }
        }
        if !cur.pop() {
            break;
        }
    }
    out
}

fn bound_children(dir: &Path) -> usize {
    fs::read_dir(dir)
        .map(|it| {
            it.flatten()
                .filter(|e| e.path().is_dir() && e.path().join("driver").is_symlink())
                .count()
        })
        .unwrap_or(0)
}

/// The device to unbind: the transport when it serves only this controller, else the HID level.
pub fn pick_target(p: &Paths, event: &Path) -> Option<Target> {
    let mut anc = bound_ancestors(p, event).into_iter();
    let hid = anc.next()?;
    if let Some(transport) = anc.next() {
        if bound_children(&transport.device) == 1 {
            return Some(transport);
        }
    }
    Some(hid)
}

fn name_of(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// "on", "off", or "none" (no touchscreen and nothing recorded as turned off).
pub fn status(p: &Paths) -> &'static str {
    if fs::read_to_string(&p.state)
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false)
    {
        "off"
    } else if touchscreens(p).is_empty() {
        "none"
    } else {
        "on"
    }
}

pub fn off(p: &Paths, persist: bool) -> Result<String, String> {
    let events = touchscreens(p);
    if events.is_empty() {
        return Err("no touchscreen found (already off?)".into());
    }
    let mut state = fs::read_to_string(&p.state).unwrap_or_default();
    let mut rules = String::new();
    let mut done = Vec::new();
    for ev in events {
        let Some(t) = pick_target(p, &ev) else {
            continue;
        };
        let name = name_of(&t.device);
        if state
            .lines()
            .any(|l| l.split('\t').next() == Some(t.device.to_str().unwrap_or("")))
        {
            continue; // two event nodes on the same controller
        }
        fs::write(t.driver.join("unbind"), &name).map_err(|e| format!("unbind {name}: {e}"))?;
        state.push_str(&format!("{}\t{}\n", t.device.display(), t.driver.display()));
        let subsystem = fs::canonicalize(t.device.join("subsystem"))
            .map(|s| name_of(&s))
            .unwrap_or_default();
        rules.push_str(&format!(
            "ACTION==\"add|bind\", SUBSYSTEM==\"{subsystem}\", KERNEL==\"{name}\", DRIVER==\"{drv}\", RUN+=\"/bin/sh -c 'echo %k > {path}/unbind'\"\n",
            drv = name_of(&t.driver),
            path = t.driver.display()
        ));
        done.push(format!("{name} (from {})", name_of(&t.driver)));
    }
    if let Some(dir) = p.state.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    fs::write(&p.state, state).map_err(|e| format!("{}: {e}", p.state.display()))?;
    if persist {
        let header = "# Written by ubuntu-ostrich system-helper: keeps the touchscreen off. Remove with `touchscreen on`.\n";
        fs::write(&p.rule, format!("{header}{rules}"))
            .map_err(|e| format!("{}: {e}", p.rule.display()))?;
    }
    Ok(format!("touchscreen off: unbound {}", done.join(", ")))
}

pub fn on(p: &Paths) -> Result<String, String> {
    let _ = fs::remove_file(&p.rule);
    let state = fs::read_to_string(&p.state).unwrap_or_default();
    if state.trim().is_empty() {
        return Err("nothing to turn back on".into());
    }
    let mut done = Vec::new();
    for line in state.lines() {
        let Some((dev, drv)) = line.split_once('\t') else {
            continue;
        };
        let name = name_of(Path::new(dev));
        fs::write(Path::new(drv).join("bind"), &name).map_err(|e| format!("bind {name}: {e}"))?;
        done.push(name);
    }
    fs::remove_file(&p.state).map_err(|e| format!("{}: {e}", p.state.display()))?;
    Ok(format!("touchscreen on: rebound {}", done.join(", ")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    /// A fake sysfs: transport `i2c-TS` (driver i2c_hid) → HID `0018:TS` (driver hid-multitouch)
    /// → input → event5 (touchscreen); plus a touchpad on its own transport.
    fn fixture(tag: &str) -> (PathBuf, Paths) {
        let root = std::env::temp_dir().join(format!("ost-ts-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let sys = root.join("sys");
        let drv = |name: &str| {
            let d = sys.join("bus/drivers").join(name);
            fs::create_dir_all(&d).unwrap();
            d
        };
        let (i2c, mt) = (drv("i2c_hid"), drv("hid-multitouch"));
        let ts_t = sys.join("devices/i2c-TS");
        let ts_h = ts_t.join("0018:TS");
        let ts_ev = ts_h.join("input/input13/event5");
        fs::create_dir_all(&ts_ev).unwrap();
        symlink(&i2c, ts_t.join("driver")).unwrap();
        symlink(&mt, ts_h.join("driver")).unwrap();
        fs::write(ts_ev.join("dev"), "13:69\n").unwrap();
        let tp_t = sys.join("devices/i2c-TP");
        let tp_ev = tp_t.join("0018:TP/input/input14/event6");
        fs::create_dir_all(&tp_ev).unwrap();
        symlink(&i2c, tp_t.join("driver")).unwrap();
        symlink(&mt, tp_t.join("0018:TP/driver")).unwrap();
        fs::write(tp_ev.join("dev"), "13:70\n").unwrap();
        fs::create_dir_all(sys.join("class/input")).unwrap();
        symlink(&ts_ev, sys.join("class/input/event5")).unwrap();
        symlink(&tp_ev, sys.join("class/input/event6")).unwrap();
        let udev = root.join("udev");
        fs::create_dir_all(&udev).unwrap();
        fs::write(
            udev.join("c13:69"),
            "E:ID_INPUT=1\nE:ID_INPUT_TOUCHSCREEN=1\n",
        )
        .unwrap();
        fs::write(udev.join("c13:70"), "E:ID_INPUT=1\nE:ID_INPUT_TOUCHPAD=1\n").unwrap();
        let paths = Paths {
            sys,
            udev_data: udev,
            state: root.join("state/ts.state"),
            rule: root.join("90-ts.rules"),
        };
        (root, paths)
    }

    #[test]
    fn finds_only_the_touchscreen() {
        let (_root, p) = fixture("find");
        let ts = touchscreens(&p);
        assert_eq!(ts.len(), 1);
        assert!(ts[0].ends_with("event5"));
    }

    #[test]
    fn picks_the_transport_when_it_serves_only_the_touchscreen() {
        let (_root, p) = fixture("pick");
        let ev = touchscreens(&p).remove(0);
        let t = pick_target(&p, &ev).unwrap();
        assert!(t.device.ends_with("i2c-TS"));
        assert!(t.driver.ends_with("i2c_hid"));
    }

    #[test]
    fn falls_back_to_hid_when_the_transport_is_shared() {
        let (_root, p) = fixture("shared");
        // a second bound device on the touchscreen's transport
        let extra = p.sys.join("devices/i2c-TS/0018:PEN");
        fs::create_dir_all(&extra).unwrap();
        symlink(
            p.sys.join("bus/drivers/hid-multitouch"),
            extra.join("driver"),
        )
        .unwrap();
        let ev = touchscreens(&p).remove(0);
        assert!(pick_target(&p, &ev).unwrap().device.ends_with("0018:TS"));
    }

    #[test]
    fn off_writes_unbind_state_and_rule_then_on_rebinds() {
        let (_root, p) = fixture("offon");
        assert_eq!(status(&p), "on");
        let msg = off(&p, true).unwrap();
        assert!(msg.contains("i2c-TS"));
        let drv = p.sys.join("bus/drivers/i2c_hid");
        assert_eq!(fs::read_to_string(drv.join("unbind")).unwrap(), "i2c-TS");
        assert_eq!(status(&p), "off");
        let rule = fs::read_to_string(&p.rule).unwrap();
        assert!(rule.contains("KERNEL==\"i2c-TS\"") && rule.contains("DRIVER==\"i2c_hid\""));
        // the touchpad's transport is never touched
        assert!(!rule.contains("i2c-TP"));
        on(&p).unwrap();
        assert_eq!(fs::read_to_string(drv.join("bind")).unwrap(), "i2c-TS");
        assert!(!p.rule.exists() && !p.state.exists());
    }

    #[test]
    fn on_without_state_is_an_error() {
        let (_root, p) = fixture("nostate");
        assert!(on(&p).is_err());
    }
}
