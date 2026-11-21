//! Updates to Ubuntu Ostrich itself: the latest GitHub release against the version installed.
//!
//! Offered in the Store's Updates tab and the daily notification. Updating runs `ostrich update`
//! pinned to that release's tag in a terminal (it asks for the password and prints what it does).
//! Only plain releases (`v0.5.0`) count: a tag with a suffix is not offered.

use crate::github::{latest_release, parse_repo};

/// Where the releases are published.
pub const SLUG: &str = "thehamandbread/ubuntu-ostrich";

/// The id of this entry in the Store's list of updates (the other ids are Flatpak apps and
/// `github:owner/name`).
pub const UPDATE_ID: &str = "ostrich";

/// "v0.5.0" or "0.5.0" → [0, 5, 0]; None for anything but dotted numbers (so a tag is safe to put
/// in a command line once it parses).
pub fn parse_version(s: &str) -> Option<Vec<u32>> {
    let s = s.strip_prefix('v').unwrap_or(s);
    if s.is_empty() {
        return None;
    }
    s.split('.').map(|p| p.parse::<u32>().ok()).collect()
}

/// Is `tag` a plain release newer than `installed`? ("0.4.0", "v0.5.0" → true; equal, older or
/// unparsable → false.)
pub fn newer(installed: &str, tag: &str) -> bool {
    match (parse_version(installed), parse_version(tag)) {
        (Some(have), Some(latest)) => latest > have,
        _ => false,
    }
}

/// The tag of a newer release than `installed`, if there is one. Asks GitHub (network); None when
/// up to date, when there is no release, or when it can't be reached this time.
pub fn available(installed: &str) -> Option<String> {
    let repo = parse_repo(SLUG)?;
    let tag = latest_release(&repo).ok()??.tag;
    newer(installed, &tag).then_some(tag)
}

/// The shell script that runs the update for `tag` and keeps the terminal open to read the result.
/// `tag` must be a parsed version (digits and dots, maybe a leading v): it goes into the script.
pub fn update_script(tag: &str) -> Option<String> {
    parse_version(tag)?;
    Some(format!(
        "REPO_REF={tag} \"$HOME/.local/bin/ostrich\" update; status=$?; echo; \
         if [ $status -eq 0 ]; then echo 'Updated. Log out and back in to finish.'; \
         else echo 'The update did not finish: see above.'; fi; \
         read -r -p 'Press Enter to close. ' _"
    ))
}

/// The command that opens a terminal running `script`: the first of the usual terminals that
/// `exists`. `xdg-terminal-exec` is Ubuntu's own way to start the user's default terminal.
pub fn terminal_command(exists: impl Fn(&str) -> bool, script: &str) -> Option<Vec<String>> {
    let sh = |program: &str, flags: &[&str]| -> Vec<String> {
        std::iter::once(program)
            .chain(flags.iter().copied())
            .chain(["bash", "-c", script])
            .map(String::from)
            .collect()
    };
    [
        ("xdg-terminal-exec", &[][..]),
        ("ptyxis", &["--"][..]),
        ("ghostty", &["-e"][..]),
        ("gnome-terminal", &["--"][..]),
        ("kgx", &["-e"][..]),
        ("x-terminal-emulator", &["-e"][..]),
    ]
    .into_iter()
    .find(|(program, _)| exists(program))
    .map(|(program, flags)| sh(program, flags))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_parse_and_compare() {
        assert_eq!(parse_version("v0.5.0"), Some(vec![0, 5, 0]));
        assert_eq!(parse_version("0.10.2"), Some(vec![0, 10, 2]));
        for bad in [
            "",
            "v",
            "0.5.0-rc1",
            "main",
            "0..1",
            "1.2.x",
            "v0.5; rm -rf ~",
        ] {
            assert_eq!(parse_version(bad), None, "{bad:?}");
        }
        assert!(newer("0.4.0", "v0.5.0"));
        assert!(newer("0.9.0", "v0.10.0"), "numbers, not text");
        assert!(newer("0.4.0", "0.4.1"));
        assert!(!newer("0.5.0", "v0.5.0"));
        assert!(!newer("0.5.0", "v0.4.9"));
        assert!(
            !newer("0.4.0", "v0.5.0-rc1"),
            "a pre-release is not offered"
        );
        assert!(
            !newer("dev", "v0.5.0"),
            "an unknown installed version offers nothing"
        );
    }

    #[test]
    fn the_update_script_is_pinned_and_safe() {
        let s = update_script("v0.5.0").unwrap();
        assert!(s.starts_with("REPO_REF=v0.5.0 \"$HOME/.local/bin/ostrich\" update"));
        assert!(s.contains("Press Enter to close"));
        assert_eq!(update_script("v0.5.0; rm -rf ~"), None);
        assert_eq!(update_script("main"), None);
    }

    #[test]
    fn the_first_terminal_that_exists_runs_it() {
        let has = |names: &'static [&'static str]| move |p: &str| names.contains(&p);
        let cmd = terminal_command(has(&["ghostty", "x-terminal-emulator"]), "echo hi").unwrap();
        assert_eq!(cmd, ["ghostty", "-e", "bash", "-c", "echo hi"]);
        let cmd = terminal_command(has(&["xdg-terminal-exec", "ghostty"]), "echo hi").unwrap();
        assert_eq!(cmd, ["xdg-terminal-exec", "bash", "-c", "echo hi"]);
        let cmd = terminal_command(has(&["ptyxis"]), "echo hi").unwrap();
        assert_eq!(cmd[..2], ["ptyxis", "--"]);
        assert_eq!(terminal_command(has(&[]), "echo hi"), None);
    }
}
