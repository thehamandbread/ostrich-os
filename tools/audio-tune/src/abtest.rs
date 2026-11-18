//! "Which sounds better, A or B?" A binary search per band group (low, mid, high).
//!
//! Each group starts at the base gain with a step of `start_step` dB. Every comparison offers
//! base+step (A) against base-step (B); the pick moves the base half a step that way and halves the
//! step. After `rounds` comparisons per group it moves to the next group. With rounds = 4 and a
//! 6 dB start step that's 12 comparisons in total, ending within about 0.4 dB of the preference.

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Choice {
    A,
    B,
    Same,
}

#[derive(Clone, Debug)]
pub struct AbTest {
    pub gains: [f64; 3], // low, mid, high
    group: usize,
    round: usize,
    step: f64,
    start_step: f64,
    rounds: usize,
    max_db: f64,
}

impl AbTest {
    pub fn new(start: [f64; 3], start_step: f64, rounds: usize, max_db: f64) -> Self {
        AbTest {
            gains: start,
            group: 0,
            round: 0,
            step: start_step,
            start_step,
            rounds,
            max_db,
        }
    }

    pub fn done(&self) -> bool {
        self.group >= 3
    }

    pub fn total_comparisons(&self) -> usize {
        3 * self.rounds
    }

    pub fn comparisons_made(&self) -> usize {
        self.group.min(3) * self.rounds + if self.done() { 0 } else { self.round }
    }

    /// The two gain sets to play now: (A, B). None when finished.
    pub fn pair(&self) -> Option<([f64; 3], [f64; 3])> {
        if self.done() {
            return None;
        }
        let mut a = self.gains;
        let mut b = self.gains;
        a[self.group] = (a[self.group] + self.step).clamp(-self.max_db, self.max_db);
        b[self.group] = (b[self.group] - self.step).clamp(-self.max_db, self.max_db);
        Some((a, b))
    }

    /// Records the listener's answer and advances.
    pub fn answer(&mut self, c: Choice) {
        if self.done() {
            return;
        }
        let g = self.group;
        let delta = match c {
            Choice::A => self.step / 2.0,
            Choice::B => -self.step / 2.0,
            Choice::Same => 0.0,
        };
        self.gains[g] = (self.gains[g] + delta).clamp(-self.max_db, self.max_db);
        self.step /= 2.0;
        self.round += 1;
        if self.round >= self.rounds {
            self.group += 1;
            self.round = 0;
            self.step = self.start_step;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A listener who prefers whichever option is closer to their ideal gains.
    fn converge(ideal: [f64; 3]) -> [f64; 3] {
        let mut t = AbTest::new([0.0; 3], 6.0, 4, 9.0);
        while let Some((a, b)) = t.pair() {
            let dist = |x: [f64; 3]| {
                x.iter()
                    .zip(&ideal)
                    .map(|(p, q)| (p - q).powi(2))
                    .sum::<f64>()
            };
            t.answer(if dist(a) < dist(b) {
                Choice::A
            } else if dist(b) < dist(a) {
                Choice::B
            } else {
                Choice::Same
            });
        }
        t.gains
    }

    #[test]
    fn finds_a_listeners_preference_in_twelve_steps() {
        for ideal in [[3.0, -1.5, 2.0], [-4.0, 0.0, 5.0], [0.0, 0.0, 0.0]] {
            let got = converge(ideal);
            for i in 0..3 {
                assert!(
                    (got[i] - ideal[i]).abs() <= 0.8,
                    "ideal {ideal:?} got {got:?}"
                );
            }
        }
    }

    #[test]
    fn counts_and_finishes() {
        let mut t = AbTest::new([0.0; 3], 6.0, 4, 9.0);
        assert_eq!(t.total_comparisons(), 12);
        for _ in 0..12 {
            assert!(!t.done());
            t.answer(Choice::Same);
        }
        assert!(t.done() && t.pair().is_none());
        assert_eq!(t.gains, [0.0; 3]);
    }

    #[test]
    fn gains_stay_within_limits() {
        let mut t = AbTest::new([8.0, 0.0, 0.0], 6.0, 4, 9.0);
        let (a, _) = t.pair().unwrap();
        assert_eq!(a[0], 9.0);
        t.answer(Choice::A);
        assert!(t.gains[0] <= 9.0);
    }
}
