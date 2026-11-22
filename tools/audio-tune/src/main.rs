//! ostrich speakers: speaker tuning with PipeWire's own filter-chain (Ostrich OS).
//!
//!   ostrich speakers list                         presets
//!   ostrich speakers show <preset>                response at a few frequencies, and the preamp
//!   ostrich speakers apply <preset> [--target SINK] [--dry-run]
//!   ostrich speakers off [--dry-run]
//!
//!   ostrich speakers current                     the applied preset, or "off"
//!   ostrich speakers save-custom <low> <mid> <high>    the listening test's result, as preset \"custom\"
//!   ostrich speakers render <preset> <out.wav> [--clip ID]   a clip (pink noise without one) through a preset
//!   ostrich speakers clips                       the music and speech clips, and whether each is installed
//!   ostrich speakers clip-cut <id> <decoded.wav> keep the clip's excerpt (the installer runs this)
//!
//! `apply` writes ~/.config/pipewire/pipewire.conf.d/90-ostrich-os-speakers.conf and
//! restarts PipeWire so it takes effect; `off` removes it. The GUI and the A/B listening test sit on
//! the same library (see abtest.rs).

use audio_tune::{clips, eq, pipewire, render, system};

use std::process::ExitCode;
use std::{env, fs};

fn restart_pipewire(dry_run: bool) {
    if dry_run {
        println!(
            "would restart PipeWire (systemctl --user restart pipewire pipewire-pulse wireplumber)"
        );
    } else {
        system::restart_pipewire();
    }
}

fn usage() -> ExitCode {
    eprintln!("usage: ostrich speakers list | current | show <preset> | apply <preset> [--target SINK] [--dry-run] | off [--dry-run]\n       ostrich speakers save-custom <low> <mid> <high> | render <preset> <out.wav> [--clip ID]\n       ostrich speakers clips | clip-cut <id> <decoded.wav>");
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let mut args: Vec<String> = env::args().skip(1).collect();
    let dry_run = args.iter().any(|a| a == "--dry-run");
    args.retain(|a| a != "--dry-run");
    let mut clip = None;
    if let Some(i) = args.iter().position(|a| a == "--clip") {
        if i + 1 >= args.len() {
            return usage();
        }
        clip = Some(args.remove(i + 1));
        args.remove(i);
    }
    let mut target = None;
    if let Some(i) = args.iter().position(|a| a == "--target") {
        if i + 1 >= args.len() {
            return usage();
        }
        target = Some(args.remove(i + 1));
        args.remove(i);
    }
    match args
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        ["list"] => {
            for p in eq::PRESETS {
                println!("{p}");
            }
            if system::load_custom().is_some() {
                println!("custom");
            }
        }
        ["show", name] => {
            let Some(e) = system::preset(name) else {
                eprintln!("ostrich speakers: no preset {name}");
                return ExitCode::from(2);
            };
            println!("preset {} (preamp {:.1} dB)", e.name, e.preamp_db());
            for f in [40.0, 100.0, 250.0, 1000.0, 2500.0, 6000.0, 12000.0] {
                println!("{:>6} Hz  {:+5.1} dB", f, e.response_db(f, 48000.0));
            }
        }
        ["apply", name] => {
            let Some(e) = system::preset(name) else {
                eprintln!("ostrich speakers: no preset {name}");
                return ExitCode::from(2);
            };
            let Some(sink) = target.or_else(system::speaker_sink) else {
                eprintln!("ostrich speakers: the default output is not the built-in speakers (Bluetooth, HDMI and USB are left alone), or there is none; switch to the speakers, or pass --target <sink name> (see `wpctl status`)");
                return ExitCode::FAILURE;
            };
            let path = system::conf_path();
            let text = pipewire::filter_chain(&e, &sink);
            if dry_run {
                println!("would write {}:\n{text}", path.display());
            } else {
                if let Some(dir) = path.parent() {
                    if let Err(err) = fs::create_dir_all(dir) {
                        eprintln!("ostrich speakers: {}: {err}", dir.display());
                        return ExitCode::FAILURE;
                    }
                }
                if let Err(err) = fs::write(&path, text) {
                    eprintln!("ostrich speakers: {}: {err}", path.display());
                    return ExitCode::FAILURE;
                }
                println!(
                    "wrote {} (preset {}, speakers: {sink})",
                    path.display(),
                    e.name
                );
            }
            restart_pipewire(dry_run);
        }
        ["save-custom", low, mid, high] => {
            let Some(g) = system::parse_custom(&format!("{low} {mid} {high}")) else {
                eprintln!("ostrich speakers: gains must be numbers within ±24 dB");
                return ExitCode::from(2);
            };
            if let Err(e) = system::save_custom(g) {
                eprintln!("ostrich speakers: {e}");
                return ExitCode::FAILURE;
            }
            println!("saved custom preset {g:?}; apply it with: ostrich speakers apply custom");
        }
        ["current"] => println!(
            "{}",
            system::current_preset().unwrap_or_else(|| "off".into())
        ),
        ["clips"] => {
            for c in clips::all() {
                let installed = if clips::path(&c.id).is_some() {
                    "yes"
                } else {
                    "no"
                };
                println!(
                    "{}\t{}\t{}\t{installed}\t{}\t{}",
                    c.id, c.name, c.kind, c.credit, c.licence
                );
            }
        }
        ["clip-cut", id, decoded] => {
            let Some(c) = clips::find(id) else {
                eprintln!("ostrich speakers: no clip {id}");
                return ExitCode::from(2);
            };
            let (frames, rate) = match clips::read_file(std::path::Path::new(decoded)) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("ostrich speakers: {e}");
                    return ExitCode::FAILURE;
                }
            };
            let out = clips::cut(&frames, rate, c.start, c.seconds, -20.0);
            let path = clips::dir().join(format!("{id}.wav"));
            if let Err(e) = fs::create_dir_all(clips::dir())
                .and_then(|_| fs::write(&path, clips::wav_stereo(&out, rate)))
            {
                eprintln!("ostrich speakers: {}: {e}", path.display());
                return ExitCode::FAILURE;
            }
            println!("wrote {}", path.display());
        }
        ["render", name, out] => {
            let Some(e) = system::preset(name) else {
                eprintln!("ostrich speakers: no preset {name}");
                return ExitCode::from(2);
            };
            // A music or speech clip if it's installed, else pink noise.
            let music = clip
                .as_deref()
                .and_then(clips::path)
                .and_then(|p| clips::read_file(&p).ok());
            let wav = match music {
                Some((frames, rate)) => {
                    clips::wav_stereo(&render::render_stereo(&e, &frames, rate), rate)
                }
                None => {
                    let noise = render::pink_noise(4.0, render::RATE, 1);
                    render::wav(&render::render(&e, &noise, render::RATE), render::RATE)
                }
            };
            if let Err(err) = fs::write(out, wav) {
                eprintln!("ostrich speakers: {out}: {err}");
                return ExitCode::FAILURE;
            }
        }
        ["off"] => {
            let path = system::conf_path();
            if !path.exists() {
                println!("speaker tuning is already off");
                return ExitCode::SUCCESS;
            }
            if dry_run {
                println!("would remove {}", path.display());
            } else if let Err(err) = fs::remove_file(&path) {
                eprintln!("ostrich speakers: {}: {err}", path.display());
                return ExitCode::FAILURE;
            }
            restart_pipewire(dry_run);
        }
        _ => return usage(),
    }
    ExitCode::SUCCESS
}
