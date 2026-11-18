//! audio-tune library: EQ maths and presets, the PipeWire filter-chain writer, the A/B listening
//! test, and its clips (music and speech, or pink noise). Shared by the CLI (main.rs) and the setup wizard.

pub mod abtest;
pub mod clips;
pub mod eq;
pub mod pipewire;
pub mod render;
pub mod system;
