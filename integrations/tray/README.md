# iaragon-tray

A system-tray status indicator for the iaragon sync daemon, implementing the
freedesktop **StatusNotifierItem** (SNI) spec — the tray protocol used by KDE
Plasma, and by GNOME/others through an AppIndicator extension.

It is a **standalone binary**, not part of the daemon: it shares no code with
it and only reads the daemon's status socket (the same socket the Dolphin
overlay plugin uses). Every few seconds it sends the reserved `?status` line
and shows the one-word aggregate reply as an icon + tooltip:

| Daemon reply | Icon (themed) | Meaning |
|---|---|---|
| `syncing` | `emblem-synchronizing` | a transfer is in flight |
| `synced`  | `emblem-default`       | up to date |
| `failed`  | `dialog-error`         | a transfer burnt its retries |
| (no answer) | `network-offline`    | the daemon is not running |

The menu offers **Open mirror folder** (`xdg-open`, default `~/GoogleDrive`,
override with `IARAGON_MIRROR`) and **Quit**.

## Why Rust

The tray is the one piece that does not belong on the BEAM: an SNI item is a
small, always-idle GUI helper, and running it on the daemon's runtime would
mean a second Erlang VM just to paint an icon. It is a standalone binary with
no shared code, so it is free to use the right tool. Rust + [`ksni`] 0.3 gives
a ~2 MB static-ish binary that speaks DBus through pure-Rust **zbus** — no
libdbus C library to build or link. (The Dolphin plugin stays C++ only because
Dolphin's plugin ABI forces it; that constraint does not apply here.)

[`ksni`]: https://crates.io/crates/ksni

## Build & run

```sh
cd integrations/tray
cargo build --release        # -> target/release/iaragon-tray
./target/release/iaragon-tray &   # needs a running SNI host (tray)
```

Requires the Rust toolchain (`cargo`) to build; at runtime it needs a session
D-Bus and a tray host (KDE Plasma natively; GNOME via the AppIndicator
extension). No libdbus dev package is required — zbus is pure Rust.

Nothing installs the tray automatically yet — install.sh and the native
packages ship only the daemon. To run it as a per-user service, place the
binary and the unit template yourself, then enable it:

```sh
install -m755 target/release/iaragon-tray ~/.local/bin/
install -m644 ../../dist/iaragon-tray.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now iaragon-tray.service
```

## Tests

```sh
cargo test    # pure logic: status-word parsing, socket-path resolution
```

The parsing and socket-path resolution are unit-tested; they mirror the
daemon's own `status_server.resolve_socket_path` so the tray always looks
where the daemon actually binds.
