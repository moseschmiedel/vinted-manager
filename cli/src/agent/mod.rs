//! AI agents (Claude Code, Codex, …) driven through their own CLIs and the user's own login.
//!
//! This is the only place that talks to AI: front ends (terminal, macOS app, …) run
//! `vinted agent run … --json` and render the shared event stream.

mod parse;
mod task;

use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use anyhow::{Context, Result, bail};
use clap::{Subcommand, ValueEnum};
use serde_json::{Value, json};

use crate::Repo;
pub use parse::Event;
pub use task::Task;

#[derive(Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Kind {
    Claude,
    Codex,
}

impl Kind {
    pub const ALL: [Kind; 2] = [Kind::Claude, Kind::Codex];

    pub fn id(self) -> &'static str {
        match self {
            Kind::Claude => "claude",
            Kind::Codex => "codex",
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Kind::Claude => "Claude Code",
            Kind::Codex => "Codex",
        }
    }

    fn login_command(self) -> &'static str {
        match self {
            Kind::Claude => "claude auth login",
            Kind::Codex => "codex login",
        }
    }

    fn from_id(id: &str) -> Option<Kind> {
        Kind::ALL.into_iter().find(|k| k.id() == id)
    }
}

// ---------------------------------------------------------------- CLI

#[derive(Subcommand)]
pub enum AgentCmd {
    /// Show agents, whether they're installed and logged in, and their settings
    Status {
        #[arg(long)]
        json: bool,
    },
    /// Change agent settings (stored per user, not in the repository)
    Config {
        #[command(subcommand)]
        action: ConfigAction,
    },
    /// Run an agent in this repository
    Run {
        #[command(subcommand)]
        task: RunTask,
        /// Agent to use (default: the configured default, if ready)
        #[arg(long, global = true)]
        provider: Option<Kind>,
        /// Model override for this run
        #[arg(long, global = true)]
        model: Option<String>,
        /// Print events as JSON lines (for apps)
        #[arg(long, global = true)]
        json: bool,
    },
}

#[derive(Subcommand)]
pub enum ConfigAction {
    /// Set a value: default, <agent>.binary, <agent>.model, <agent>.env ("KEY=value" lines)
    Set { key: String, value: String },
    /// Print the settings file path
    Path,
}

#[derive(Subcommand)]
pub enum RunTask {
    /// Sort newly imported inbox photos into folders, one folder per item
    Cluster {
        #[arg(required = true, num_args = 1..)]
        photos: Vec<String>,
    },
    /// Draft one listing from an inbox photo or photo folder
    Draft { group: String },
    /// Process the whole inbox
    Inbox,
    /// Re-check an item's price
    Price { id: String },
    /// Work the user's answers from Notizen into an item
    Revise { id: String },
    /// Any instruction, e.g. "item 4 sold for 4 €"
    #[command(alias = "ask")]
    Instruction {
        #[arg(required = true, num_args = 1..)]
        text: Vec<String>,
    },
}

pub fn command(repo: &Repo, cmd: AgentCmd) -> Result<i32> {
    let config = Config::load()?;
    match cmd {
        AgentCmd::Status { json } => {
            status(&config, json);
            Ok(0)
        }
        AgentCmd::Config {
            action: ConfigAction::Path,
        } => {
            println!("{}", Config::path().display());
            Ok(0)
        }
        AgentCmd::Config {
            action: ConfigAction::Set { key, value },
        } => {
            let mut config = config;
            config.set(&key, &value)?;
            config.save()?;
            println!("Updated {key}");
            Ok(0)
        }
        AgentCmd::Run {
            task,
            provider,
            model,
            json,
        } => {
            let task = match task {
                RunTask::Cluster { photos } => Task::cluster(repo, &photos)?,
                RunTask::Draft { group } => Task::draft(repo, &group)?,
                RunTask::Inbox => Task::Inbox,
                RunTask::Price { id } => Task::price(repo, &id)?,
                RunTask::Revise { id } => Task::revise(repo, &id)?,
                RunTask::Instruction { text } => Task::Ask {
                    text: text.join(" "),
                },
            };
            run(repo, &config, provider, model, &task, json)
        }
    }
}

// ---------------------------------------------------------------- settings

#[derive(Default, Clone)]
pub struct AgentSettings {
    pub binary: String,
    pub model: String,
    pub env: BTreeMap<String, String>,
}

pub struct Config {
    pub default: Kind,
    pub agents: BTreeMap<&'static str, AgentSettings>,
}

impl Config {
    /// `~/Library/Application Support/vinted/agents.json` on macOS, `~/.config/vinted/…` on Linux,
    /// `%APPDATA%\vinted\…` on Windows. `VINTED_CONFIG_DIR` overrides (tests).
    pub fn path() -> PathBuf {
        let dir = env::var_os("VINTED_CONFIG_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                dirs::config_dir()
                    .unwrap_or_else(|| PathBuf::from("."))
                    .join("vinted")
            });
        dir.join("agents.json")
    }

    pub fn load() -> Result<Config> {
        let mut config = Config {
            default: Kind::Claude,
            agents: Kind::ALL
                .iter()
                .map(|k| (k.id(), AgentSettings::default()))
                .collect(),
        };
        let path = Self::path();
        let Ok(text) = fs::read_to_string(&path) else {
            return Ok(config);
        };
        let value: Value =
            serde_json::from_str(&text).with_context(|| format!("reading {}", path.display()))?;
        if let Some(kind) = value["default"].as_str().and_then(Kind::from_id) {
            config.default = kind;
        }
        for kind in Kind::ALL {
            let agent = &value["agents"][kind.id()];
            let settings = config.agents.get_mut(kind.id()).unwrap();
            settings.binary = agent["binary"].as_str().unwrap_or("").to_string();
            settings.model = agent["model"].as_str().unwrap_or("").to_string();
            if let Some(env) = agent["env"].as_object() {
                settings.env = env
                    .iter()
                    .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string())))
                    .collect();
            }
        }
        Ok(config)
    }

    pub fn save(&self) -> Result<()> {
        let path = Self::path();
        fs::create_dir_all(path.parent().unwrap())?;
        let mut options = fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&path)?;
        #[cfg(unix)]
        fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o600))?;
        file.write_all((serde_json::to_string_pretty(&self.to_json())? + "\n").as_bytes())?;
        Ok(())
    }

    fn to_json(&self) -> Value {
        let agents: serde_json::Map<String, Value> = self
            .agents
            .iter()
            .map(|(id, s)| {
                (
                    id.to_string(),
                    json!({"binary": s.binary, "model": s.model, "env": s.env}),
                )
            })
            .collect();
        json!({"default": self.default.id(), "agents": agents})
    }

    fn settings(&self, kind: Kind) -> &AgentSettings {
        &self.agents[kind.id()]
    }

    pub fn set(&mut self, key: &str, value: &str) -> Result<()> {
        if key == "default" {
            self.default =
                Kind::from_id(value).with_context(|| format!("unknown agent {value:?}"))?;
            return Ok(());
        }
        let Some((agent, field)) = key.split_once('.') else {
            bail!("unknown setting {key:?}")
        };
        let kind = Kind::from_id(agent).with_context(|| format!("unknown agent {agent:?}"))?;
        let settings = self.agents.get_mut(kind.id()).unwrap();
        match field {
            "binary" => settings.binary = value.trim().to_string(),
            "model" => settings.model = value.trim().to_string(),
            "env" => {
                settings.env = value
                    .lines()
                    .filter_map(|line| line.split_once('='))
                    .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
                    .filter(|(k, _)| !k.is_empty())
                    .collect();
            }
            _ => bail!("unknown setting {key:?} (binary, model or env)"),
        }
        Ok(())
    }
}

// ---------------------------------------------------------------- detection

/// PATH of the user's login shell: apps started from Finder get a minimal PATH, but agent
/// CLIs and their runtimes (node, bun) live in ~/.local/bin, Homebrew, etc.
fn search_path() -> String {
    let current = env::var("PATH").unwrap_or_default();
    #[cfg(unix)]
    {
        let home = dirs::home_dir().unwrap_or_default();
        let extra: Vec<String> = [".local/bin", ".bun/bin", ".cargo/bin", ".npm-global/bin"]
            .iter()
            .map(|d| home.join(d).to_string_lossy().to_string())
            .chain([
                "/opt/homebrew/bin".to_string(),
                "/usr/local/bin".to_string(),
            ])
            .collect();
        let shell = env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
        let login = Command::new(shell)
            .args(["-lc", "printf %s \"$PATH\""])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
            .unwrap_or_default();
        [login, current, extra.join(":")]
            .into_iter()
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(":")
    }
    #[cfg(not(unix))]
    current
}

fn resolve_executable(kind: Kind, settings: &AgentSettings, path: &str) -> Option<PathBuf> {
    if !settings.binary.is_empty() {
        let binary = expand_home(&settings.binary);
        return is_executable(&binary).then_some(binary);
    }
    let names: &[&str] = if cfg!(windows) {
        &[".exe", ".cmd", ""]
    } else {
        &[""]
    };
    env::split_paths(path)
        .flat_map(|dir| {
            names
                .iter()
                .map(move |ext| dir.join(format!("{}{ext}", kind.id())))
        })
        .find(|candidate| is_executable(candidate))
}

fn is_executable(path: &Path) -> bool {
    let Ok(metadata) = fs::metadata(path) else { return false };
    if !metadata.is_file() { return false; }
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))] { true }
}

fn expand_home(path: &str) -> PathBuf {
    match path.strip_prefix("~/") {
        Some(rest) => dirs::home_dir().unwrap_or_default().join(rest),
        None => PathBuf::from(path),
    }
}

fn agent_command(executable: &Path, settings: &AgentSettings, path: &str) -> Command {
    let mut command = Command::new(executable);
    command
        .env("PATH", path)
        .envs(&settings.env)
        .stdin(Stdio::null());
    command
}

struct Status {
    executable: Option<PathBuf>,
    version: Option<String>,
    logged_in: bool,
    detail: String,
}

fn detect(kind: Kind, settings: &AgentSettings, path: &str) -> Status {
    let Some(executable) = resolve_executable(kind, settings, path) else {
        return Status {
            executable: None,
            version: None,
            logged_in: false,
            detail: format!("{} not found", kind.id()),
        };
    };
    let output = |args: &[&str]| {
        agent_command(&executable, settings, path)
            .args(args)
            .output()
            .ok()
    };
    let version = output(&["--version"])
        .and_then(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .next()
                .map(|l| l.trim().to_string())
        })
        .filter(|v| !v.is_empty());
    let (logged_in, mut detail) = match kind {
        Kind::Claude => {
            let info: Value = output(&["auth", "status"])
                .filter(|o| o.status.success())
                .and_then(|o| serde_json::from_slice(&o.stdout).ok())
                .unwrap_or(Value::Null);
            let logged_in = info["loggedIn"].as_bool().unwrap_or(false);
            let method = info["authMethod"].as_str().unwrap_or("unknown");
            (
                logged_in,
                if logged_in {
                    format!("Logged in ({method})")
                } else {
                    "Not logged in".into()
                },
            )
        }
        Kind::Codex => {
            let out = output(&["login", "status"]);
            let text = out
                .as_ref()
                .map(|o| {
                    format!(
                        "{}{}",
                        String::from_utf8_lossy(&o.stdout),
                        String::from_utf8_lossy(&o.stderr)
                    )
                })
                .unwrap_or_default();
            let lower = text.to_lowercase();
            let ok = out.is_some_and(|o| o.status.success())
                && lower.contains("logged in")
                && !lower.contains("not logged in");
            (
                ok,
                text.lines()
                    .next()
                    .unwrap_or("Not logged in")
                    .trim()
                    .to_string(),
            )
        }
    };
    if !logged_in {
        detail = format!("{detail} — run `{}` in a terminal", kind.login_command());
    }
    Status {
        executable: Some(executable),
        version,
        logged_in,
        detail,
    }
}

fn status(config: &Config, as_json: bool) {
    let path = search_path();
    let agents: Vec<(Kind, Status)> = Kind::ALL
        .iter()
        .map(|&k| (k, detect(k, config.settings(k), &path)))
        .collect();
    if as_json {
        let list: Vec<Value> = agents
            .iter()
            .map(|(kind, s)| {
                let settings = config.settings(*kind);
                json!({
                    "id": kind.id(), "name": kind.name(),
                    "ready": s.executable.is_some() && s.logged_in,
                    "executable": s.executable.as_ref().map(|p| p.to_string_lossy()),
                    "version": s.version, "logged_in": s.logged_in, "detail": s.detail,
                    "login_command": kind.login_command(),
                    "binary": settings.binary, "model": settings.model, "env": settings.env,
                })
            })
            .collect();
        let out =
            json!({"default": config.default.id(), "config_path": Config::path(), "agents": list});
        println!("{}", serde_json::to_string_pretty(&out).unwrap());
        return;
    }
    println!("Settings: {}\n", Config::path().display());
    for (kind, s) in agents {
        let mark = if s.executable.is_some() && s.logged_in {
            "✓"
        } else {
            "✗"
        };
        let default = if kind == config.default {
            " (default)"
        } else {
            ""
        };
        println!("{mark} {}{default}: {}", kind.name(), s.detail);
        if let Some(exe) = &s.executable {
            println!(
                "    {} · {}",
                s.version.as_deref().unwrap_or("?"),
                exe.display()
            );
        }
    }
}

// ---------------------------------------------------------------- run

/// Tools Claude may use without asking; everything else is denied (`dontAsk`).
const CLAUDE_TOOLS: &str =
    "Read,Write,Edit,Glob,Grep,WebSearch,WebFetch,Bash(./vinted:*),Bash(magick:*)";

fn arguments(kind: Kind, model: &str, prompt: &str, root: &Path) -> Vec<String> {
    let mut args: Vec<String> = match kind {
        Kind::Claude => [
            "-p",
            prompt,
            "--output-format",
            "stream-json",
            "--verbose",
            "--permission-mode",
            "dontAsk",
            "--allowedTools",
            CLAUDE_TOOLS,
        ]
        .iter()
        .map(|s| s.to_string())
        .collect(),
        // workspace-write keeps changes inside the repo; network is needed for `./vinted comps`.
        Kind::Codex => [
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--sandbox",
            "workspace-write",
            "-c",
            "sandbox_workspace_write.network_access=true",
            "-C",
        ]
        .iter()
        .map(|s| s.to_string())
        .chain([root.to_string_lossy().to_string()])
        .collect(),
    };
    if !model.is_empty() {
        args.extend(["--model".to_string(), model.to_string()]);
    }
    if kind == Kind::Codex {
        args.push(prompt.to_string());
    }
    args
}

static CHILD_PID: AtomicU32 = AtomicU32::new(0);
static CANCELLED: AtomicBool = AtomicBool::new(false);

fn emit(event: &Event, as_json: bool) {
    if as_json {
        println!("{}", event.to_json());
        return;
    }
    match event {
        Event::Started { model, .. } => println!("… {}", model.as_deref().unwrap_or("started")),
        Event::Message { text } => println!("\n{text}\n"),
        Event::Tool { name, detail } => println!("  · {name} {detail}"),
        Event::Finished {
            summary,
            is_error,
            cost_usd,
        } => {
            if *is_error {
                eprintln!("✗ {}", summary.as_deref().unwrap_or("failed"));
            } else {
                let cost = cost_usd.map(|c| format!(" (${c:.2})")).unwrap_or_default();
                println!("✓ done{cost}");
            }
        }
        Event::Notice { text } => eprintln!("{text}"),
    }
}

/// Returns the process exit code: 0 ok, 1 failed, 130 cancelled.
fn run(
    repo: &Repo,
    config: &Config,
    provider: Option<Kind>,
    model: Option<String>,
    task: &Task,
    as_json: bool,
) -> Result<i32> {
    let path = search_path();
    let kind = match provider {
        Some(kind) => kind,
        None => {
            let ready = |k: Kind| {
                let s = detect(k, config.settings(k), &path);
                s.executable.is_some() && s.logged_in
            };
            if ready(config.default) {
                config.default
            } else {
                Kind::ALL
                    .into_iter()
                    .find(|&k| ready(k))
                    .context("No agent is ready. Run `./vinted agent status`.")?
            }
        }
    };
    let settings = config.settings(kind);
    let model = model.unwrap_or_else(|| settings.model.clone());
    if as_json {
        println!(
            "{}",
            json!({"type": "run", "provider": kind.id(), "provider_name": kind.name(), "title": task.title()})
        );
    } else {
        println!("▶ {} — {}", kind.name(), task.title());
    }

    let Some(executable) = resolve_executable(kind, settings, &path) else {
        emit(
            &Event::Finished {
                summary: Some(format!("{} not found", kind.id())),
                is_error: true,
                cost_usd: None,
            },
            as_json,
        );
        return Ok(1);
    };
    let mut command = agent_command(&executable, settings, &path);
    command
        .args(arguments(kind, &model, &task.prompt(), &repo.root))
        .current_dir(&repo.root)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    {
        // Own process group, so cancelling also stops the agent's subprocesses.
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command
        .spawn()
        .with_context(|| format!("starting {}", executable.display()))?;
    CHILD_PID.store(child.id(), Ordering::SeqCst);
    let _ = ctrlc::set_handler(|| {
        CANCELLED.store(true, Ordering::SeqCst);
        terminate(CHILD_PID.load(Ordering::SeqCst));
    });

    let mut stderr = child.stderr.take().unwrap();
    let stderr_reader = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = stderr.read_to_string(&mut text);
        text
    });

    let mut finished: Option<Event> = None;
    for line in BufReader::new(child.stdout.take().unwrap()).lines() {
        let Ok(line) = line else {
            emit(
                &Event::Notice {
                    text: "Reading agent output failed".into(),
                },
                as_json,
            );
            break;
        };
        let events = match kind {
            Kind::Claude => parse::claude(&line),
            Kind::Codex => parse::codex(&line),
        };
        for event in events {
            if matches!(event, Event::Finished { .. }) {
                finished = Some(event);
            } else {
                emit(&event, as_json);
            }
        }
    }
    let status = child.wait()?;
    let stderr_text = stderr_reader.join().unwrap_or_default();

    CHILD_PID.store(0, Ordering::SeqCst);
    if CANCELLED.swap(false, Ordering::SeqCst) {
        emit(
            &Event::Finished {
                summary: Some("Cancelled".into()),
                is_error: true,
                cost_usd: None,
            },
            as_json,
        );
        return Ok(130);
    }
    match finished {
        Some(
            event @ Event::Finished {
                is_error: false, ..
            },
        ) if status.success() => {
            if let Task::Cluster { photos } = task {
                let remaining: Vec<&String> = photos
                    .iter()
                    .filter(|photo| repo.root.join(photo).exists())
                    .collect();
                if !remaining.is_empty() {
                    emit(
                        &Event::Finished {
                            summary: Some(format!(
                                "Photos still ungrouped: {}",
                                remaining
                                    .iter()
                                    .map(|p| p.as_str())
                                    .collect::<Vec<_>>()
                                    .join(", ")
                            )),
                            is_error: true,
                            cost_usd: None,
                        },
                        as_json,
                    );
                    return Ok(1);
                }
            }
            emit(&event, as_json);
            Ok(0)
        }
        Some(Event::Finished {
            is_error: false, ..
        }) => {
            emit(
                &Event::Finished {
                    summary: Some(format!("{} exited with {status}", kind.id())),
                    is_error: true,
                    cost_usd: None,
                },
                as_json,
            );
            Ok(1)
        }
        Some(event @ Event::Finished { is_error: true, .. }) => {
            emit(&event, as_json);
            Ok(1)
        }
        Some(_) => unreachable!("only finished events are stored"),
        None => {
            let tail: String = stderr_text
                .trim()
                .chars()
                .rev()
                .take(2000)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            let summary = if tail.is_empty() {
                format!("{} exited with {status}", kind.id())
            } else {
                tail
            };
            emit(
                &Event::Finished {
                    summary: Some(summary),
                    is_error: true,
                    cost_usd: None,
                },
                as_json,
            );
            Ok(1)
        }
    }
}

fn terminate(pid: u32) {
    if pid == 0 {
        return;
    }
    #[cfg(unix)]
    unsafe {
        // Negative pid = the whole process group created with `process_group(0)`.
        libc::kill(-(pid as i32), libc::SIGTERM);
    }
    #[cfg(not(unix))]
    {
        let _ = Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/T", "/F"])
            .status();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_runs_restricted() {
        let args = arguments(Kind::Claude, "sonnet", "hi", Path::new("/repo"));
        assert!(args.contains(&"dontAsk".to_string()));
        assert!(args.iter().any(|a| a.contains("Bash(./vinted:*)")));
        assert!(!args.iter().any(|a| a == "Bash" || a.contains("Bash(*)")));
        assert_eq!(&args[args.len() - 2..], ["--model", "sonnet"]);
    }

    #[test]
    fn codex_runs_in_workspace_sandbox() {
        let args = arguments(Kind::Codex, "", "hi", Path::new("/repo"));
        assert_eq!(&args[..2], ["exec", "--json"]);
        assert!(args.contains(&"workspace-write".to_string()));
        assert_eq!(args.last().unwrap(), "hi");
        assert!(!args.contains(&"--model".to_string()));
    }

    #[cfg(unix)]
    #[test]
    fn readiness_requires_executable_and_successful_login_check() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let binary = temp.path().join("assistant");
        let mut settings = AgentSettings { binary: binary.to_string_lossy().into(), ..Default::default() };
        assert!(detect(Kind::Claude, &settings, "/usr/bin:/bin").executable.is_none());
        fs::write(&binary, r#"#!/bin/sh
if [ "$1" = "--version" ]; then echo test-version; exit 0; fi
if [ "$1" = "auth" ]; then
    printf '{"loggedIn":%s}' "${TEST_LOGIN:-false}"
else
    if [ "${TEST_LOGIN:-false}" = "true" ]; then echo 'Logged in'; else echo 'Not logged in'; fi
fi
exit "${TEST_EXIT:-0}"
"#).unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(detect(Kind::Claude, &settings, "/usr/bin:/bin").executable.is_none());
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        for kind in [Kind::Claude, Kind::Codex] {
            settings.env.insert("TEST_LOGIN".into(), "false".into());
            settings.env.insert("TEST_EXIT".into(), "0".into());
            let logged_out = detect(kind, &settings, "/usr/bin:/bin");
            assert!(logged_out.executable.is_some());
            assert!(!logged_out.logged_in);
            settings.env.insert("TEST_LOGIN".into(), "true".into());
            assert!(detect(kind, &settings, "/usr/bin:/bin").logged_in);
            settings.env.insert("TEST_EXIT".into(), "1".into());
            assert!(!detect(kind, &settings, "/usr/bin:/bin").logged_in);
        }
    }

    #[test]
    fn config_set_and_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        // SAFETY: tests touching VINTED_CONFIG_DIR run only here.
        unsafe { env::set_var("VINTED_CONFIG_DIR", dir.path()) };
        let mut config = Config::load().unwrap();
        config.set("default", "codex").unwrap();
        config.set("claude.model", "opus").unwrap();
        config
            .set("claude.env", "CLAUDE_CONFIG_DIR=~/.claude_personal\nBAD")
            .unwrap();
        assert!(config.set("claude.nope", "x").is_err());
        assert!(config.set("gemini.model", "x").is_err());
        config.save().unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(Config::path()).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }

        let loaded = Config::load().unwrap();
        assert!(loaded.default == Kind::Codex);
        assert_eq!(loaded.settings(Kind::Claude).model, "opus");
        assert_eq!(
            loaded
                .settings(Kind::Claude)
                .env
                .get("CLAUDE_CONFIG_DIR")
                .map(String::as_str),
            Some("~/.claude_personal")
        );
        assert_eq!(loaded.settings(Kind::Claude).env.len(), 1);
    }
}
