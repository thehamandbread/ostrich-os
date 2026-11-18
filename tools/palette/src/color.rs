//! Colour maths: sRGB, linear RGB, OKLab/OKLCh, WCAG contrast.

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rgb {
    pub r: f32,
    pub g: f32,
    pub b: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Lab {
    pub l: f32,
    pub a: f32,
    pub b: f32,
}

fn to_linear(c: f32) -> f32 {
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

fn to_srgb(c: f32) -> f32 {
    let c = c.clamp(0.0, 1.0);
    if c <= 0.003_130_8 {
        12.92 * c
    } else {
        1.055 * c.powf(1.0 / 2.4) - 0.055
    }
}

impl Rgb {
    pub fn from_u8(r: u8, g: u8, b: u8) -> Self {
        Rgb {
            r: r as f32 / 255.0,
            g: g as f32 / 255.0,
            b: b as f32 / 255.0,
        }
    }

    pub fn from_hex(hex: &str) -> Option<Self> {
        let h = hex.strip_prefix('#')?;
        if h.len() != 6 {
            return None;
        }
        let v = u32::from_str_radix(h, 16).ok()?;
        Some(Self::from_u8((v >> 16) as u8, (v >> 8) as u8, v as u8))
    }

    pub fn to_u8(self) -> (u8, u8, u8) {
        let q = |c: f32| (c.clamp(0.0, 1.0) * 255.0).round() as u8;
        (q(self.r), q(self.g), q(self.b))
    }

    pub fn hex(self) -> String {
        let (r, g, b) = self.to_u8();
        format!("#{r:02x}{g:02x}{b:02x}")
    }

    /// WCAG relative luminance.
    pub fn luminance(self) -> f32 {
        0.2126 * to_linear(self.r) + 0.7152 * to_linear(self.g) + 0.0722 * to_linear(self.b)
    }

    pub fn to_lab(self) -> Lab {
        let (r, g, b) = (to_linear(self.r), to_linear(self.g), to_linear(self.b));
        let l = (0.412_221_47 * r + 0.536_332_55 * g + 0.051_445_99 * b).cbrt();
        let m = (0.211_903_5 * r + 0.680_699_5 * g + 0.107_396_96 * b).cbrt();
        let s = (0.088_302_46 * r + 0.281_718_85 * g + 0.629_978_7 * b).cbrt();
        Lab {
            l: 0.210_454_26 * l + 0.793_617_8 * m - 0.004_072_047 * s,
            a: 1.977_998_5 * l - 2.428_592_2 * m + 0.450_593_7 * s,
            b: 0.025_904_037 * l + 0.782_771_77 * m - 0.808_675_77 * s,
        }
    }
}

impl Lab {
    pub fn to_rgb(self) -> Rgb {
        let l = (self.l + 0.396_337_78 * self.a + 0.215_803_76 * self.b).powi(3);
        let m = (self.l - 0.105_561_346 * self.a - 0.063_854_17 * self.b).powi(3);
        let s = (self.l - 0.089_484_18 * self.a - 1.291_485_5 * self.b).powi(3);
        Rgb {
            r: to_srgb(4.076_741_7 * l - 3.307_711_6 * m + 0.230_969_94 * s),
            g: to_srgb(-1.268_438 * l + 2.609_757_4 * m - 0.341_319_38 * s),
            b: to_srgb(-0.004_196_086_3 * l - 0.703_418_6 * m + 1.707_614_7 * s),
        }
    }

    pub fn chroma(self) -> f32 {
        (self.a * self.a + self.b * self.b).sqrt()
    }

    /// Hue angle in degrees, 0..360.
    pub fn hue(self) -> f32 {
        self.b.atan2(self.a).to_degrees().rem_euclid(360.0)
    }

    pub fn dist2(self, o: Lab) -> f32 {
        (self.l - o.l).powi(2) + (self.a - o.a).powi(2) + (self.b - o.b).powi(2)
    }
}

/// WCAG contrast ratio between two colours (1..21).
pub fn contrast(x: Rgb, y: Rgb) -> f32 {
    let (a, b) = (x.luminance(), y.luminance());
    let (hi, lo) = if a > b { (a, b) } else { (b, a) };
    (hi + 0.05) / (lo + 0.05)
}

/// Shortest distance between two hue angles in degrees.
pub fn hue_distance(a: f32, b: f32) -> f32 {
    let d = (a - b).rem_euclid(360.0);
    d.min(360.0 - d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trip() {
        let c = Rgb::from_hex("#3584e4").unwrap();
        assert_eq!(c.hex(), "#3584e4");
        assert!(Rgb::from_hex("3584e4").is_none());
        assert!(Rgb::from_hex("#12345").is_none());
    }

    #[test]
    fn oklab_round_trip() {
        for hex in ["#3584e4", "#e62d42", "#000000", "#ffffff", "#9141ac"] {
            let c = Rgb::from_hex(hex).unwrap();
            assert_eq!(c.to_lab().to_rgb().hex(), hex, "{hex}");
        }
    }

    #[test]
    fn oklab_known_values() {
        let white = Rgb::from_hex("#ffffff").unwrap().to_lab();
        assert!((white.l - 1.0).abs() < 1e-3 && white.chroma() < 1e-3);
        let black = Rgb::from_hex("#000000").unwrap().to_lab();
        assert!(black.l.abs() < 1e-3);
    }

    #[test]
    fn contrast_extremes() {
        let w = Rgb::from_hex("#ffffff").unwrap();
        let k = Rgb::from_hex("#000000").unwrap();
        assert!((contrast(w, k) - 21.0).abs() < 0.01);
        assert!((contrast(w, w) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn hue_distance_wraps() {
        assert!((hue_distance(350.0, 10.0) - 20.0).abs() < 1e-4);
        assert!((hue_distance(10.0, 190.0) - 180.0).abs() < 1e-4);
    }
}
