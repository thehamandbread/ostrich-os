//! PipeWire filter-chain config for the speaker EQ (builtin biquads only: no plugins, no daemon).
//!
//! The chain is a WirePlumber 0.5 "smart filter" on the built-in speaker sink: WirePlumber links
//! whatever plays to the speakers through it automatically, so the default output, its volume and
//! the sound menu stay the hardware device, and other outputs (Bluetooth, HDMI) never pass through it.
//! PipeWire duplicates the mono builtin graph for each channel. The preamp (negative gain so the
//! largest boost can't clip) is a high shelf at 1 Hz: every audible frequency is above it, so it is
//! a plain gain.

use crate::eq::{Band, Eq, Kind};

pub const NODE_NAME: &str = "ostrich_os_speakers";

fn fmt(x: f64) -> String {
    let s = format!("{x:.3}");
    let s = s.trim_end_matches('0').trim_end_matches('.').to_string();
    if s == "-0" {
        "0".into()
    } else {
        s
    }
}

fn node(name: &str, b: &Band) -> String {
    format!(
        "          {{ type = builtin name = {name} label = {} control = {{ \"Freq\" = {} \"Q\" = {} \"Gain\" = {} }} }}\n",
        b.kind.label(),
        fmt(b.freq),
        fmt(b.q),
        fmt(b.gain_db)
    )
}

/// The full drop-in (for ~/.config/pipewire/pipewire.conf.d/). `target` is the speaker sink name.
pub fn filter_chain(eq: &Eq, target: &str) -> String {
    let pre = Band {
        kind: Kind::HighShelf,
        freq: 1.0,
        q: 0.7,
        gain_db: eq.preamp_db(),
    };
    let mut nodes = node("preamp", &pre);
    let mut names = vec!["preamp".to_string()];
    for (i, b) in eq.bands.iter().enumerate() {
        let n = format!("eq{}", i + 1);
        nodes.push_str(&node(&n, b));
        names.push(n);
    }
    let links: String = names
        .windows(2)
        .map(|w| {
            format!(
                "          {{ output = \"{}:Out\" input = \"{}:In\" }}\n",
                w[0], w[1]
            )
        })
        .collect();
    format!(
        "# Speaker tuning from Ostrich OS (ostrich speakers). Preset: {name}\n\
         # Generated file: change it with `ostrich speakers`, remove it with `ostrich speakers off`.\n\
         context.modules = [\n\
         \x20 {{ name = libpipewire-module-filter-chain\n\
         \x20   args = {{\n\
         \x20     node.description = \"Speakers (tuned)\"\n\
         \x20     media.name = \"Speakers (tuned)\"\n\
         \x20     filter.graph = {{\n\
         \x20       nodes = [\n{nodes}\x20       ]\n\
         \x20       links = [\n{links}\x20       ]\n\
         \x20     }}\n\
         \x20     audio.channels = 2\n\
         \x20     audio.position = [ FL FR ]\n\
         \x20     capture.props = {{\n\
         \x20       node.name = \"{NODE_NAME}\"\n\
         \x20       media.class = Audio/Sink\n\
         \x20       filter.smart = true\n\
         \x20       filter.smart.name = \"{NODE_NAME}\"\n\
         \x20       filter.smart.target = {{ node.name = \"{target}\" }}\n\
         \x20     }}\n\
         \x20     playback.props = {{ node.name = \"{NODE_NAME}.output\" node.passive = true }}\n\
         \x20   }}\n\
         \x20 }}\n\
         ]\n",
        name = eq.name,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::eq::preset;

    #[test]
    fn config_has_every_band_linked_in_order() {
        let c = filter_chain(
            &preset("voice").unwrap(),
            "alsa_output.pci-0000_00_1f.3.analog-stereo",
        );
        assert!(c.contains(
            "label = bq_lowshelf control = { \"Freq\" = 120 \"Q\" = 0.7 \"Gain\" = -4 }"
        ));
        assert!(
            c.contains("label = bq_peaking control = { \"Freq\" = 2500 \"Q\" = 1 \"Gain\" = 3 }")
        );
        assert!(c.contains("{ output = \"preamp:Out\" input = \"eq1:In\" }"));
        assert!(c.contains("{ output = \"eq2:Out\" input = \"eq3:In\" }"));
        assert!(!c.contains("eq4"));
        assert!(c.contains(
            "filter.smart.target = { node.name = \"alsa_output.pci-0000_00_1f.3.analog-stereo\" }"
        ));
        assert!(c.contains("filter.smart = true"));
    }

    #[test]
    fn preamp_matches_the_boost() {
        let c = filter_chain(&preset("bass").unwrap(), "x");
        let line = c.lines().find(|l| l.contains("name = preamp")).unwrap();
        assert!(line.contains("\"Gain\" = -"), "{line}");
        let flat = filter_chain(&preset("flat").unwrap(), "x");
        assert!(flat
            .lines()
            .find(|l| l.contains("name = preamp"))
            .unwrap()
            .contains("\"Gain\" = 0 "));
    }

    #[test]
    fn braces_balance() {
        let c = filter_chain(&preset("movie").unwrap(), "x");
        assert_eq!(c.matches('{').count(), c.matches('}').count());
        assert_eq!(c.matches('[').count(), c.matches(']').count());
    }
}
