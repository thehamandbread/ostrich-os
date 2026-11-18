//! ostrich: the one command for Ubuntu Ostrich.
//!
//!   ostrich <command> [arguments]       ostrich help   lists the commands
//!
//! Each command is a separate program in ~/.local/libexec/ubuntu-ostrich/ (OSTRICH_LIBEXEC
//! overrides it), so this front end stays tiny and the GTK/WebKit tools load only when used.

mod config;
mod env;

use std::env as stdenv;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, ExitCode};

const VERSION: &str = env!("CARGO_PKG_VERSION");

/// (command, program, one-line help, example)
const COMMANDS: [(&str, &str, &str, &str); 6] = [
    (
        "store",
        "ostrich-store",
        "Find, install, update and remove apps. Paste a GitHub link to install that project; --gui opens the window.",
        "ostrich store spotify",
    ),
    (
        "theme",
        "ostrich-theme",
        "Accent colours picked from your wallpaper.",
        "ostrich theme apply 2",
    ),
    (
        "speakers",
        "ostrich-speakers",
        "Tune the laptop speakers: presets, or tune by ear in `ostrich setup --step speakers`.",
        "ostrich speakers apply voice",
    ),
    (
        "drawer",
        "ostrich-drawer",
        "Ostrich Drawer: your web apps in the top bar (Super+Alt+D; --list, --recommended, --add).",
        "ostrich drawer --add whatsapp",
    ),
    (
        "settings",
        "ostrich-setup",
        "Ostrich Settings: every Ubuntu Ostrich setting, a page each.",
        "ostrich settings --step dock",
    ),
    (
        "setup",
        "ostrich-setup",
        "The same as settings; --tour runs the first-login tour again.",
        "ostrich setup --tour",
    ),
];

fn libexec() -> PathBuf {
    stdenv::var_os("OSTRICH_LIBEXEC")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(stdenv::var_os("HOME").unwrap_or_default())
                .join(".local/libexec/ubuntu-ostrich")
        })
}

fn data_home() -> PathBuf {
    stdenv::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(stdenv::var_os("HOME").unwrap_or_default()).join(".local/share")
        })
}

fn state_home() -> PathBuf {
    stdenv::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(stdenv::var_os("HOME").unwrap_or_default()).join(".local/state")
        })
}

/// The installer that `update` and `uninstall` run: the copy the one-line install keeps, else the
/// checkout it was installed from (install.sh records its path).
fn installer() -> Option<PathBuf> {
    let fetched = data_home().join("ubuntu-ostrich/src/install.sh");
    if fetched.exists() {
        return Some(fetched);
    }
    let recorded = std::fs::read_to_string(state_home().join("ubuntu-ostrich/source")).ok()?;
    let checkout = PathBuf::from(recorded.trim()).join("install.sh");
    checkout.exists().then_some(checkout)
}

fn help() -> String {
    let mut s =
        format!("Ubuntu Ostrich {VERSION}\n\nUsage: ostrich <command> [arguments]\n\nCommands:\n");
    for (name, _, text, example) in COMMANDS {
        s.push_str(&format!("  {name:<9} {text}\n            e.g. {example}\n"));
    }
    s.push_str(
        "  config    Every setting from the terminal, and a settings file for your dotfiles (`ostrich config help`).\n  \
         workspace Saved workspaces: open one named, close it where you left off (`ostrich workspace help`; also `env`).\n  \
         update    Get the latest Ubuntu Ostrich and apply it (safe to run any time).\n  \
         uninstall Put your computer back the way it was before Ubuntu Ostrich.\n  \
         version   Show the version.\n  \
         help      Show this.\n\n\
         Add --help after a command for its own options, e.g. `ostrich store --help`.\n",
    );
    s
}

/// What to do for a command line; separated from running it so it can be tested.
#[derive(Debug, PartialEq)]
enum Action {
    Print(String),
    Run(PathBuf, Vec<String>),
    Fail(String),
    Env(Vec<String>),
    Config(Vec<String>),
}

fn decide(args: &[String]) -> Action {
    let Some(cmd) = args.first() else {
        return Action::Print(help());
    };
    let rest = args[1..].to_vec();
    match cmd.as_str() {
        "help" | "-h" | "--help" => Action::Print(help()),
        "version" | "-V" | "--version" => Action::Print(format!("Ubuntu Ostrich {VERSION}\n")),
        "env" | "workspace" => Action::Env(rest),
        "config" => Action::Config(rest),
        "update" | "uninstall" => match installer() {
            Some(installer) => {
                let mut a = vec![installer.to_string_lossy().into_owned(), format!("--{cmd}")];
                a.extend(rest);
                Action::Run(PathBuf::from("bash"), a)
            }
            None => Action::Fail(
                "ostrich: can't find the installer it was installed with (the downloaded copy, or \
                 the checkout it was run from, if that has moved). Run the install command again:\n  \
                 wget -qO- https://raw.githubusercontent.com/thehamandbread/ubuntu-ostrich/main/install.sh | bash\n"
                    .into(),
            ),
        },
        _ => match COMMANDS.iter().find(|c| c.0 == cmd) {
            Some((_, program, _, _)) => Action::Run(libexec().join(program), rest),
            None => {
                let near = COMMANDS
                    .iter()
                    .map(|c| c.0)
                    .find(|c| c.starts_with(cmd.get(..2).unwrap_or(cmd)));
                let hint = near
                    .map(|n| format!(" Did you mean `ostrich {n}`?"))
                    .unwrap_or_default();
                Action::Fail(format!(
                    "ostrich: there's no command called `{cmd}`.{hint} See `ostrich help`.\n"
                ))
            }
        },
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = stdenv::args().skip(1).collect();
    match decide(&args) {
        Action::Print(s) => {
            print!("{s}");
            ExitCode::SUCCESS
        }
        Action::Fail(s) => {
            eprint!("{s}");
            ExitCode::from(2)
        }
        Action::Env(a) => match env::run(&a) {
            Ok(out) => {
                print!("{out}");
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("ostrich env: {e}");
                ExitCode::FAILURE
            }
        },
        Action::Config(a) => match config::run(&a) {
            Ok(out) => {
                print!("{out}");
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("ostrich config: {e}");
                ExitCode::FAILURE
            }
        },
        Action::Run(program, a) => {
            if program.is_absolute() && !program.exists() {
                eprintln!(
                    "ostrich: {} isn't installed. `ostrich update` puts it back.",
                    program.display()
                );
                return ExitCode::FAILURE;
            }
            // exec: the tool takes over this process (its exit code, signals, terminal).
            let err = Command::new(&program).args(&a).exec();
            eprintln!("ostrich: could not start {}: {err}", program.display());
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn no_arguments_and_help_print_every_command() {
        for args in [a(&[]), a(&["help"]), a(&["--help"])] {
            let Action::Print(s) = decide(&args) else {
                panic!("expected help")
            };
            for (name, ..) in COMMANDS {
                assert!(s.contains(&format!("  {name} ")), "{name} missing");
            }
            assert!(s.contains("update") && s.contains("version") && s.contains("uninstall"));
        }
    }

    #[test]
    fn workspace_is_env_by_its_new_name() {
        for cmd in ["env", "workspace"] {
            let Action::Env(rest) = decide(&a(&[cmd, "open", "school"])) else {
                panic!("{cmd} should be the saved-workspaces command")
            };
            assert_eq!(rest, a(&["open", "school"]));
        }
    }

    #[test]
    fn commands_run_their_program_with_the_rest_of_the_arguments() {
        stdenv::set_var("OSTRICH_LIBEXEC", "/opt/x");
        assert_eq!(
            decide(&a(&["store", "spotify", "--x"])),
            Action::Run(
                PathBuf::from("/opt/x/ostrich-store"),
                a(&["spotify", "--x"])
            )
        );
        assert_eq!(
            decide(&a(&["setup", "--step", "dock"])),
            Action::Run(
                PathBuf::from("/opt/x/ostrich-setup"),
                a(&["--step", "dock"])
            )
        );
        assert_eq!(
            decide(&a(&["settings"])),
            Action::Run(PathBuf::from("/opt/x/ostrich-setup"), a(&[]))
        );
    }

    #[test]
    fn update_and_uninstall_find_the_downloaded_copy_or_the_recorded_checkout() {
        let root = std::env::temp_dir().join(format!("ostrich-test-{}", std::process::id()));
        let (data, state, checkout) =
            (root.join("data"), root.join("state"), root.join("checkout"));
        for d in [&data, &state.join("ubuntu-ostrich"), &checkout] {
            std::fs::create_dir_all(d).unwrap();
        }
        stdenv::set_var("XDG_DATA_HOME", &data);
        stdenv::set_var("XDG_STATE_HOME", &state);
        assert!(matches!(decide(&a(&["uninstall"])), Action::Fail(_)));
        // Installed from a checkout: install.sh recorded where.
        std::fs::write(checkout.join("install.sh"), "").unwrap();
        std::fs::write(
            state.join("ubuntu-ostrich/source"),
            format!("{}\n", checkout.display()),
        )
        .unwrap();
        assert_eq!(
            decide(&a(&["uninstall", "--yes"])),
            Action::Run(
                PathBuf::from("bash"),
                a(&[
                    &checkout.join("install.sh").to_string_lossy(),
                    "--uninstall",
                    "--yes"
                ])
            )
        );
        // The one-line install's copy comes first.
        std::fs::create_dir_all(data.join("ubuntu-ostrich/src")).unwrap();
        std::fs::write(data.join("ubuntu-ostrich/src/install.sh"), "").unwrap();
        let Action::Run(_, args) = decide(&a(&["update"])) else {
            panic!()
        };
        assert!(
            args[0].ends_with("ubuntu-ostrich/src/install.sh"),
            "{args:?}"
        );
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn unknown_commands_suggest_a_close_one() {
        let Action::Fail(s) = decide(&a(&["sto"])) else {
            panic!()
        };
        assert!(s.contains("ostrich store"), "{s}");
        let Action::Fail(s) = decide(&a(&["xyz"])) else {
            panic!()
        };
        assert!(s.contains("ostrich help") && !s.contains("Did you mean"));
        // A multi-byte first letter must not panic.
        assert!(matches!(decide(&a(&["日本"])), Action::Fail(_)));
    }

    #[test]
    fn version() {
        assert_eq!(
            decide(&a(&["--version"])),
            Action::Print(format!("Ubuntu Ostrich {VERSION}\n"))
        );
    }
}
