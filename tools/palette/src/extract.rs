//! Accent extraction: k-means in OKLab over a downsampled wallpaper, then usable accents.

use crate::color::{contrast, hue_distance, Lab, Rgb};

/// Deterministic xorshift, so the same wallpaper always gives the same palette.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn unit(&mut self) -> f32 {
        (self.next() >> 40) as f32 / (1u64 << 24) as f32
    }
}

#[derive(Clone, Debug)]
pub struct Cluster {
    pub centre: Lab,
    pub count: usize,
}

/// k-means with k-means++ seeding. Returns clusters sorted by size, largest first.
pub fn kmeans(samples: &[Lab], k: usize, iterations: usize) -> Vec<Cluster> {
    if samples.is_empty() || k == 0 {
        return Vec::new();
    }
    let k = k.min(samples.len());
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
    let mut centres = vec![samples[(rng.next() as usize) % samples.len()]];
    while centres.len() < k {
        let d: Vec<f32> = samples
            .iter()
            .map(|s| centres.iter().map(|c| s.dist2(*c)).fold(f32::MAX, f32::min))
            .collect();
        let total: f32 = d.iter().sum();
        if total <= 0.0 {
            break;
        }
        let mut target = rng.unit() * total;
        let mut pick = samples.len() - 1;
        for (i, di) in d.iter().enumerate() {
            target -= di;
            if target <= 0.0 {
                pick = i;
                break;
            }
        }
        centres.push(samples[pick]);
    }

    let mut assign = vec![0usize; samples.len()];
    for _ in 0..iterations {
        let mut changed = false;
        for (i, s) in samples.iter().enumerate() {
            let best = (0..centres.len())
                .min_by(|&a, &b| s.dist2(centres[a]).total_cmp(&s.dist2(centres[b])))
                .unwrap();
            if assign[i] != best {
                assign[i] = best;
                changed = true;
            }
        }
        let mut sums = vec![(0.0f32, 0.0f32, 0.0f32, 0usize); centres.len()];
        for (s, &c) in samples.iter().zip(&assign) {
            let e = &mut sums[c];
            e.0 += s.l;
            e.1 += s.a;
            e.2 += s.b;
            e.3 += 1;
        }
        for (c, (l, a, b, n)) in centres.iter_mut().zip(&sums) {
            if *n > 0 {
                *c = Lab {
                    l: l / *n as f32,
                    a: a / *n as f32,
                    b: b / *n as f32,
                };
            }
        }
        if !changed {
            break;
        }
    }
    let mut counts = vec![0usize; centres.len()];
    for &c in &assign {
        counts[c] += 1;
    }
    let mut clusters: Vec<Cluster> = centres
        .into_iter()
        .zip(counts)
        .map(|(centre, count)| Cluster { centre, count })
        .collect();
    clusters.sort_by(|a, b| b.count.cmp(&a.count));
    clusters
}

/// Shifts lightness until white text on the colour reaches `min_contrast`, keeping hue and chroma.
pub fn usable_accent(c: Lab, min_contrast: f32) -> Rgb {
    let white = Rgb {
        r: 1.0,
        g: 1.0,
        b: 1.0,
    };
    let mut lab = Lab {
        l: c.l.clamp(0.35, 0.75),
        ..c
    };
    for _ in 0..40 {
        let rgb = lab.to_rgb();
        if contrast(rgb, white) >= min_contrast {
            return rgb;
        }
        lab.l -= 0.01;
    }
    lab.to_rgb()
}

/// Accent candidates from clusters: colourful enough, not near-black/white, distinct in hue.
/// Ordered by how much of the picture they cover, weighted by colourfulness.
pub fn accents(clusters: &[Cluster], max: usize) -> Vec<Rgb> {
    let mut scored: Vec<(f32, Lab)> = clusters
        .iter()
        .filter(|c| c.centre.chroma() >= 0.04 && c.centre.l > 0.2 && c.centre.l < 0.95)
        .map(|c| (c.count as f32 * c.centre.chroma().sqrt(), c.centre))
        .collect();
    scored.sort_by(|a, b| b.0.total_cmp(&a.0));
    let mut picked: Vec<Lab> = Vec::new();
    for (_, lab) in scored {
        if picked
            .iter()
            .all(|p| hue_distance(p.hue(), lab.hue()) >= 25.0)
        {
            picked.push(lab);
        }
        if picked.len() == max {
            break;
        }
    }
    picked.into_iter().map(|l| usable_accent(l, 3.0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lab(hex: &str) -> Lab {
        Rgb::from_hex(hex).unwrap().to_lab()
    }

    #[test]
    fn kmeans_separates_two_colours() {
        let mut s = vec![lab("#d02020"); 300];
        s.extend(vec![lab("#2040d0"); 100]);
        let c = kmeans(&s, 2, 10);
        assert_eq!(c.len(), 2);
        assert_eq!(c[0].count, 300);
        assert!(c[0].centre.dist2(lab("#d02020")) < 1e-6);
    }

    #[test]
    fn kmeans_is_deterministic() {
        let s: Vec<Lab> = (0..500)
            .map(|i| lab(&format!("#{:02x}{:02x}80", i % 256, (i * 7) % 256)))
            .collect();
        let a: Vec<_> = kmeans(&s, 6, 15).iter().map(|c| c.count).collect();
        let b: Vec<_> = kmeans(&s, 6, 15).iter().map(|c| c.count).collect();
        assert_eq!(a, b);
    }

    #[test]
    fn accents_skip_greys_and_near_duplicates() {
        let clusters = vec![
            Cluster {
                centre: lab("#808080"),
                count: 1000,
            }, // grey: skipped
            Cluster {
                centre: lab("#c03030"),
                count: 500,
            },
            Cluster {
                centre: lab("#c83a30"),
                count: 400,
            }, // same hue as the red: skipped
            Cluster {
                centre: lab("#3050c0"),
                count: 300,
            },
        ];
        let a = accents(&clusters, 5);
        assert_eq!(a.len(), 2);
    }

    #[test]
    fn usable_accent_reaches_contrast_with_white() {
        let white = Rgb {
            r: 1.0,
            g: 1.0,
            b: 1.0,
        };
        for hex in ["#f8e080", "#80f0ff", "#ffd0e0"] {
            let c = usable_accent(lab(hex), 3.0);
            assert!(contrast(c, white) >= 3.0, "{hex} -> {}", c.hex());
        }
    }
}
