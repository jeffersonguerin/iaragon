//! iaragon-tray — a StatusNotifierItem (system tray) status indicator.
//!
//! A tiny standalone binary: it does not share code with the daemon, it only
//! reads the daemon's status socket (the same socket the Dolphin overlay
//! plugin uses). It sends the reserved `?status` line and shows the one-word
//! aggregate reply as a tray icon + tooltip, polling on an interval. If the
//! socket does not answer, the daemon is not running and the tray shows an
//! offline icon. No daemon coupling beyond that one line protocol.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

/// The daemon's aggregate sync state, as reported by the `?status` query.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Status {
    Syncing,
    Synced,
    Failed,
    /// The socket did not answer — no daemon running there.
    Offline,
}

impl Status {
    /// Map the daemon's status word to a state. Anything unrecognised (and
    /// the daemon's own "unknown") is treated as offline-equivalent: we only
    /// light up on a word we understand.
    fn parse(word: &str) -> Status {
        match word.trim() {
            "syncing" => Status::Syncing,
            "synced" => Status::Synced,
            "failed" => Status::Failed,
            _ => Status::Offline,
        }
    }

    /// A themed freedesktop icon name — no bundled pixmaps, so it inherits the
    /// user's icon theme.
    fn icon_name(self) -> &'static str {
        match self {
            Status::Syncing => "emblem-synchronizing",
            Status::Synced => "emblem-default",
            Status::Failed => "dialog-error",
            Status::Offline => "network-offline",
        }
    }

    fn description(self) -> &'static str {
        match self {
            Status::Syncing => "Syncing with Google Drive…",
            Status::Synced => "Up to date",
            Status::Failed => "A transfer failed — check iaragon-doctor",
            Status::Offline => "Daemon not running",
        }
    }
}

/// Resolve the status socket path exactly as the daemon does
/// (status_server.resolve_socket_path): the user runtime dir when the session
/// provides a non-empty one, the iaragon data dir otherwise. An empty
/// XDG_RUNTIME_DIR counts as absent.
fn resolve_socket_path(runtime_dir: Option<String>, data_dir: &str) -> PathBuf {
    match runtime_dir {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir).join("iaragon.sock"),
        _ => PathBuf::from(data_dir).join("status.sock"),
    }
}

/// The iaragon data dir: $XDG_DATA_HOME/iaragon, else ~/.local/share/iaragon.
fn data_dir(xdg_data_home: Option<String>, home: &str) -> String {
    let base = match xdg_data_home {
        Some(d) if !d.is_empty() => d,
        _ => format!("{home}/.local/share"),
    };
    format!("{base}/iaragon")
}

/// Ask the daemon for its aggregate status. Any I/O error (no socket file,
/// connection refused, timeout) means no daemon is answering — Offline.
fn query_status(socket: &std::path::Path) -> Status {
    match query_once(socket) {
        Ok(word) => Status::parse(&word),
        Err(_) => Status::Offline,
    }
}

fn query_once(socket: &std::path::Path) -> std::io::Result<String> {
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    stream.write_all(b"?status\n")?;
    let mut buf = String::new();
    stream.read_to_string(&mut buf)?;
    Ok(buf)
}

// --- tray ------------------------------------------------------------------

struct IaragonTray {
    status: Status,
    mirror: String,
}

impl ksni::Tray for IaragonTray {
    fn icon_name(&self) -> String {
        self.status.icon_name().to_string()
    }

    fn title(&self) -> String {
        "iaragon".into()
    }

    fn id(&self) -> String {
        "iaragon".into()
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip {
            title: "iaragon".into(),
            description: self.status.description().into(),
            icon_name: self.status.icon_name().to_string(),
            icon_pixmap: Vec::new(),
        }
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::{MenuItem, StandardItem};
        let mirror = self.mirror.clone();
        vec![
            StandardItem {
                label: format!("iaragon — {}", self.status.description()),
                enabled: false,
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            StandardItem {
                label: "Open mirror folder".into(),
                icon_name: "folder".into(),
                activate: Box::new(move |_: &mut Self| {
                    let _ = std::process::Command::new("xdg-open").arg(&mirror).spawn();
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Quit".into(),
                icon_name: "application-exit".into(),
                activate: Box::new(|_: &mut Self| std::process::exit(0)),
                ..Default::default()
            }
            .into(),
        ]
    }
}

fn env_nonempty(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

fn main() {
    let home = env_nonempty("HOME").unwrap_or_else(|| ".".to_string());
    let socket = resolve_socket_path(
        env_nonempty("XDG_RUNTIME_DIR"),
        &data_dir(env_nonempty("XDG_DATA_HOME"), &home),
    );
    // The mirror the "Open folder" item points at; override with IARAGON_MIRROR.
    let mirror = env_nonempty("IARAGON_MIRROR").unwrap_or_else(|| format!("{home}/GoogleDrive"));

    // The blocking API keeps main synchronous; ksni runs its zbus reactor on
    // its own thread. (ksni 0.3 speaks DBus via pure-Rust zbus — no libdbus C
    // library to build or link against.)
    use ksni::blocking::TrayMethods;
    let handle = IaragonTray {
        status: query_status(&socket),
        mirror,
    }
    .spawn()
    .expect("no StatusNotifierItem host available (is a system tray running?)");

    // Poll the socket and push updates into the tray. A tray icon is idle
    // almost all the time, so a few-second poll is plenty and cheap.
    loop {
        std::thread::sleep(Duration::from_secs(3));
        let status = query_status(&socket);
        handle.update(|tray: &mut IaragonTray| tray.status = status);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_known_status_words() {
        assert_eq!(Status::parse("syncing"), Status::Syncing);
        assert_eq!(Status::parse("synced\n"), Status::Synced);
        assert_eq!(Status::parse("  failed  "), Status::Failed);
    }

    #[test]
    fn unknown_or_daemon_unknown_word_is_offline() {
        assert_eq!(Status::parse("unknown"), Status::Offline);
        assert_eq!(Status::parse(""), Status::Offline);
        assert_eq!(Status::parse("garbage"), Status::Offline);
    }

    #[test]
    fn runtime_dir_wins_when_present() {
        assert_eq!(
            resolve_socket_path(Some("/run/user/1000".into()), "/home/u/.local/share/iaragon"),
            PathBuf::from("/run/user/1000/iaragon.sock"),
        );
    }

    #[test]
    fn empty_or_absent_runtime_dir_falls_back_to_data_dir() {
        let data = "/home/u/.local/share/iaragon";
        assert_eq!(
            resolve_socket_path(Some(String::new()), data),
            PathBuf::from("/home/u/.local/share/iaragon/status.sock"),
        );
        assert_eq!(
            resolve_socket_path(None, data),
            PathBuf::from("/home/u/.local/share/iaragon/status.sock"),
        );
    }

    #[test]
    fn data_dir_prefers_xdg_then_home() {
        assert_eq!(data_dir(Some("/x/data".into()), "/home/u"), "/x/data/iaragon");
        assert_eq!(data_dir(None, "/home/u"), "/home/u/.local/share/iaragon");
        assert_eq!(data_dir(Some(String::new()), "/home/u"), "/home/u/.local/share/iaragon");
    }

    #[test]
    fn every_status_has_a_themed_icon() {
        for s in [Status::Syncing, Status::Synced, Status::Failed, Status::Offline] {
            assert!(!s.icon_name().is_empty());
            assert!(!s.description().is_empty());
        }
    }
}
