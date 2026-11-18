//! ostrich-system-helper: the privileged one-shot helper (DESIGN.md: system-helper).
//!
//!   touchscreen status               on | off | none   (no root needed)
//!   touchscreen off [--persist]      root (pkexec): unbind; --persist keeps it off across boots
//!   touchscreen on                   root (pkexec): rebind what was unbound, drop the rule
//!   power status                     current values of the knobs we manage (no root needed)
//!   power apply saver|balanced|performance    root: turbo, PCIe ASPM, audio power save
//!   graphics status                  integrated | hybrid | discrete | none (no root needed)
//!   graphics set integrated|hybrid|discrete   root: prime-select (takes effect after log-out)
//!
//! It accepts only these exact commands: no paths, no free-form arguments, since it runs as root
//! through polkit.

mod power;
mod touchscreen;

use std::process::ExitCode;

fn is_root() -> bool {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("Uid:"))
                .map(|l| l.split_whitespace().nth(2) == Some("0"))
        })
        .unwrap_or(false)
}

/// prime-select's names → ours.
fn graphics_status() -> &'static str {
    let out = std::process::Command::new("prime-select")
        .arg("query")
        .output();
    match out
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .as_deref()
    {
        Ok("intel") => "integrated",
        Ok("on-demand") => "hybrid",
        Ok("nvidia") => "discrete",
        _ => "none",
    }
}

fn graphics_set(mode: &str) -> Result<String, String> {
    if graphics_status() == "none" {
        return Err(
            "graphics modes need prime-select (an NVIDIA hybrid laptop with nvidia-prime)".into(),
        );
    }
    let prime = match mode {
        "integrated" => "intel",
        "hybrid" => "on-demand",
        _ => "nvidia",
    };
    let ok = std::process::Command::new("prime-select")
        .arg(prime)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if ok {
        Ok(format!(
            "graphics mode set to {mode}; log out and back in to apply"
        ))
    } else {
        Err(format!("prime-select {prime} failed"))
    }
}

fn usage() -> ExitCode {
    eprintln!("usage: ostrich-system-helper touchscreen status|on|off [--persist] | power status|apply MODE | graphics status|set MODE");
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let a: Vec<&str> = args.iter().map(String::as_str).collect();
    let paths = touchscreen::Paths::default();
    let result = match a.as_slice() {
        ["touchscreen", "status"] => {
            println!("{}", touchscreen::status(&paths));
            return ExitCode::SUCCESS;
        }
        ["touchscreen", cmd @ ("on" | "off"), rest @ ..] => {
            if !is_root() {
                eprintln!("touchscreen {cmd}: needs root (run through pkexec)");
                return ExitCode::from(1);
            }
            match (*cmd, rest) {
                ("off", []) => touchscreen::off(&paths, false),
                ("off", ["--persist"]) => touchscreen::off(&paths, true),
                ("on", []) => touchscreen::on(&paths),
                _ => return usage(),
            }
        }
        ["power", "status"] => {
            for line in power::status(&power::Paths::default()) {
                println!("{line}");
            }
            return ExitCode::SUCCESS;
        }
        ["power", "apply", mode] => {
            let Some(m) = power::Mode::parse(mode) else {
                return usage();
            };
            if !is_root() {
                eprintln!("power apply: needs root (run through pkexec)");
                return ExitCode::from(1);
            }
            for line in power::apply(&power::Paths::default(), m) {
                println!("{line}");
            }
            return ExitCode::SUCCESS;
        }
        ["graphics", "status"] => {
            println!("{}", graphics_status());
            return ExitCode::SUCCESS;
        }
        ["graphics", "set", mode @ ("integrated" | "hybrid" | "discrete")] => {
            if !is_root() {
                eprintln!("graphics set: needs root (run through pkexec)");
                return ExitCode::from(1);
            }
            graphics_set(mode)
        }
        _ => return usage(),
    };
    match result {
        Ok(msg) => {
            println!("{msg}");
            if a.contains(&"--persist") || a.get(1) == Some(&"on") {
                // pick up the rule change (written or removed)
                let _ = std::process::Command::new("udevadm")
                    .args(["control", "--reload"])
                    .status();
            }
            if a.get(1) == Some(&"on") {
                // Wait for the rebound touchscreen's input node: the tile asks `status` straight after,
                // and before udev had listed it again the answer was "none", which hid the tile.
                let _ = std::process::Command::new("udevadm")
                    .args(["settle", "--timeout=5"])
                    .status();
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}
