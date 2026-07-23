#!/bin/sh
# iaragon installer — build from source, install a per-user daemon.
#
#   curl -sSL https://raw.githubusercontent.com/jeffersonguerin/iaragon/main/install.sh | sh
#
# No root is needed for iaragon itself (it installs under ~/.local); root is
# used only to install build tools through your system package manager, and
# only when they are missing. Everything is overridable by environment:
#
#   IARAGON_REF     git ref to build (default: main)
#   IARAGON_REPO    clone URL (default: the GitHub repo)
#   IARAGON_PREFIX  install prefix (default: ~/.local)
#   GLEAM_VERSION   Gleam to bootstrap if absent (default: 1.17.0)
#   IARAGON_NO_SUDO set to 1 to never call sudo (fail instead if a dep is missing)
#
# Honest about its limits: the daemon needs Erlang/OTP >= 26 at RUNTIME. If
# your distro ships an older Erlang, this script stops and tells you how to
# get a newer one rather than installing something that would crash on first
# use.
set -eu

REPO="${IARAGON_REPO:-https://github.com/jeffersonguerin/iaragon.git}"
REF="${IARAGON_REF:-main}"
PREFIX="${IARAGON_PREFIX:-$HOME/.local}"
GLEAM_VERSION="${GLEAM_VERSION:-1.17.0}"

LIBDIR="$PREFIX/lib/iaragon"
BINDIR="$PREFIX/bin"
UNITDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# --- output helpers ---------------------------------------------------------
if [ -t 1 ]; then
  C_INFO='\033[1;34m'; C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_OFF='\033[0m'
else
  C_INFO=''; C_WARN=''; C_ERR=''; C_OFF=''
fi
log()  { printf '%b==>%b %s\n' "$C_INFO" "$C_OFF" "$1"; }
warn() { printf '%bwarning:%b %s\n' "$C_WARN" "$C_OFF" "$1" >&2; }
die()  { printf '%berror:%b %s\n' "$C_ERR" "$C_OFF" "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- privilege + package manager -------------------------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if [ "${IARAGON_NO_SUDO:-0}" = "1" ]; then
    SUDO=""
  elif have sudo; then
    SUDO="sudo"
  fi
fi

PM=""
detect_pm() {
  if   have apt-get; then PM="apt"
  elif have dnf;     then PM="dnf"
  elif have pacman;  then PM="pacman"
  elif have zypper;  then PM="zypper"
  elif have apk;     then PM="apk"
  elif have brew;    then PM="brew"
  else PM="none"
  fi
}

# pkg_install <generic-names...> — best-effort, never fatal on its own; the
# per-tool checks that follow decide whether a still-missing tool is fatal.
pkg_install() {
  [ "$PM" = "none" ] && { warn "no known package manager; skipping install of: $*"; return 0; }
  log "installing via $PM: $*"
  case "$PM" in
    apt)    $SUDO apt-get update -qq || true; $SUDO apt-get install -y "$@" || true ;;
    dnf)    $SUDO dnf install -y "$@" || true ;;
    pacman) $SUDO pacman -Sy --needed --noconfirm "$@" || true ;;
    zypper) $SUDO zypper install -y "$@" || true ;;
    apk)    $SUDO apk add "$@" || true ;;
    brew)   brew install "$@" || true ;;
  esac
}

# Map a generic dependency to this PM's package name(s), then install it.
pkg_for() {
  dep="$1"
  case "$PM:$dep" in
    *:cc)             case "$PM" in apt) pkg_install gcc ;; pacman) pkg_install gcc ;; apk) pkg_install build-base ;; *) pkg_install gcc ;; esac ;;
    *:make)           case "$PM" in apk) pkg_install make ;; *) pkg_install make ;; esac ;;
    *:git)            pkg_install git ;;
    *:curl)           pkg_install curl ;;
    apt:erlang)       pkg_install erlang-nox ;;
    pacman:erlang)    pkg_install erlang-nox ;;
    *:erlang)         pkg_install erlang ;;
    apt:rebar3)       pkg_install rebar3 ;;
    pacman:rebar3)    pkg_install rebar3 ;;
    *:rebar3)         pkg_install rebar3 ;;
    apt:inotify)      pkg_install inotify-tools ;;
    *:inotify)        pkg_install inotify-tools ;;
    *) : ;;
  esac
}

# --- toolchain checks -------------------------------------------------------
otp_release() {
  have erl || return 1
  erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt()' 2>/dev/null
}

otp_ok() {
  rel="$(otp_release 2>/dev/null || true)"
  [ -n "$rel" ] || return 1
  major="${rel%%.*}"
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -ge 26 ]
}

ensure_erlang() {
  if otp_ok; then
    log "Erlang/OTP $(otp_release) present"
    return 0
  fi
  if have erl; then
    warn "Erlang/OTP $(otp_release) is older than the required 26"
  fi
  pkg_for erlang
  if otp_ok; then
    log "Erlang/OTP $(otp_release) present"
    return 0
  fi
  # We refuse to proceed with an Erlang that would crash at runtime.
  cat >&2 <<EOF
$(printf '%berror:%b' "$C_ERR" "$C_OFF") iaragon needs Erlang/OTP >= 26 at runtime, and one could not be
installed automatically$( [ -n "${1:-}" ] && printf ' (found: %s)' "$1" ).

Install a recent Erlang, then re-run this script. Options:
  * kerl / asdf (any distro):   https://github.com/kerl/kerl
  * a prebuilt OTP tarball (e.g. Ubuntu 24.04):
      curl -fsSLO https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-27.3.4.14.tar.gz
      tar xzf OTP-27.3.4.14.tar.gz && (cd OTP-27.3.4.14 && ./Install -minimal "\$PWD")
      export PATH="\$PWD/OTP-27.3.4.14/bin:\$PATH"
EOF
  exit 1
}

gleam_ok() { have gleam; }

# Bootstrap Gleam from the official musl static binary on GitHub releases.
ensure_gleam() {
  if gleam_ok; then
    log "Gleam $(gleam --version 2>/dev/null | awk '{print $NF}') present"
    return 0
  fi
  # brew has a first-class gleam package; prefer it when present.
  if [ "$PM" = "brew" ]; then
    pkg_install gleam
    gleam_ok && { log "Gleam present"; return 0; }
  fi
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  gtarget="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) gtarget="aarch64-unknown-linux-musl" ;;
    *) die "no prebuilt Gleam for architecture '$arch'; install Gleam manually and re-run" ;;
  esac
  url="https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-${gtarget}.tar.gz"
  log "bootstrapping Gleam $GLEAM_VERSION ($gtarget)"
  mkdir -p "$BINDIR"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$url" -o "$tmp/gleam.tar.gz" || die "download failed: $url"
  tar xzf "$tmp/gleam.tar.gz" -C "$tmp" || die "could not extract Gleam tarball"
  install -m 0755 "$tmp/gleam" "$BINDIR/gleam" || die "could not install gleam to $BINDIR"
  rm -rf "$tmp"; trap - EXIT
  PATH="$BINDIR:$PATH"; export PATH
  gleam_ok || die "Gleam still not runnable after bootstrap"
  log "Gleam $(gleam --version 2>/dev/null | awk '{print $NF}') installed to $BINDIR"
}

# rebar3 is needed to compile the Erlang dep behind filespy (fs).
ensure_rebar3() {
  have rebar3 && { log "rebar3 present"; return 0; }
  pkg_for rebar3
  have rebar3 && { log "rebar3 present"; return 0; }
  log "bootstrapping rebar3 (escript) to $BINDIR"
  mkdir -p "$BINDIR"
  curl -fsSL "https://github.com/erlang/rebar3/releases/latest/download/rebar3" -o "$BINDIR/rebar3" \
    || die "could not download rebar3"
  chmod +x "$BINDIR/rebar3"
  PATH="$BINDIR:$PATH"; export PATH
  have rebar3 || die "rebar3 still not runnable after bootstrap"
}

# --- go ---------------------------------------------------------------------
detect_pm
[ "$PM" = "none" ] && warn "no supported package manager detected; assuming build tools are already present"
mkdir -p "$BINDIR"
case ":$PATH:" in *":$BINDIR:"*) : ;; *) PATH="$BINDIR:$PATH"; export PATH ;; esac

log "checking build prerequisites"
have git  || pkg_for git
have git  || die "git is required"
have curl || pkg_for curl
have curl || die "curl is required"
have cc || have gcc || pkg_for cc
have cc || have gcc || die "a C compiler is required (sqlight's NIF); install gcc/clang and re-run"
have make || pkg_for make
have make || die "make is required (sqlight's NIF)"

ensure_erlang
ensure_gleam
ensure_rebar3

# inotify-tools is optional: without it the daemon falls back to polling.
if have inotifywait; then
  log "inotify-tools present (real inotify watcher)"
else
  pkg_for inotify
  have inotifywait || warn "inotify-tools missing — the daemon will use the polling watcher (fine, just less instant)"
fi

# --- fetch + build ----------------------------------------------------------
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
log "cloning $REPO@$REF"
if ! git clone --depth 1 --branch "$REF" "$REPO" "$work/src" 2>/dev/null; then
  # Shallow branch clone fails for a commit SHA or a tag; fall back to a full
  # clone and an explicit checkout.
  git clone "$REPO" "$work/src"
  git -C "$work/src" checkout "$REF"
fi
cd "$work/src"

log "building release (gleam export erlang-shipment)"
gleam export erlang-shipment

# --- install ----------------------------------------------------------------
log "installing to $LIBDIR"
rm -rf "$LIBDIR"
mkdir -p "$(dirname "$LIBDIR")"
cp -a build/erlang-shipment "$LIBDIR"

log "installing launchers to $BINDIR"
# Bake in the directory where erl was found, so the launchers work under the
# minimal PATH of a systemd user service (or any non-login shell) even when
# Erlang lives outside /usr/bin.
ERL_DIR="$(dirname "$(command -v erl)")"
cat > "$BINDIR/iaragon" <<EOF
#!/bin/sh
# iaragon sync daemon launcher (generated by install.sh)
PATH="$ERL_DIR:\$PATH"; export PATH
exec "$LIBDIR/entrypoint.sh" run "\$@"
EOF
chmod +x "$BINDIR/iaragon"

cat > "$BINDIR/iaragon-login" <<EOF
#!/bin/sh
# iaragon interactive OAuth login launcher (generated by install.sh)
PATH="$ERL_DIR:\$PATH"; export PATH
exec erl -pa "$LIBDIR"/*/ebin -noshell -eval 'iaragon@login:main(), halt(0)' -extra "\$@"
EOF
chmod +x "$BINDIR/iaragon-login"

# --- systemd user unit ------------------------------------------------------
if have systemctl; then
  log "installing systemd user unit to $UNITDIR/iaragon.service"
  mkdir -p "$UNITDIR"
  cat > "$UNITDIR/iaragon.service" <<EOF
[Unit]
Description=iaragon — bidirectional Google Drive sync daemon
Documentation=https://github.com/jeffersonguerin/iaragon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BINDIR/iaragon
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload 2>/dev/null || true
else
  warn "systemctl not found — skipping systemd unit (start the daemon with 'iaragon')"
fi

# --- done -------------------------------------------------------------------
cat <<EOF

$(printf '%b==>%b' "$C_INFO" "$C_OFF") iaragon installed.

Next steps:
  1. Make sure $BINDIR is on your PATH:
       case ":\$PATH:" in *":$BINDIR:"*) ;; *) echo 'export PATH="$BINDIR:\$PATH"' >> ~/.profile ;; esac
  2. Create ~/.config/iaragon/oauth_client.json from a Google Cloud
     "Desktop app" OAuth client:
       {"client_id": "...", "client_secret": "..."}
  3. Log in (opens your browser):
       iaragon-login
  4. Start the daemon:
       systemctl --user enable --now iaragon.service   # supervised, or
       iaragon                                          # foreground
     To keep it running after logout: loginctl enable-linger "\$USER"

Your mirror will live at ~/GoogleDrive.
EOF
