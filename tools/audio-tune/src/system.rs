//! The parts that touch the system: where the config lives, which sink the speakers are, the
//! saved "custom" preset from the listening test, and restarting PipeWire. Used by the CLI and
//! the setup wizard.

use crate::eq::{self, Eq};
use crate::pipewire;
use std::path::PathBuf;
use std::process::Command;
use std::{env, fs};

fn config_home() -> PathBuf {
    env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(".config"))
}

pub fn conf_path() -> PathBuf {
    config_home().join("pipewire/pipewire.conf.d/90-ubuntu-ostrich-speakers.conf")
}

/// The listening test's result: "low mid high" gains in dB.
pub fn custom_path() -> PathBuf {
    config_home().join("ubuntu-ostrich/speakers-custom")
}

pub fn parse_custom(text: &str) -> Option<[f64; 3]> {
    let v: Vec<f64> = text
        .split_whitespace()
        .map(|w| w.parse().ok())
        .collect::<Option<_>>()?;
    let g: [f64; 3] = v.try_into().ok()?;
    g.iter()
        .all(|x| x.is_finite() && x.abs() <= 24.0)
        .then_some(g)
}

pub fn load_custom() -> Option<Eq> {
    let g = parse_custom(&fs::read_to_string(custom_path()).ok()?)?;
    Some(eq::three_band("custom", g[0], g[1], g[2]))
}

pub fn save_custom(g: [f64; 3]) -> std::io::Result<()> {
    let p = custom_path();
    if let Some(d) = p.parent() {
        fs::create_dir_all(d)?;
    }
    fs::write(p, format!("{:.2} {:.2} {:.2}\n", g[0], g[1], g[2]))
}

/// A preset by name, including "custom" once the listening test has saved one.
pub fn preset(name: &str) -> Option<Eq> {
    if name == "custom" {
        load_custom()
    } else {
        eq::preset(name)
    }
}

/// The real speaker sink: the filter's target if tuning is on, else the default sink when that is the
/// built-in speakers. A Bluetooth, HDMI or USB default is not: tuning is for the built-in speakers only,
/// so those give None (the caller asks for `--target`).
pub fn speaker_sink() -> Option<String> {
    if let Ok(conf) = fs::read_to_string(conf_path()) {
        if let Some(t) = target_in_conf(&conf) {
            return Some(t);
        }
    }
    // wpctl ships with WirePlumber; pactl (pulseaudio-utils) isn't installed by default.
    let out = Command::new("wpctl")
        .args(["inspect", "@DEFAULT_AUDIO_SINK@"])
        .output()
        .ok()?;
    let name = node_name(&String::from_utf8_lossy(&out.stdout))?;
    (out.status.success() && !name.starts_with(pipewire::NODE_NAME) && is_builtin(&name))
        .then_some(name)
}

/// A sink node name that is the machine's own sound card, not Bluetooth, HDMI or USB.
/// shortcut: judged by the node name alone; a card that names itself oddly can be named with `--target`.
pub fn is_builtin(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    n.starts_with("alsa_output.")
        && !n.contains("hdmi")
        && !n.contains("usb")
        && !n.contains("bluez")
}

/// `node.name = "..."` from `wpctl inspect` output.
pub fn node_name(inspect: &str) -> Option<String> {
    inspect.lines().find_map(|l| {
        let v = l
            .trim()
            .trim_start_matches('*')
            .trim()
            .strip_prefix("node.name = \"")?;
        let v = v.strip_suffix('"')?;
        (!v.is_empty()).then(|| v.to_string())
    })
}

/// The speaker node from our filter-chain drop-in (`filter.smart.target = { node.name = "..." }`).
pub fn target_in_conf(conf: &str) -> Option<String> {
    let rest = conf
        .split("filter.smart.target = { node.name = \"")
        .nth(1)?;
    let t = rest.split('"').next()?;
    (!t.is_empty()).then(|| t.to_string())
}

pub fn restart_pipewire() {
    let _ = Command::new("systemctl")
        .args([
            "--user",
            "restart",
            "pipewire",
            "pipewire-pulse",
            "wireplumber",
        ])
        .status();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn custom_gains_parse_and_are_bounded() {
        assert_eq!(parse_custom("1.5 -2 3.25\n"), Some([1.5, -2.0, 3.25]));
        assert_eq!(parse_custom("1 2"), None);
        assert_eq!(parse_custom("1 2 x"), None);
        assert_eq!(parse_custom("1 2 99"), None);
    }

    #[test]
    fn reads_the_node_name_from_wpctl() {
        let out = "id 47, type PipeWire:Interface:Node\n    alsa.card = \"0\"\n  * media.class = \"Audio/Sink\"\n  * node.name = \"alsa_output.pci-0000_00_1f.3.analog-stereo\"\n";
        assert_eq!(
            node_name(out).as_deref(),
            Some("alsa_output.pci-0000_00_1f.3.analog-stereo")
        );
        assert_eq!(node_name("nothing"), None);
    }

    #[test]
    fn only_the_machines_own_sound_card_counts_as_the_speakers() {
        assert!(is_builtin("alsa_output.pci-0000_00_1f.3.analog-stereo"));
        assert!(is_builtin(
            "alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__hw_sofhdadsp__sink"
        ));
        assert!(!is_builtin("bluez_output.AA_BB_CC_DD_EE_01.1"));
        assert!(!is_builtin("alsa_output.pci-0000_01_00.1.hdmi-stereo"));
        assert!(!is_builtin("alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__hw_sofhdadsp_5__sink_HDMI"));
        assert!(!is_builtin(
            "alsa_output.usb-Generic_USB_Audio-00.analog-stereo"
        ));
        assert!(!is_builtin("ostrich-speakers"));
    }

    #[test]
    fn finds_the_target_in_our_drop_in() {
        let c = pipewire::filter_chain(
            &eq::preset("voice").unwrap(),
            "alsa_output.pci-0000_00_1f.3.analog-stereo",
        );
        assert_eq!(
            target_in_conf(&c).as_deref(),
            Some("alsa_output.pci-0000_00_1f.3.analog-stereo")
        );
        assert_eq!(target_in_conf("nothing here"), None);
    }
}

/// The preset in the applied conf file ("Preset: voice" in its header), or None when tuning is off.
pub fn current_preset() -> Option<String> {
    let text = std::fs::read_to_string(conf_path()).ok()?;
    preset_in_conf(&text)
}

pub fn preset_in_conf(conf: &str) -> Option<String> {
    conf.lines()
        .find_map(|l| l.split_once("Preset: ").map(|(_, p)| p.trim().to_string()))
        .filter(|p| !p.is_empty())
}

#[cfg(test)]
mod current_tests {
    #[test]
    fn preset_from_the_conf_header() {
        let conf = crate::pipewire::filter_chain(&crate::eq::preset("voice").unwrap(), "x");
        assert_eq!(super::preset_in_conf(&conf).as_deref(), Some("voice"));
        assert_eq!(super::preset_in_conf("nothing"), None);
    }
}
