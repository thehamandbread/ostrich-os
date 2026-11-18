//! Power modes layered on power-profiles-daemon (DESIGN.md: power modes).
//!
//! power-profiles-daemon already sets the CPU energy preference (EPP) and the platform profile
//! (e.g. Dell quiet/balanced/performance); we don't touch those, so GNOME's own power menu keeps
//! working. On top we set safe, reversible kernel knobs:
//!
//! | knob                                   | saver                 | balanced | performance |
//! |----------------------------------------|-----------------------|----------|-------------|
//! | CPU boost (intel_pstate no_turbo)      | off                   | on       | on          |
//! | CPU long-term power limit (RAPL PL1)   | 60 % of default, ≥15 W| default  | default     |
//! | PCIe ASPM policy                       | powersupersave        | default  | performance |
//! | HDA audio power save                   | 1 s                   | 1 s      | off         |
//! | USB autosuspend (not input, not audio) | auto                  | original | original    |
//! | SATA link power                        | med_power_with_dipm   | original | max_performance |
//! | NVIDIA dGPU runtime PM                 | auto                  | auto     | on          |
//! | NMI watchdog                           | off                   | original | original    |
//! | dirty page writeback                   | 15 s                  | original | original    |
//! | Wi-Fi power save (iw)                  | on                    | original | off         |
//!
//! Anything the machine doesn't have, or a value it doesn't offer, is reported, never an error.
//! The first time a knob changes, its value is kept in /run/ubuntu-ostrich/power-originals, and
//! "original" puts that back (so balanced really is the machine's own default). /run is cleared at
//! boot, which matches the knobs: the kernel resets them too.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Mode {
    Saver,
    Balanced,
    Performance,
}

impl Mode {
    pub fn parse(s: &str) -> Option<Mode> {
        match s {
            "saver" | "power-saver" => Some(Mode::Saver),
            "balanced" => Some(Mode::Balanced),
            "performance" => Some(Mode::Performance),
            _ => None,
        }
    }
}

pub struct Paths {
    pub sys: PathBuf,
    pub proc: PathBuf,
    /// Where originals are kept (normally /run/ubuntu-ostrich).
    pub run: PathBuf,
    /// The `iw` binary for Wi-Fi power save; None skips it (tests).
    pub iw: Option<PathBuf>,
}

impl Default for Paths {
    fn default() -> Self {
        Paths {
            sys: PathBuf::from("/sys"),
            proc: PathBuf::from("/proc"),
            run: PathBuf::from("/run/ubuntu-ostrich"),
            iw: ["/usr/sbin/iw", "/usr/bin/iw", "/sbin/iw"]
                .iter()
                .map(PathBuf::from)
                .find(|p| p.exists()),
        }
    }
}

/// PL1 floor in saver: below this the machine stops feeling usable for the web.
pub const PL1_FLOOR_UW: u64 = 15_000_000;
const PL1_SAVER_PERCENT: u64 = 60;

/// What a knob should be in a mode.
#[derive(Clone, Debug, PartialEq)]
enum Want {
    Value(String),
    /// Put back the value from before we first changed it.
    Original,
}

fn v(s: &str) -> Want {
    Want::Value(s.to_string())
}

/// The pcie_aspm / SATA policy files list choices like "default performance [powersave]".
fn offered(text: &str, value: &str) -> bool {
    text.split_whitespace()
        .any(|w| w.trim_matches(['[', ']']) == value)
}

fn is_current(text: &str, value: &str) -> bool {
    let t = text.trim();
    t == value || t.split_whitespace().any(|w| w == format!("[{value}]"))
}

fn read(p: &Path) -> Option<String> {
    fs::read_to_string(p).ok().map(|s| s.trim().to_string())
}

fn list(dir: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = fs::read_dir(dir)
        .map(|it| it.flatten().map(|e| e.path()).collect())
        .unwrap_or_default();
    v.sort();
    v
}

/// Originals kept across helper runs: "path\tvalue" lines.
struct Originals {
    file: PathBuf,
    map: BTreeMap<String, String>,
}

impl Originals {
    fn load(run: &Path) -> Originals {
        let file = run.join("power-originals");
        let map = fs::read_to_string(&file)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| l.split_once('\t'))
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        Originals { file, map }
    }

    fn remember(&mut self, key: &str, value: &str) {
        self.map
            .entry(key.to_string())
            .or_insert_with(|| value.to_string());
    }

    fn save(&self) {
        let text: String = self
            .map
            .iter()
            .map(|(k, v)| format!("{k}\t{v}\n"))
            .collect();
        if let Some(d) = self.file.parent() {
            let _ = fs::create_dir_all(d);
        }
        let _ = fs::write(&self.file, text);
    }
}

/// The current value of a policy file: for "[a] b c" lists the bracketed one.
fn current_choice(text: &str) -> String {
    text.split_whitespace()
        .find(|w| w.starts_with('['))
        .map(|w| w.trim_matches(['[', ']']).to_string())
        .unwrap_or_else(|| text.trim().to_string())
}

/// Sets one sysfs/procfs file to what `want` says, recording the original first.
fn set(path: &Path, want: &Want, choices: bool, orig: &mut Originals, report: &mut Vec<String>) {
    let key = path.to_string_lossy().into_owned();
    let Some(text) = read(path) else {
        report.push(format!("{key}: not available"));
        return;
    };
    let current = current_choice(&text);
    let value = match want {
        Want::Value(v) => v.clone(),
        Want::Original => match orig.map.get(&key) {
            Some(o) => o.clone(),
            None => {
                report.push(format!("{key}: unchanged ({current})"));
                return;
            }
        },
    };
    if is_current(&text, &value) {
        report.push(format!("{key}: already {value}"));
        return;
    }
    // Policy files list their choices ("[a] b c"); a bare value means there's no list to check.
    if choices && text.contains('[') && !offered(&text, &value) {
        report.push(format!("{key}: {value} not offered"));
        return;
    }
    orig.remember(&key, &current);
    match fs::write(path, &value) {
        Ok(()) => report.push(format!("{key}: {current} -> {value}")),
        Err(e) => report.push(format!("{key}: could not set {value}: {e}")),
    }
}

/// USB devices that must never autosuspend: anything with an input (HID) or audio interface.
fn usb_keep_awake(dev: &Path) -> bool {
    list(dev).iter().any(|i| {
        matches!(
            read(&i.join("bInterfaceClass")).as_deref(),
            Some("03" | "01")
        )
    })
}

/// RAPL package domains (intel-rapl:N, not the :N:M subdomains).
fn rapl_domains(sys: &Path) -> Vec<PathBuf> {
    list(&sys.join("class/powercap"))
        .into_iter()
        .filter(|p| {
            let n = p
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            n.starts_with("intel-rapl:") && n.matches(':').count() == 1
        })
        .collect()
}

/// Saver PL1 for a domain: 60 % of its default (the original), never below the floor, never above
/// the default.
pub fn saver_pl1(default_uw: u64) -> u64 {
    (default_uw * PL1_SAVER_PERCENT / 100)
        .max(PL1_FLOOR_UW)
        .min(default_uw)
}

fn nvidia_functions(sys: &Path) -> Vec<PathBuf> {
    list(&sys.join("bus/pci/devices"))
        .into_iter()
        .filter(|d| read(&d.join("vendor")).as_deref() == Some("0x10de"))
        .collect()
}

fn wifi_interfaces(sys: &Path) -> Vec<String> {
    list(&sys.join("class/net"))
        .into_iter()
        .filter(|n| n.join("wireless").exists())
        .filter_map(|n| n.file_name().map(|f| f.to_string_lossy().into_owned()))
        .collect()
}

/// Applies a mode; returns one line per knob (changed / already set / not available).
pub fn apply(p: &Paths, mode: Mode) -> Vec<String> {
    let mut report = Vec::new();
    let mut orig = Originals::load(&p.run);
    let pick = |s: Want, b: Want, perf: Want| match mode {
        Mode::Saver => s,
        Mode::Balanced => b,
        Mode::Performance => perf,
    };

    let cpu = p.sys.join("devices/system/cpu/intel_pstate/no_turbo");
    set(
        &cpu,
        &pick(v("1"), v("0"), v("0")),
        false,
        &mut orig,
        &mut report,
    );

    for d in rapl_domains(&p.sys) {
        let f = d.join("constraint_0_power_limit_uw");
        let key = f.to_string_lossy().into_owned();
        let default = orig
            .map
            .get(&key)
            .cloned()
            .or_else(|| read(&f))
            .and_then(|s| s.parse::<u64>().ok());
        let want = match (mode, default) {
            (Mode::Saver, Some(def)) => Want::Value(saver_pl1(def).to_string()),
            _ => Want::Original,
        };
        set(&f, &want, false, &mut orig, &mut report);
    }

    set(
        &p.sys.join("module/pcie_aspm/parameters/policy"),
        &pick(v("powersupersave"), v("default"), v("performance")),
        true,
        &mut orig,
        &mut report,
    );
    set(
        &p.sys.join("module/snd_hda_intel/parameters/power_save"),
        &pick(v("1"), v("1"), v("0")),
        false,
        &mut orig,
        &mut report,
    );

    for dev in list(&p.sys.join("bus/usb/devices")) {
        let ctl = dev.join("power/control");
        if !ctl.exists() || usb_keep_awake(&dev) {
            continue;
        }
        set(
            &ctl,
            &pick(v("auto"), Want::Original, Want::Original),
            false,
            &mut orig,
            &mut report,
        );
    }

    for host in list(&p.sys.join("class/scsi_host")) {
        let f = host.join("link_power_management_policy");
        if f.exists() {
            set(
                &f,
                &pick(
                    v("med_power_with_dipm"),
                    Want::Original,
                    v("max_performance"),
                ),
                false,
                &mut orig,
                &mut report,
            );
        }
    }

    for f in nvidia_functions(&p.sys) {
        set(
            &f.join("power/control"),
            &pick(v("auto"), v("auto"), v("on")),
            false,
            &mut orig,
            &mut report,
        );
    }

    set(
        &p.proc.join("sys/kernel/nmi_watchdog"),
        &pick(v("0"), Want::Original, Want::Original),
        false,
        &mut orig,
        &mut report,
    );
    set(
        &p.proc.join("sys/vm/dirty_writeback_centisecs"),
        &pick(v("1500"), Want::Original, Want::Original),
        false,
        &mut orig,
        &mut report,
    );

    if let Some(iw) = &p.iw {
        let want = match mode {
            Mode::Saver => Some("on"),
            Mode::Performance => Some("off"),
            Mode::Balanced => None, // NetworkManager's own choice
        };
        for ifc in wifi_interfaces(&p.sys) {
            match want {
                Some(w) => {
                    let ok = Command::new(iw)
                        .args(["dev", &ifc, "set", "power_save", w])
                        .status()
                        .is_ok_and(|s| s.success());
                    report.push(format!(
                        "wifi {ifc}: power_save {w}{}",
                        if ok { "" } else { " (failed)" }
                    ));
                }
                None => report.push(format!("wifi {ifc}: left to NetworkManager")),
            }
        }
    }

    orig.save();
    report
}

/// For `status`: the current value of each knob the machine has.
pub fn status(p: &Paths) -> Vec<String> {
    let mut files = vec![
        p.sys.join("devices/system/cpu/intel_pstate/no_turbo"),
        p.sys.join("module/pcie_aspm/parameters/policy"),
        p.sys.join("module/snd_hda_intel/parameters/power_save"),
        p.proc.join("sys/kernel/nmi_watchdog"),
        p.proc.join("sys/vm/dirty_writeback_centisecs"),
    ];
    files.extend(
        rapl_domains(&p.sys)
            .into_iter()
            .map(|d| d.join("constraint_0_power_limit_uw")),
    );
    files.extend(
        nvidia_functions(&p.sys)
            .into_iter()
            .map(|d| d.join("power/control")),
    );
    files
        .into_iter()
        .map(|f| {
            format!(
                "{}: {}",
                f.display(),
                read(&f).unwrap_or_else(|| "not available".into())
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fx {
        p: Paths,
    }

    impl Fx {
        fn new(tag: &str) -> Fx {
            let root = std::env::temp_dir().join(format!("uo-power-{tag}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            let p = Paths {
                sys: root.join("sys"),
                proc: root.join("proc"),
                run: root.join("run"),
                iw: None,
            };
            let fx = Fx { p };
            fx.w("sys/devices/system/cpu/intel_pstate/no_turbo", "0\n");
            fx.w(
                "sys/module/pcie_aspm/parameters/policy",
                "[default] performance powersave powersupersave\n",
            );
            fx.w("sys/module/snd_hda_intel/parameters/power_save", "1\n");
            fx.w(
                "sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw",
                "45000000\n",
            );
            fx.w(
                "sys/class/powercap/intel-rapl:0:0/constraint_0_power_limit_uw",
                "1000\n",
            );
            // a USB stick (mass storage) and a USB mouse (HID)
            fx.w("sys/bus/usb/devices/1-1/power/control", "on\n");
            fx.w("sys/bus/usb/devices/1-1/1-1:1.0/bInterfaceClass", "08\n");
            fx.w("sys/bus/usb/devices/1-2/power/control", "on\n");
            fx.w("sys/bus/usb/devices/1-2/1-2:1.0/bInterfaceClass", "03\n");
            fx.w("sys/bus/pci/devices/0000:01:00.0/vendor", "0x10de\n");
            fx.w("sys/bus/pci/devices/0000:01:00.0/power/control", "auto\n"); // Ubuntu's default
            fx.w("proc/sys/kernel/nmi_watchdog", "1\n");
            fx.w("proc/sys/vm/dirty_writeback_centisecs", "500\n");
            fx
        }

        fn w(&self, rel: &str, v: &str) {
            let root = self.p.sys.parent().unwrap();
            let f = root.join(rel);
            fs::create_dir_all(f.parent().unwrap()).unwrap();
            fs::write(f, v).unwrap();
        }

        fn r(&self, rel: &str) -> String {
            read(&self.p.sys.parent().unwrap().join(rel)).unwrap()
        }
    }

    #[test]
    fn saver_sets_every_knob_and_balanced_puts_the_originals_back() {
        let fx = Fx::new("roundtrip");
        apply(&fx.p, Mode::Saver);
        assert_eq!(fx.r("sys/devices/system/cpu/intel_pstate/no_turbo"), "1");
        assert_eq!(
            fx.r("sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw"),
            "27000000"
        );
        assert_eq!(
            fx.r("sys/class/powercap/intel-rapl:0:0/constraint_0_power_limit_uw"),
            "1000"
        );
        assert_eq!(
            fx.r("sys/module/pcie_aspm/parameters/policy"),
            "powersupersave"
        );
        assert_eq!(fx.r("sys/bus/usb/devices/1-1/power/control"), "auto");
        assert_eq!(
            fx.r("sys/bus/usb/devices/1-2/power/control"),
            "on",
            "the mouse never sleeps"
        );
        assert_eq!(
            fx.r("sys/bus/pci/devices/0000:01:00.0/power/control"),
            "auto"
        );
        assert_eq!(fx.r("proc/sys/kernel/nmi_watchdog"), "0");
        assert_eq!(fx.r("proc/sys/vm/dirty_writeback_centisecs"), "1500");

        // Saver again changes nothing, and doesn't lose the originals.
        apply(&fx.p, Mode::Saver);
        apply(&fx.p, Mode::Balanced);
        assert_eq!(fx.r("sys/devices/system/cpu/intel_pstate/no_turbo"), "0");
        assert_eq!(
            fx.r("sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw"),
            "45000000"
        );
        assert_eq!(fx.r("sys/module/pcie_aspm/parameters/policy"), "default");
        assert_eq!(fx.r("sys/bus/usb/devices/1-1/power/control"), "on");
        assert_eq!(fx.r("proc/sys/kernel/nmi_watchdog"), "1");
        assert_eq!(fx.r("proc/sys/vm/dirty_writeback_centisecs"), "500");
    }

    #[test]
    fn performance_is_full_speed() {
        let fx = Fx::new("perf");
        apply(&fx.p, Mode::Saver);
        apply(&fx.p, Mode::Performance);
        assert_eq!(fx.r("sys/devices/system/cpu/intel_pstate/no_turbo"), "0");
        assert_eq!(
            fx.r("sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw"),
            "45000000"
        );
        assert_eq!(
            fx.r("sys/module/pcie_aspm/parameters/policy"),
            "performance"
        );
        assert_eq!(fx.r("sys/module/snd_hda_intel/parameters/power_save"), "0");
        assert_eq!(fx.r("sys/bus/pci/devices/0000:01:00.0/power/control"), "on");
    }

    #[test]
    fn pl1_floor_and_ceiling() {
        assert_eq!(saver_pl1(45_000_000), 27_000_000);
        assert_eq!(saver_pl1(20_000_000), PL1_FLOOR_UW); // 12 W would be too slow
        assert_eq!(saver_pl1(10_000_000), 10_000_000); // never above the machine's own default
    }

    #[test]
    fn missing_knobs_and_unoffered_values_are_reported_not_errors() {
        let fx = Fx::new("missing");
        fs::remove_file(fx.p.sys.join("devices/system/cpu/intel_pstate/no_turbo")).unwrap();
        fx.w(
            "sys/module/pcie_aspm/parameters/policy",
            "[default] performance\n",
        );
        let r = apply(&fx.p, Mode::Saver);
        assert!(r.iter().any(|l| l.contains("no_turbo: not available")));
        assert!(r.iter().any(|l| l.contains("powersupersave not offered")));
    }

    #[test]
    fn balanced_on_a_fresh_machine_changes_nothing() {
        let fx = Fx::new("fresh");
        let r = apply(&fx.p, Mode::Balanced);
        assert!(
            r.iter()
                .all(|l| l.contains("already") || l.contains("unchanged")),
            "{r:?}"
        );
    }

    #[test]
    fn mode_names() {
        assert_eq!(Mode::parse("power-saver"), Some(Mode::Saver));
        assert_eq!(Mode::parse("performance"), Some(Mode::Performance));
        assert_eq!(Mode::parse("turbo"), None);
    }
}
