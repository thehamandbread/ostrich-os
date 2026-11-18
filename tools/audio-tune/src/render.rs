//! Rendering listening-test clips through an EQ: music and speech (clips.rs), or pink noise when
//! no clip is installed, written as a WAV file.
//!
//! The A/B test plays two variants of the same clip with a plain player (`pw-play`) straight to the
//! speakers, so switching between A and B is instant and PipeWire never restarts mid-test. The EQ
//! here is the same RBJ biquads PipeWire's filter-chain runs (eq.rs), so what's heard is what gets
//! applied.

use crate::eq::{coefficients, Eq};

pub const RATE: u32 = 48000;

/// Pink noise (Paul Kellet's filter on xorshift white noise), deterministic, about -18 dBFS RMS.
pub fn pink_noise(seconds: f64, rate: u32, seed: u64) -> Vec<f32> {
    let n = (seconds * rate as f64) as usize;
    let mut x = seed.max(1);
    let mut b = [0f64; 7];
    let mut out = Vec::with_capacity(n);
    for _ in 0..n {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        let white = (x >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0;
        b[0] = 0.99886 * b[0] + white * 0.0555179;
        b[1] = 0.99332 * b[1] + white * 0.0750759;
        b[2] = 0.96900 * b[2] + white * 0.153852;
        b[3] = 0.86650 * b[3] + white * 0.3104856;
        b[4] = 0.55000 * b[4] + white * 0.5329522;
        b[5] = -0.7616 * b[5] - white * 0.0168980;
        let pink = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362;
        b[6] = white * 0.115926;
        out.push((pink * 0.05) as f32);
    }
    out
}

/// The clip through the EQ (preamp included, so boosts can't clip), with 20 ms fades.
pub fn render(eq: &Eq, input: &[f32], rate: u32) -> Vec<f32> {
    let pre = 10f64.powf(eq.preamp_db() / 20.0);
    let mut s: Vec<f64> = input.iter().map(|&v| v as f64 * pre).collect();
    for band in &eq.bands {
        let [b0, b1, b2, a0, a1, a2] = coefficients(band, rate as f64);
        let (b0, b1, b2, a1, a2) = (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);
        let (mut z1, mut z2) = (0.0, 0.0); // transposed direct form II
        for v in s.iter_mut() {
            let y = b0 * *v + z1;
            z1 = b1 * *v - a1 * y + z2;
            z2 = b2 * *v - a2 * y;
            *v = y;
        }
    }
    let fade = (rate as usize / 50).min(s.len() / 2);
    let len = s.len();
    for i in 0..fade {
        let g = i as f64 / fade as f64;
        s[i] *= g;
        s[len - 1 - i] *= g;
    }
    s.iter().map(|&v| v.clamp(-1.0, 1.0) as f32).collect()
}

/// A stereo clip (music) through the EQ: each channel on its own, as PipeWire does.
pub fn render_stereo(eq: &Eq, frames: &[[f32; 2]], rate: u32) -> Vec<[f32; 2]> {
    let left: Vec<f32> = frames.iter().map(|f| f[0]).collect();
    let right: Vec<f32> = frames.iter().map(|f| f[1]).collect();
    let (l, r) = (render(eq, &left, rate), render(eq, &right, rate));
    l.into_iter().zip(r).map(|(a, b)| [a, b]).collect()
}

/// 16-bit stereo PCM WAV (the mono clip on both channels).
pub fn wav(samples: &[f32], rate: u32) -> Vec<u8> {
    let data_len = (samples.len() * 4) as u32;
    let mut w = Vec::with_capacity(44 + data_len as usize);
    w.extend_from_slice(b"RIFF");
    w.extend_from_slice(&(36 + data_len).to_le_bytes());
    w.extend_from_slice(b"WAVEfmt ");
    w.extend_from_slice(&16u32.to_le_bytes());
    w.extend_from_slice(&1u16.to_le_bytes()); // PCM
    w.extend_from_slice(&2u16.to_le_bytes()); // channels
    w.extend_from_slice(&rate.to_le_bytes());
    w.extend_from_slice(&(rate * 4).to_le_bytes()); // byte rate
    w.extend_from_slice(&4u16.to_le_bytes()); // block align
    w.extend_from_slice(&16u16.to_le_bytes()); // bits
    w.extend_from_slice(b"data");
    w.extend_from_slice(&data_len.to_le_bytes());
    for &v in samples {
        let s = (v * 32767.0).round() as i16;
        w.extend_from_slice(&s.to_le_bytes());
        w.extend_from_slice(&s.to_le_bytes());
    }
    w
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::eq::{preset, three_band};

    fn sine(freq: f64, n: usize) -> Vec<f32> {
        (0..n)
            .map(|i| {
                (0.25 * (2.0 * std::f64::consts::PI * freq * i as f64 / RATE as f64).sin()) as f32
            })
            .collect()
    }

    fn rms(s: &[f32]) -> f64 {
        // the middle, away from the fades and the filter settling
        let m = &s[s.len() / 4..s.len() * 3 / 4];
        (m.iter().map(|v| (*v as f64).powi(2)).sum::<f64>() / m.len() as f64).sqrt()
    }

    #[test]
    fn flat_leaves_the_clip_alone() {
        let x = pink_noise(0.5, RATE, 7);
        let y = render(&preset("flat").unwrap(), &x, RATE);
        let fade = RATE as usize / 50;
        assert!(x[fade..x.len() - fade]
            .iter()
            .zip(&y[fade..y.len() - fade])
            .all(|(a, b)| (a - b).abs() < 1e-6));
    }

    #[test]
    fn the_rendered_gain_matches_the_eq_response() {
        let eq = three_band("t", 6.0, 0.0, -6.0);
        for f in [60.0, 15000.0] {
            let x = sine(f, RATE as usize);
            let got = 20.0 * (rms(&render(&eq, &x, RATE)) / rms(&x)).log10();
            let want = eq.response_db(f, RATE as f64) + eq.preamp_db();
            assert!(
                (got - want).abs() < 0.3,
                "{f} Hz: got {got:.2} dB, want {want:.2}"
            );
        }
    }

    #[test]
    fn noise_is_deterministic_and_never_clips() {
        assert_eq!(pink_noise(0.1, RATE, 3), pink_noise(0.1, RATE, 3));
        let loud = render(
            &three_band("b", 9.0, 9.0, 9.0),
            &pink_noise(1.0, RATE, 3),
            RATE,
        );
        assert!(loud.iter().all(|v| v.abs() <= 1.0));
    }

    #[test]
    fn stereo_channels_are_filtered_alike() {
        let eq = three_band("t", 6.0, 0.0, -6.0);
        let x = pink_noise(0.5, RATE, 5);
        let frames: Vec<[f32; 2]> = x.iter().map(|&v| [v, v]).collect();
        let y = render_stereo(&eq, &frames, RATE);
        assert_eq!(y.len(), frames.len());
        assert!(y.iter().all(|f| (f[0] - f[1]).abs() < 1e-6));
        assert_eq!(
            y.iter().map(|f| f[0]).collect::<Vec<_>>(),
            render(&eq, &x, RATE)
        );
    }

    #[test]
    fn wav_header_and_length() {
        let w = wav(&[0.0, 0.5, -0.5], RATE);
        assert_eq!(&w[0..4], b"RIFF");
        assert_eq!(&w[8..16], b"WAVEfmt ");
        assert_eq!(u32::from_le_bytes(w[40..44].try_into().unwrap()), 12);
        assert_eq!(w.len(), 44 + 12);
    }
}
