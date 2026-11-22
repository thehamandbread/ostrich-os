//! Music and speech clips for tuning by ear (data/clips.tsv, built in): the catalog, where the
//! installed excerpts live, and reading, cutting and writing 16-bit stereo WAV.
//!
//! The installer (modules/tools/install.sh) downloads each clip, checks its SHA-256, decodes it to
//! 48 kHz stereo WAV with GStreamer and runs `ostrich speakers clip-cut <id> <decoded.wav>`, which
//! keeps a 20-second excerpt, fades it in and out, and levels it, so every clip (and both sides
//! of an A/B comparison) plays equally loud.

use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq)]
pub struct Clip {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub url: String,
    pub sha256: String,
    pub start: f64,
    pub seconds: f64,
    pub licence: String,
    pub credit: String,
}

pub fn parse(text: &str) -> Vec<Clip> {
    text.lines()
        .filter(|l| !l.starts_with('#') && !l.trim().is_empty())
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            let [id, name, kind, url, sha256, start, seconds, licence, credit] = f.as_slice()
            else {
                return None;
            };
            Some(Clip {
                id: id.to_string(),
                name: name.to_string(),
                kind: kind.to_string(),
                url: url.to_string(),
                sha256: sha256.to_string(),
                start: start.parse().ok()?,
                seconds: seconds.parse().ok()?,
                licence: licence.to_string(),
                credit: credit.to_string(),
            })
        })
        .collect()
}

pub fn all() -> Vec<Clip> {
    parse(include_str!("../data/clips.tsv"))
}

pub fn find(id: &str) -> Option<Clip> {
    all().into_iter().find(|c| c.id == id)
}

pub fn dir() -> PathBuf {
    let data = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/share")
        });
    data.join("ostrich-os/audio")
}

/// The installed excerpt, if the installer got it.
pub fn path(id: &str) -> Option<PathBuf> {
    let p = dir().join(format!("{id}.wav"));
    p.is_file().then_some(p)
}

/// Interleaved stereo samples and the sample rate, from a 16-bit PCM WAV (mono is duplicated).
pub fn read_wav(bytes: &[u8]) -> Result<(Vec<[f32; 2]>, u32), String> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("not a WAV file".into());
    }
    let (mut channels, mut rate, mut bits) = (0u16, 0u32, 0u16);
    let mut i = 12;
    while i + 8 <= bytes.len() {
        let id = &bytes[i..i + 4];
        let len = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().unwrap()) as usize;
        let body = &bytes[i + 8..(i + 8 + len).min(bytes.len())];
        if id == b"fmt " && body.len() >= 16 {
            channels = u16::from_le_bytes([body[2], body[3]]);
            rate = u32::from_le_bytes(body[4..8].try_into().unwrap());
            bits = u16::from_le_bytes([body[14], body[15]]);
        } else if id == b"data" {
            if bits != 16 || !(1..=2).contains(&channels) {
                return Err(format!("unsupported WAV: {channels} channels, {bits} bits"));
            }
            let step = channels as usize * 2;
            let frames = body
                .chunks_exact(step)
                .map(|f| {
                    let l = i16::from_le_bytes([f[0], f[1]]) as f32 / 32768.0;
                    let r = if channels == 2 {
                        i16::from_le_bytes([f[2], f[3]]) as f32 / 32768.0
                    } else {
                        l
                    };
                    [l, r]
                })
                .collect();
            return Ok((frames, rate));
        }
        i += 8 + len + (len & 1);
    }
    Err("no audio data in the WAV file".into())
}

/// 16-bit stereo PCM WAV.
pub fn wav_stereo(frames: &[[f32; 2]], rate: u32) -> Vec<u8> {
    let data_len = (frames.len() * 4) as u32;
    let mut w = Vec::with_capacity(44 + data_len as usize);
    w.extend_from_slice(b"RIFF");
    w.extend_from_slice(&(36 + data_len).to_le_bytes());
    w.extend_from_slice(b"WAVEfmt ");
    w.extend_from_slice(&16u32.to_le_bytes());
    w.extend_from_slice(&1u16.to_le_bytes());
    w.extend_from_slice(&2u16.to_le_bytes());
    w.extend_from_slice(&rate.to_le_bytes());
    w.extend_from_slice(&(rate * 4).to_le_bytes());
    w.extend_from_slice(&4u16.to_le_bytes());
    w.extend_from_slice(&16u16.to_le_bytes());
    w.extend_from_slice(b"data");
    w.extend_from_slice(&data_len.to_le_bytes());
    for f in frames {
        for v in f {
            w.extend_from_slice(&((v.clamp(-1.0, 1.0) * 32767.0).round() as i16).to_le_bytes());
        }
    }
    w
}

/// The excerpt: `seconds` from `start`, half-second fades, levelled to `rms_db` (never clipping).
pub fn cut(frames: &[[f32; 2]], rate: u32, start: f64, seconds: f64, rms_db: f64) -> Vec<[f32; 2]> {
    let a = ((start * rate as f64) as usize).min(frames.len());
    let b = (a + (seconds * rate as f64) as usize).min(frames.len());
    let mut out: Vec<[f32; 2]> = frames[a..b].to_vec();
    let n = out.len();
    if n == 0 {
        return out;
    }
    let power: f64 = out
        .iter()
        .map(|f| (f[0] as f64).powi(2) + (f[1] as f64).powi(2))
        .sum::<f64>()
        / (2 * n) as f64;
    let peak = out
        .iter()
        .flat_map(|f| f.iter())
        .fold(0f32, |m, v| m.max(v.abs())) as f64;
    let rms = power.sqrt();
    let want = 10f64.powf(rms_db / 20.0);
    // Level to the target, but never so loud the peaks clip (0.95 headroom).
    let gain = if rms > 0.0 { want / rms } else { 1.0 };
    let gain = if peak > 0.0 {
        gain.min(0.95 / peak)
    } else {
        gain
    };
    let fade = (rate as usize / 2).min(n / 2);
    for (i, f) in out.iter_mut().enumerate() {
        let edge = i.min(n - 1 - i);
        let g = gain
            * if edge < fade {
                edge as f64 / fade as f64
            } else {
                1.0
            };
        f[0] = (f[0] as f64 * g) as f32;
        f[1] = (f[1] as f64 * g) as f32;
    }
    out
}

pub fn read_file(p: &Path) -> Result<(Vec<[f32; 2]>, u32), String> {
    let bytes = std::fs::read(p).map_err(|e| format!("{}: {e}", p.display()))?;
    read_wav(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_is_pinned_and_free() {
        let c = all();
        assert!(c.len() >= 4, "catalog failed to parse");
        for clip in &c {
            assert!(
                clip.url.starts_with("https://upload.wikimedia.org/"),
                "{}",
                clip.url
            );
            assert_eq!(clip.sha256.len(), 64, "{}", clip.id);
            assert!(clip.sha256.chars().all(|ch| ch.is_ascii_hexdigit()));
            assert!(
                ["CC0", "Public domain"].contains(&clip.licence.as_str()),
                "{}",
                clip.id
            );
            assert!(clip.seconds > 5.0 && clip.seconds <= 30.0);
        }
        assert!(find("speech").is_some() && find("nope").is_none());
    }

    #[test]
    fn wav_round_trip() {
        let frames = vec![[0.0, 0.5], [-0.5, 0.25], [0.1, -0.1]];
        let (back, rate) = read_wav(&wav_stereo(&frames, 48000)).unwrap();
        assert_eq!(rate, 48000);
        assert_eq!(back.len(), 3);
        assert!((back[1][0] + 0.5).abs() < 1e-3 && (back[0][1] - 0.5).abs() < 1e-3);
        assert!(read_wav(b"nonsense").is_err());
    }

    #[test]
    fn mono_wav_is_duplicated() {
        let mono = crate::render::wav(&[0.25, -0.25], 48000); // stereo with equal channels
        let (f, _) = read_wav(&mono).unwrap();
        assert_eq!(f[0][0], f[0][1]);
    }

    #[test]
    fn cut_levels_and_fades() {
        let rate = 1000;
        let frames: Vec<[f32; 2]> = (0..10_000)
            .map(|i| {
                let v = if i % 2 == 0 { 0.05 } else { -0.05 };
                [v, v]
            })
            .collect();
        let out = cut(&frames, rate, 2.0, 4.0, -20.0);
        assert_eq!(out.len(), 4000);
        assert_eq!(out[0], [0.0, 0.0]); // faded in
        let mid = out[2000][0].abs() as f64;
        assert!(
            (20.0 * mid.log10() + 20.0).abs() < 0.5,
            "levelled to -20 dB, got {mid}"
        );
        // A loud clip is turned down, not clipped.
        let loud: Vec<[f32; 2]> = (0..4000)
            .map(|i| if i % 2 == 0 { [0.9, 0.9] } else { [-0.9, -0.9] })
            .collect();
        assert!(cut(&loud, rate, 0.0, 4.0, 0.0)
            .iter()
            .all(|f| f[0].abs() <= 0.951));
    }
}
