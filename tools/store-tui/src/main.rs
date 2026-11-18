//! ostrich store (the ostrich-store program): a terminal app store over the local Flathub catalogue.
//!
//!   type        search (instant, fuzzy; no network)
//!   ↑/↓ PgUp/PgDn  move          Enter  install, or remove (asks first) if installed
//!   Ctrl+U      update the selected app          Ctrl+R  reload installed apps
//!   paste a GitHub link, Enter   install that project: from Flathub if it's there, else its
//!                                latest release (.flatpak > AppImage > .deb > tarball), checksum-
//!                                verified when published; shows what it will do and asks first.
//!                                Installed already: Enter updates it, Ctrl+D removes it
//!   Esc / Ctrl+C  quit (Esc first cancels a pending removal)
//!
//!   --gui [SEARCH]  open the store window instead (ostrich-store-gtk)
//!
//! While idle it blocks waiting for a key (no polling); it only polls while flatpak runs.

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::{DefaultTerminal, Frame};
use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, ExitCode};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;
use store_core::appstream::{self, App};
use store_core::flatpak::{self, Action, Installed};
use store_core::ghinstall;
use store_core::github::{self, Asset, Kind, Release, Repo};
use store_core::search::Searcher;

const REMOTE: &str = "flathub";
const MAX_RESULTS: usize = 200;

struct Job {
    action: Action,
    id: String,
    child: Child,
    lines: Receiver<String>,
}

/// A GitHub link resolved and waiting for the user to confirm.
enum GhPlan {
    Flathub(String),
    Release {
        repo: Repo,
        release: Release,
        kind: Kind,
        asset: Asset,
    },
    /// An unverified .deb, already downloaded to `dest`, waiting for a second yes.
    Unchecked {
        repo: Repo,
        release: Release,
        kind: Kind,
        asset: Asset,
        dest: PathBuf,
    },
}

fn is_github_link(q: &str) -> bool {
    q.contains("github.com/") || q.trim_start().starts_with("git@github.com:")
}

struct State {
    apps: Vec<App>,
    installed: HashMap<String, Installed>,
    searcher: Searcher,
    query: String,
    results: Vec<usize>,
    list: ListState,
    status: Vec<String>,
    confirm_remove: Option<String>,
    job: Option<Job>,
    github: Option<GhPlan>,
    gh_job: Option<(Receiver<String>, Receiver<GhPlan>)>,
}

impl State {
    fn refresh_results(&mut self) {
        self.results = self.searcher.search(&self.apps, &self.query, MAX_RESULTS);
        self.list.select(if self.results.is_empty() {
            None
        } else {
            Some(0)
        });
    }

    fn selected(&self) -> Option<&App> {
        self.list
            .selected()
            .and_then(|i| self.results.get(i))
            .map(|&i| &self.apps[i])
    }

    fn reload_installed(&mut self) {
        match flatpak::installed() {
            Ok(list) => self.installed = list.into_iter().map(|i| (i.id.clone(), i)).collect(),
            Err(e) => self
                .status
                .push(format!("could not list installed apps: {e}")),
        }
    }

    fn start(&mut self, action: Action, id: String) {
        if self.job.is_some() {
            self.status
                .push("wait for the current job to finish".into());
            return;
        }
        let shown = flatpak::command_line(action, REMOTE, &id).join(" ");
        match flatpak::spawn(action, REMOTE, &id) {
            Ok(mut child) => {
                let (tx, rx) = mpsc::channel();
                for pipe in [
                    child
                        .stdout
                        .take()
                        .map(|p| Box::new(p) as Box<dyn std::io::Read + Send>),
                    child
                        .stderr
                        .take()
                        .map(|p| Box::new(p) as Box<dyn std::io::Read + Send>),
                ]
                .into_iter()
                .flatten()
                {
                    let tx = tx.clone();
                    std::thread::spawn(move || {
                        for line in BufReader::new(pipe).lines().map_while(Result::ok) {
                            // flatpak redraws progress with \r; keep the last state of each line
                            let last = line.rsplit('\r').next().unwrap_or("").trim().to_string();
                            if !last.is_empty() && tx.send(last).is_err() {
                                break;
                            }
                        }
                    });
                }
                self.status = vec![format!("$ {shown}")];
                self.job = Some(Job {
                    action,
                    id,
                    child,
                    lines: rx,
                });
            }
            Err(e) => self.status.push(e),
        }
    }

    fn resolve_github(&mut self) {
        let Some(repo) = github::parse_repo(&self.query) else {
            self.status.push("not a GitHub repository link".into());
            return;
        };
        if let Some(app) = github::flathub_match(&self.apps, &repo) {
            self.status.push(format!(
                "github.com/{} is on Flathub as {} ({}). Enter installs it from Flathub.",
                repo.slug(),
                app.name,
                app.id
            ));
            self.github = Some(GhPlan::Flathub(app.id.clone()));
            return;
        }
        let release = match github::latest_release(&repo) {
            Ok(Some(r)) => r,
            Ok(None) => {
                self.status.push(format!(
                    "github.com/{} has no releases: not an installable app repo",
                    repo.slug()
                ));
                return;
            }
            Err(e) => {
                self.status.push(format!("GitHub: {e}"));
                return;
            }
        };
        let had = ghinstall::Dirs::from_env().and_then(|d| ghinstall::installed_tag(&d, &repo));
        if had.as_deref() == Some(release.tag.as_str()) {
            self.status.push(format!(
                "github.com/{} is up to date ({}). Ctrl+D removes it.",
                repo.slug(),
                release.tag
            ));
            return;
        }
        if let Some(t) = &had {
            self.status
                .push(format!("installed: {t}. Ctrl+D removes it instead."));
        }
        let Some((kind, asset)) =
            github::choose_asset(&release.assets).map(|(k, a)| (k, a.clone()))
        else {
            self.status.push(format!(
                "release {} has no Linux x86_64 app (looked for .flatpak, AppImage, .deb, tarball)",
                release.tag
            ));
            return;
        };
        let how = match kind {
            Kind::Flatpak => "Flatpak bundle, installed for you only",
            Kind::AppImage => "AppImage, kept in your home folder with a launcher",
            Kind::Deb => "Debian package: ITS INSTALL SCRIPTS RUN AS ROOT",
            Kind::Tarball => "tarball, extracted into your home folder with a launcher",
        };
        self.status.push(format!(
            "github.com/{} {}: {} ({:.1} MB), {how}",
            repo.slug(),
            release.tag,
            asset.name,
            asset.size as f64 / 1e6
        ));
        self.status.push(
            "Not reviewed by Flathub or Ubuntu: only install from projects you trust. Enter installs, Esc cancels.".into(),
        );
        self.github = Some(GhPlan::Release {
            repo,
            release,
            kind,
            asset,
        });
    }

    /// Removes an app installed from GitHub, in the background (a .deb asks for a password).
    fn remove_github(&mut self, repo: Repo) {
        let (tx, rx) = mpsc::channel();
        let (_, ask_rx) = mpsc::channel(); // a removal never asks again
        std::thread::spawn(move || {
            let got = ghinstall::Dirs::from_env()
                .ok_or_else(|| "HOME is not set".to_string())
                .and_then(|d| ghinstall::remove(&d, &repo));
            let _ = tx.send(match got {
                Ok(s) => format!("✓ {s}"),
                Err(e) => format!("✗ {e}"),
            });
        });
        self.gh_job = Some((rx, ask_rx));
    }

    /// Forgets a pending GitHub plan, deleting a download that was waiting for a second yes.
    fn drop_github(&mut self) {
        if let Some(GhPlan::Unchecked { dest, .. }) = self.github.take() {
            let _ = std::fs::remove_file(dest);
        }
    }

    fn run_github(&mut self, plan: GhPlan) {
        let (repo, release, kind, asset, downloaded) = match plan {
            GhPlan::Flathub(id) => return self.start(Action::Install, id),
            GhPlan::Release {
                repo,
                release,
                kind,
                asset,
            } => (repo, release, kind, asset, None),
            GhPlan::Unchecked {
                repo,
                release,
                kind,
                asset,
                dest,
            } => (repo, release, kind, asset, Some(dest)),
        };
        let (tx, rx) = mpsc::channel();
        let (ask_tx, ask_rx) = mpsc::channel();
        std::thread::spawn(move || {
            let result = (|| -> Result<Option<String>, String> {
                let dirs = ghinstall::Dirs::from_env().ok_or("HOME is not set")?;
                let (dest, verified) = match downloaded {
                    Some(dest) => (dest, false),
                    None => {
                        std::fs::create_dir_all(dirs.downloads()).map_err(|e| e.to_string())?;
                        let dest = dirs.downloads().join(&asset.name);
                        let _ = tx.send(format!("downloading {}…", asset.name));
                        let verified = github::download_verified(&release, &asset, &dest)?;
                        let _ = tx.send(if verified {
                            "checksum verified".to_string()
                        } else {
                            "no checksum published for it: not verified".to_string()
                        });
                        // A package that runs as root and couldn't be checked: ask once more.
                        if kind == Kind::Deb && !verified {
                            let scripts = ghinstall::deb_scripts(&dest);
                            let what = if scripts.is_empty() {
                                "It has no install scripts, but it still installs as root."
                                    .to_string()
                            } else {
                                format!("It runs install scripts as root ({}).", scripts.join(", "))
                            };
                            let _ = tx.send(format!(
                                "{} published no checksum for {}, so there's no way to tell it's the file its authors built. {what} This can change your whole computer.",
                                repo.slug(),
                                asset.name
                            ));
                            let _ = tx.send(
                                "Install it without a check? Enter installs anyway, Esc cancels."
                                    .into(),
                            );
                            let _ = ask_tx.send(GhPlan::Unchecked {
                                repo,
                                release,
                                kind,
                                asset,
                                dest,
                            });
                            return Ok(None);
                        }
                        (dest, verified)
                    }
                };
                let done =
                    ghinstall::install(&dirs, &repo, &release.tag, &kind, &asset.name, &dest);
                let _ = std::fs::remove_file(&dest);
                let summary = done?.summary;
                Ok(Some(if verified {
                    summary
                } else {
                    format!("{summary} (no checksum was published, so it wasn't verified)")
                }))
            })();
            match result {
                Ok(None) => {}
                Ok(Some(s)) => _ = tx.send(format!("✓ {s}")),
                Err(e) => _ = tx.send(format!("✗ {e}")),
            }
        });
        self.gh_job = Some((rx, ask_rx));
    }

    /// Drains GitHub install output; true when it ended.
    fn poll_github(&mut self) -> bool {
        let Some((rx, ask)) = self.gh_job.as_ref() else {
            return false;
        };
        loop {
            match rx.try_recv() {
                Ok(line) => self.status.push(line),
                Err(mpsc::TryRecvError::Empty) => return false,
                Err(mpsc::TryRecvError::Disconnected) => {
                    self.github = ask.try_recv().ok();
                    self.gh_job = None;
                    self.reload_installed();
                    return true;
                }
            }
        }
    }

    /// Drains job output; returns true when the job ended.
    fn poll_job(&mut self) -> bool {
        let Some(job) = self.job.as_mut() else {
            return false;
        };
        while let Ok(line) = job.lines.try_recv() {
            self.status.push(line);
        }
        match job.child.try_wait() {
            Ok(Some(status)) => {
                let verb = match job.action {
                    Action::Install => "installed",
                    Action::Uninstall => "removed",
                    Action::Update => "updated",
                };
                let msg = if status.success() {
                    format!("✓ {} {verb}", job.id)
                } else {
                    format!("✗ {} failed ({status})", job.id)
                };
                self.status.push(msg);
                self.job = None;
                self.reload_installed();
                true
            }
            _ => false,
        }
    }
}

fn draw(f: &mut Frame, s: &mut State) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(5),
            Constraint::Length(7),
        ])
        .split(f.area());
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(45), Constraint::Percentage(55)])
        .split(rows[1]);

    let search = Paragraph::new(Line::from(vec![
        Span::raw(" "),
        Span::styled(&s.query, Style::new().add_modifier(Modifier::BOLD)),
        Span::raw("▏"),
    ]))
    .block(Block::default().borders(Borders::ALL).title(format!(
        " Search {} apps ",
        s.results.len().min(MAX_RESULTS)
    )));
    f.render_widget(search, rows[0]);

    let items: Vec<ListItem> = s
        .results
        .iter()
        .map(|&i| {
            let a = &s.apps[i];
            let mark = if s.installed.contains_key(&a.id) {
                "✓ "
            } else {
                "  "
            };
            ListItem::new(Line::from(vec![
                Span::raw(mark),
                Span::styled(a.name.clone(), Style::new().add_modifier(Modifier::BOLD)),
                Span::raw(format!("  {}", a.summary)),
            ]))
        })
        .collect();
    let list = List::new(items)
        .block(Block::default().borders(Borders::ALL).title(" Results "))
        .highlight_style(Style::new().add_modifier(Modifier::REVERSED));
    f.render_stateful_widget(list, cols[0], &mut s.list);

    let details = match s.selected() {
        Some(a) => {
            let mut lines = vec![
                Line::from(Span::styled(
                    a.name.clone(),
                    Style::new().add_modifier(Modifier::BOLD),
                )),
                Line::from(a.summary.clone()),
                Line::from(""),
                Line::from(format!("id: {}", a.id)),
            ];
            if let Some(i) = s.installed.get(&a.id) {
                lines.push(Line::from(format!(
                    "installed: {} ({} {})",
                    if i.version.is_empty() {
                        "yes"
                    } else {
                        &i.version
                    },
                    i.origin,
                    i.installation
                )));
            }
            if !a.developer.is_empty() {
                lines.push(Line::from(format!("by: {}", a.developer)));
            }
            if !a.license.is_empty() {
                lines.push(Line::from(format!("licence: {}", a.license)));
            }
            if !a.categories.is_empty() {
                lines.push(Line::from(format!(
                    "categories: {}",
                    a.categories.join(", ")
                )));
            }
            for (label, url) in [("web", &a.homepage), ("source", &a.vcs_browser)] {
                if let Some(u) = url {
                    lines.push(Line::from(format!("{label}: {u}")));
                }
            }
            lines.push(Line::from(""));
            lines.extend(a.description.lines().map(|l| Line::from(l.to_string())));
            lines
        }
        None => vec![Line::from("No matches.")],
    };
    f.render_widget(
        Paragraph::new(details)
            .wrap(Wrap { trim: false })
            .block(Block::default().borders(Borders::ALL).title(" Details ")),
        cols[1],
    );

    let help = if let Some(id) = &s.confirm_remove {
        format!(" Remove {id}? Enter = yes, Esc = no ")
    } else if s.github.is_some() {
        " Install it? Enter = yes, Esc = no ".to_string()
    } else if s.job.is_some() || s.gh_job.is_some() {
        " working… ".to_string()
    } else {
        " Enter install/remove · paste a GitHub link + Enter · Ctrl+U update · Esc quit "
            .to_string()
    };
    let tail: Vec<Line> = s
        .status
        .iter()
        .rev()
        .take(5)
        .rev()
        .map(|l| Line::from(l.clone()))
        .collect();
    f.render_widget(
        Paragraph::new(tail).block(Block::default().borders(Borders::ALL).title(help)),
        rows[2],
    );
}

/// Handles a key; returns false to quit.
fn on_key(s: &mut State, k: KeyEvent) -> bool {
    if k.kind != KeyEventKind::Press {
        return true;
    }
    let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
    match k.code {
        KeyCode::Char('c') if ctrl => return false,
        KeyCode::Esc => {
            if s.confirm_remove.take().is_none() {
                if s.github.is_none() {
                    return false;
                }
                s.drop_github();
            }
        }
        KeyCode::Char('r') if ctrl => s.reload_installed(),
        KeyCode::Enter => {
            if let Some(id) = s.confirm_remove.take() {
                match github::parse_repo(&id).filter(|_| id.starts_with("github.com/")) {
                    Some(repo) if s.gh_job.is_none() => s.remove_github(repo),
                    Some(_) => s.status.push("wait for the current job to finish".into()),
                    None => s.start(Action::Uninstall, id),
                }
            } else if let Some(plan) = s.github.take() {
                if s.job.is_some() || s.gh_job.is_some() {
                    s.status.push("wait for the current job to finish".into());
                    s.github = Some(plan);
                } else {
                    s.run_github(plan);
                }
            } else if is_github_link(&s.query) {
                s.resolve_github();
            } else if let Some(a) = s.selected() {
                let id = a.id.clone();
                if s.installed.contains_key(&id) {
                    s.confirm_remove = Some(id);
                } else {
                    s.start(Action::Install, id);
                }
            }
        }
        KeyCode::Char('d') if ctrl && is_github_link(&s.query) => {
            let dirs = ghinstall::Dirs::from_env();
            match github::parse_repo(&s.query) {
                Some(r)
                    if dirs
                        .and_then(|d| ghinstall::installed_tag(&d, &r))
                        .is_some() =>
                {
                    s.drop_github();
                    s.confirm_remove = Some(format!("github.com/{}", r.slug()));
                }
                _ => s
                    .status
                    .push("that project wasn't installed by the store".into()),
            }
        }
        KeyCode::Char('u') if ctrl => {
            if let Some(a) = s.selected() {
                let id = a.id.clone();
                s.start(Action::Update, id);
            }
        }
        KeyCode::Up => s.list.select_previous(),
        KeyCode::Down => s.list.select_next(),
        KeyCode::PageUp => s.list.scroll_up_by(10),
        KeyCode::PageDown => s.list.scroll_down_by(10),
        KeyCode::Backspace => {
            s.drop_github();
            s.query.pop();
            s.refresh_results();
        }
        KeyCode::Char(c) if !ctrl => {
            s.drop_github();
            s.query.push(c);
            s.refresh_results();
        }
        _ => {}
    }
    true
}

fn run(term: &mut DefaultTerminal, s: &mut State) -> std::io::Result<()> {
    loop {
        term.draw(|f| draw(f, s))?;
        // Blocking read while idle; short polls only while a flatpak job is running.
        let ev = if s.job.is_some() || s.gh_job.is_some() {
            if event::poll(Duration::from_millis(100))? {
                Some(event::read()?)
            } else {
                None
            }
        } else {
            Some(event::read()?)
        };
        if let Some(Event::Key(k)) = ev {
            if !on_key(s, k) {
                return Ok(());
            }
        }
        s.poll_job();
        s.poll_github();
    }
}

fn main() -> ExitCode {
    // `ostrich store --gui`: the store window, installed next to this program.
    if std::env::args().nth(1).as_deref() == Some("--gui") {
        use std::os::unix::process::CommandExt;
        let gui = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.join("ostrich-store-gtk")))
            .unwrap_or_else(|| "ostrich-store-gtk".into());
        let err = std::process::Command::new(&gui)
            .args(std::env::args().skip(2))
            .exec();
        eprintln!(
            "ostrich store: could not open the store window ({}): {err}",
            gui.display()
        );
        return ExitCode::FAILURE;
    }
    if matches!(
        std::env::args().nth(1).as_deref(),
        Some("-h" | "--help" | "help")
    ) {
        println!("usage: ostrich store [SEARCH]   search Flathub and install, in the terminal\n       ostrich store --gui       the store window");
        return ExitCode::SUCCESS;
    }
    if !std::io::IsTerminal::is_terminal(&std::io::stdout()) {
        eprintln!("ostrich store: needs a terminal (or use `ostrich store --gui`)");
        return ExitCode::from(2);
    }
    let Some(path) = store_core::catalogue_path(REMOTE) else {
        eprintln!("ostrich store: no Flathub catalogue found. Add Flathub and refresh it with:\n  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo\n  flatpak update --appstream");
        return ExitCode::FAILURE;
    };
    let apps = match appstream::load(&path) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("ostrich store: {e}");
            return ExitCode::FAILURE;
        }
    };
    let mut s = State {
        apps,
        installed: HashMap::new(),
        searcher: Searcher::default(),
        query: std::env::args().skip(1).collect::<Vec<_>>().join(" "),
        results: Vec::new(),
        list: ListState::default(),
        status: vec![format!("catalogue: {}", path.display())],
        confirm_remove: None,
        job: None,
        github: None,
        gh_job: None,
    };
    s.reload_installed();
    s.refresh_results();
    let mut term = ratatui::init();
    let r = run(&mut term, &mut s);
    ratatui::restore();
    if let Some(mut job) = s.job.take() {
        eprintln!("ostrich store: waiting for {} to finish…", job.id);
        let _ = job.child.wait();
    }
    match r {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("ostrich store: {e}");
            ExitCode::FAILURE
        }
    }
}
