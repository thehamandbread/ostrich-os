//! Parametric EQ: bands, presets, and the frequency response (RBJ Audio EQ Cookbook biquads).

use std::f64::consts::PI;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    LowShelf,
    Peaking,
    HighShelf,
}

impl Kind {
    /// PipeWire filter-chain builtin label.
    pub fn label(self) -> &'static str {
        match self {
            Kind::LowShelf => "bq_lowshelf",
            Kind::Peaking => "bq_peaking",
            Kind::HighShelf => "bq_highshelf",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Band {
    pub kind: Kind,
    pub freq: f64,
    pub q: f64,
    pub gain_db: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Eq {
    pub name: String,
    pub bands: Vec<Band>,
}

impl Eq {
    /// Gain applied before the bands so the loudest boost can't clip: minus the response peak.
    pub fn preamp_db(&self) -> f64 {
        let peak = (0..=200)
            .map(|i| 20.0 * 1000f64.powf(i as f64 / 200.0)) // 20 Hz .. 20 kHz, log spaced
            .map(|f| self.response_db(f, 48000.0))
            .fold(f64::MIN, f64::max);
        -(peak.max(0.0))
    }

    /// Total response in dB at `freq` (sum of every band's magnitude in dB).
    pub fn response_db(&self, freq: f64, rate: f64) -> f64 {
        self.bands
            .iter()
            .map(|b| band_response_db(b, freq, rate))
            .sum()
    }
}

/// Biquad coefficients (b0, b1, b2, a0, a1, a2) from the RBJ cookbook.
pub fn coefficients(b: &Band, rate: f64) -> [f64; 6] {
    let a = 10f64.powf(b.gain_db / 40.0);
    let w0 = 2.0 * PI * b.freq / rate;
    let (sin, cos) = w0.sin_cos();
    let alpha = sin / (2.0 * b.q);
    match b.kind {
        Kind::Peaking => [
            1.0 + alpha * a,
            -2.0 * cos,
            1.0 - alpha * a,
            1.0 + alpha / a,
            -2.0 * cos,
            1.0 - alpha / a,
        ],
        Kind::LowShelf => {
            let s = 2.0 * a.sqrt() * alpha;
            [
                a * ((a + 1.0) - (a - 1.0) * cos + s),
                2.0 * a * ((a - 1.0) - (a + 1.0) * cos),
                a * ((a + 1.0) - (a - 1.0) * cos - s),
                (a + 1.0) + (a - 1.0) * cos + s,
                -2.0 * ((a - 1.0) + (a + 1.0) * cos),
                (a + 1.0) + (a - 1.0) * cos - s,
            ]
        }
        Kind::HighShelf => {
            let s = 2.0 * a.sqrt() * alpha;
            [
                a * ((a + 1.0) + (a - 1.0) * cos + s),
                -2.0 * a * ((a - 1.0) + (a + 1.0) * cos),
                a * ((a + 1.0) + (a - 1.0) * cos - s),
                (a + 1.0) - (a - 1.0) * cos + s,
                2.0 * ((a - 1.0) - (a + 1.0) * cos),
                (a + 1.0) - (a - 1.0) * cos - s,
            ]
        }
    }
}

/// Magnitude of one band at `freq`, in dB.
pub fn band_response_db(b: &Band, freq: f64, rate: f64) -> f64 {
    let [b0, b1, b2, a0, a1, a2] = coefficients(b, rate);
    let w = 2.0 * PI * freq / rate;
    // H(e^jw) = (b0 + b1 z^-1 + b2 z^-2) / (a0 + a1 z^-1 + a2 z^-2)
    let (c1, s1) = (w.cos(), w.sin());
    let (c2, s2) = ((2.0 * w).cos(), (2.0 * w).sin());
    let num = (b0 + b1 * c1 + b2 * c2, -(b1 * s1 + b2 * s2));
    let den = (a0 + a1 * c1 + a2 * c2, -(a1 * s1 + a2 * s2));
    let mag2 = (num.0 * num.0 + num.1 * num.1) / (den.0 * den.0 + den.1 * den.1);
    10.0 * mag2.log10()
}

fn band(kind: Kind, freq: f64, q: f64, gain_db: f64) -> Band {
    Band {
        kind,
        freq,
        q,
        gain_db,
    }
}

/// The three band groups the A/B test adjusts: low shelf, a broad mid, high shelf.
pub fn three_band(name: &str, low: f64, mid: f64, high: f64) -> Eq {
    Eq {
        name: name.into(),
        bands: vec![
            band(Kind::LowShelf, 150.0, 0.7, low),
            band(Kind::Peaking, 1500.0, 0.8, mid),
            band(Kind::HighShelf, 6000.0, 0.7, high),
        ],
    }
}

pub fn preset(name: &str) -> Option<Eq> {
    Some(match name {
        "flat" => three_band("flat", 0.0, 0.0, 0.0),
        // presence for speech, less boom
        "voice" => Eq {
            name: "voice".into(),
            bands: vec![
                band(Kind::LowShelf, 120.0, 0.7, -4.0),
                band(Kind::Peaking, 2500.0, 1.0, 3.0),
                band(Kind::HighShelf, 8000.0, 0.7, 1.0),
            ],
        },
        "music" => three_band("music", 3.0, -1.0, 2.0),
        "bass" => Eq {
            name: "bass".into(),
            bands: vec![
                band(Kind::LowShelf, 120.0, 0.7, 6.0),
                band(Kind::Peaking, 60.0, 1.2, 2.0),
            ],
        },
        // dialogue up, a little low end
        "movie" => Eq {
            name: "movie".into(),
            bands: vec![
                band(Kind::LowShelf, 100.0, 0.7, 2.0),
                band(Kind::Peaking, 2000.0, 0.9, 3.0),
                band(Kind::HighShelf, 7000.0, 0.7, 1.0),
            ],
        },
        _ => return None,
    })
}

pub const PRESETS: [&str; 5] = ["flat", "voice", "music", "bass", "movie"];

#[cfg(test)]
mod tests {
    use super::*;

    fn near(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() < tol
    }

    #[test]
    fn peaking_hits_its_gain_at_its_frequency() {
        let b = band(Kind::Peaking, 1000.0, 1.0, 6.0);
        assert!(near(band_response_db(&b, 1000.0, 48000.0), 6.0, 0.01));
        assert!(band_response_db(&b, 50.0, 48000.0).abs() < 0.2);
    }

    #[test]
    fn shelves_reach_their_gain_far_from_the_corner() {
        let lo = band(Kind::LowShelf, 200.0, 0.7, 6.0);
        assert!(near(band_response_db(&lo, 20.0, 48000.0), 6.0, 0.2));
        assert!(band_response_db(&lo, 10000.0, 48000.0).abs() < 0.1);
        let hi = band(Kind::HighShelf, 5000.0, 0.7, -4.0);
        assert!(near(band_response_db(&hi, 20000.0, 48000.0), -4.0, 0.3));
    }

    #[test]
    fn flat_is_flat_and_needs_no_preamp() {
        let f = preset("flat").unwrap();
        assert!(f.response_db(1000.0, 48000.0).abs() < 1e-9);
        assert_eq!(f.preamp_db(), 0.0);
    }

    #[test]
    fn preamp_offsets_the_largest_boost() {
        let b = preset("bass").unwrap();
        let pre = b.preamp_db();
        assert!(pre < -5.0, "{pre}");
        let peak = (0..=200)
            .map(|i| 20.0 * 1000f64.powf(i as f64 / 200.0))
            .map(|f| b.response_db(f, 48000.0))
            .fold(f64::MIN, f64::max);
        assert!(near(peak + pre, 0.0, 1e-9));
    }

    #[test]
    fn every_preset_exists() {
        for p in PRESETS {
            assert!(preset(p).is_some(), "{p}");
        }
        assert!(preset("nope").is_none());
    }
}
