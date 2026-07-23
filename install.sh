#!/bin/sh
# iaragon installer — build from source, install a per-user daemon.
#
#   curl -sSL https://raw.githubusercontent.com/jeffersonguerin/iaragon/main/install.sh | sh
#
# No root is needed for iaragon itself (it installs under ~/.local); root is
# used only to install build tools through your system package manager, and
# only when they are missing.
#
# No conflicts with your existing toolchain: any dependency already present —
# no matter how you installed it (apt, brew, kerl, asdf, a manual build) — is
# detected and KEPT. Nothing is ever reinstalled or duplicated. Only what is
# actually missing gets installed.
#
# Consistency of method: for the dependencies it does need to install, the
# package manager detected on your system is the single source for every one
# it can provide (apt -> everything from apt, brew -> everything from brew,
# ...). A direct binary download is used ONLY for a dependency your manager
# does not package (Gleam is not in the apt/dnf/zypper repositories), and the
# script says so out loud when it does.
#
# The script is transparent: before installing anything it prints a plan of
# what is present and what it will install (and how); it echoes the exact
# command it runs for each package; and it prints a summary at the end.
#
# Overridable by environment:
#   IARAGON_REF     git ref to build (default: main)
#   IARAGON_REPO    clone URL (default: the GitHub repo)
#   IARAGON_PREFIX  install prefix (default: ~/.local)
#   IARAGON_PM      force the package manager for MISSING deps, to match your
#                   toolchain (apt|dnf|pacman|zypper|apk|brew). Default: the
#                   first one detected. Present deps are kept regardless.
#   GLEAM_VERSION   Gleam to fetch if your manager has no package (default: 1.17.0)
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

# What gets installed this run, for the closing summary.
NEWLY=""

# --- output helpers ---------------------------------------------------------
if [ -t 1 ]; then
  C_INFO='\033[1;34m'; C_OK='\033[1;32m'; C_DIM='\033[2m'
  C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_OFF='\033[0m'
else
  C_INFO=''; C_OK=''; C_DIM=''; C_WARN=''; C_ERR=''; C_OFF=''
fi
log()  { printf '%b==>%b %s\n' "$C_INFO" "$C_OFF" "$1"; }
note() { printf '%bnote:%b %s\n' "$C_INFO" "$C_OFF" "$1"; }
warn() { printf '%bwarning:%b %s\n' "$C_WARN" "$C_OFF" "$1" >&2; }
die()  { printf '%berror:%b %s\n' "$C_ERR" "$C_OFF" "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
add_newly() { NEWLY="$NEWLY $1"; }

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
  # An explicit choice wins, so users can pin missing-dep installs to the same
  # manager their toolchain already uses.
  if [ -n "${IARAGON_PM:-}" ]; then PM="$IARAGON_PM"; return; fi
  if   have apt-get; then PM="apt"
  elif have dnf;     then PM="dnf"
  elif have pacman;  then PM="pacman"
  elif have zypper;  then PM="zypper"
  elif have apk;     then PM="apk"
  elif have brew;    then PM="brew"
  else PM="none"
  fi
}

# The exact command line pkg_install would run — shown to the user verbatim.
pm_cmdline() {
  case "$PM" in
    apt)    echo "${SUDO:+sudo }apt-get install -y $*" ;;
    dnf)    echo "${SUDO:+sudo }dnf install -y $*" ;;
    pacman) echo "${SUDO:+sudo }pacman -Sy --needed --noconfirm $*" ;;
    zypper) echo "${SUDO:+sudo }zypper install -y $*" ;;
    apk)    echo "${SUDO:+sudo }apk add $*" ;;
    brew)   echo "brew install $*" ;;
    *)      echo "(manually) install $*" ;;
  esac
}

# pkg_install <pkg...> — install through the detected manager, echoing the
# exact command first. Returns the real exit status so callers can fall back.
pkg_install() {
  [ "$PM" = "none" ] && { warn "no package manager detected; install manually: $*"; return 1; }
  printf '%b    $ %s%b\n' "$C_DIM" "$(pm_cmdline "$@")" "$C_OFF"
  case "$PM" in
    apt)    $SUDO apt-get update -qq >/dev/null 2>&1 || true; $SUDO apt-get install -y "$@" ;;
    dnf)    $SUDO dnf install -y "$@" ;;
    pacman) $SUDO pacman -Sy --needed --noconfirm "$@" ;;
    zypper) $SUDO zypper install -y "$@" ;;
    apk)    $SUDO apk add "$@" ;;
    brew)   brew install "$@" ;;
  esac
}

# Map a generic dependency to this manager's package name, then install it.
pkg_for() {
  case "$PM:$1" in
    apk:cc)        pkg_install build-base ;;
    *:cc)          pkg_install gcc ;;
    *:make)        pkg_install make ;;
    *:git)         pkg_install git ;;
    *:curl)        pkg_install curl ;;
    apt:erlang)    pkg_install erlang-nox ;;
    pacman:erlang) pkg_install erlang-nox ;;
    *:erlang)      pkg_install erlang ;;
    *:gleam)       pkg_install gleam ;;
    *:rebar3)      pkg_install rebar3 ;;
    *:inotify)     pkg_install inotify-tools ;;
    *) return 1 ;;
  esac
}

# --- toolchain probes -------------------------------------------------------
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
gleam_ok() { have gleam; }
gleam_ver() { gleam --version 2>/dev/null | awk '{print $NF}'; }
cc_ok() { have cc || have gcc; }

# --- ensure_* : install one dependency, method preserved -------------------
ensure_base() { # generic-dep  binary-to-check  human-name
  have "$2" && { log "$3: present"; return 0; }
  log "installing $3 via $PM"
  pkg_for "$1" || true
  have "$2" && { add_newly "$3($PM)"; log "$3: installed via $PM"; return 0; }
  die "$3 is required but could not be installed; install it and re-run"
}

ensure_erlang() {
  otp_ok && { log "Erlang/OTP $(otp_release): present"; return 0; }
  have erl && warn "Erlang/OTP $(otp_release) is older than the required 26 — replacing via $PM"
  log "installing Erlang via $PM"
  pkg_for erlang || true
  otp_ok && { add_newly "erlang($PM)"; log "Erlang/OTP $(otp_release): installed via $PM"; return 0; }
  cat >&2 <<EOF
$(printf '%berror:%b' "$C_ERR" "$C_OFF") iaragon needs Erlang/OTP >= 26 at runtime, and $PM could not
provide one$( have erl && printf ' (found OTP %s)' "$(otp_release)" ).

Install a recent Erlang, then re-run this script. Options:
  * kerl / asdf (any distro):   https://github.com/kerl/kerl
  * a prebuilt OTP tarball (e.g. Ubuntu 24.04):
      curl -fsSLO https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-27.3.4.14.tar.gz
      tar xzf OTP-27.3.4.14.tar.gz && (cd OTP-27.3.4.14 && ./Install -minimal "\$PWD")
      export PATH="\$PWD/OTP-27.3.4.14/bin:\$PATH"
EOF
  exit 1
}

ensure_gleam() {
  gleam_ok && { log "Gleam $(gleam_ver): present"; return 0; }
  # Method preserved: try the detected manager first.
  if [ "$PM" != "none" ]; then
    log "installing Gleam via $PM"
    pkg_for gleam || true
    gleam_ok && { add_newly "gleam($PM)"; log "Gleam $(gleam_ver): installed via $PM"; return 0; }
    note "$PM does not package Gleam — falling back to the official static binary (upstream's recommended install)"
  fi
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  gtarget="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) gtarget="aarch64-unknown-linux-musl" ;;
    *) die "no prebuilt Gleam for architecture '$arch'; install Gleam manually and re-run" ;;
  esac
  url="https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-${gtarget}.tar.gz"
  log "fetching Gleam $GLEAM_VERSION ($gtarget)"
  printf '%b    $ curl -fsSL %s%b\n' "$C_DIM" "$url" "$C_OFF"
  mkdir -p "$BINDIR"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$url" -o "$tmp/gleam.tar.gz" || die "download failed: $url"
  tar xzf "$tmp/gleam.tar.gz" -C "$tmp" || die "could not extract Gleam tarball"
  install -m 0755 "$tmp/gleam" "$BINDIR/gleam" || die "could not install gleam to $BINDIR"
  rm -rf "$tmp"; trap - EXIT
  PATH="$BINDIR:$PATH"; export PATH
  gleam_ok || die "Gleam still not runnable after install"
  add_newly "gleam(official binary -> $BINDIR)"
  log "Gleam $(gleam_ver): installed to $BINDIR"
}

# rebar3 is needed to compile the Erlang dep behind filespy (fs).
ensure_rebar3() {
  have rebar3 && { log "rebar3: present"; return 0; }
  if [ "$PM" != "none" ]; then
    log "installing rebar3 via $PM"
    pkg_for rebar3 || true
    have rebar3 && { add_newly "rebar3($PM)"; log "rebar3: installed via $PM"; return 0; }
    note "$PM does not package rebar3 — falling back to the official escript"
  fi
  url="https://github.com/erlang/rebar3/releases/latest/download/rebar3"
  log "fetching rebar3 (escript)"
  printf '%b    $ curl -fsSL %s%b\n' "$C_DIM" "$url" "$C_OFF"
  mkdir -p "$BINDIR"
  curl -fsSL "$url" -o "$BINDIR/rebar3" || die "could not download rebar3"
  chmod +x "$BINDIR/rebar3"
  PATH="$BINDIR:$PATH"; export PATH
  have rebar3 || die "rebar3 still not runnable after install"
  add_newly "rebar3(official escript -> $BINDIR)"
}

ensure_inotify() {
  have inotifywait && { log "inotify-tools: present"; return 0; }
  if [ "$PM" != "none" ]; then
    log "installing inotify-tools via $PM (optional; enables the instant watcher)"
    pkg_for inotify || true
    have inotifywait && { add_newly "inotify-tools($PM)"; log "inotify-tools: installed via $PM"; return 0; }
  fi
  warn "inotify-tools not available — the daemon will use the polling watcher (works, just less instant)"
}

# --- dependency plan (transparency) ----------------------------------------
plan_method() {
  case "$1" in
    gleam)  case "$PM" in
              brew) echo "via brew" ;;
              none) echo "official static binary" ;;
              *)    echo "via $PM if packaged, else official static binary" ;;
            esac ;;
    rebar3) [ "$PM" = none ] && echo "official escript" || echo "via $PM if packaged, else official escript" ;;
    *)      [ "$PM" = none ] && echo "MANUAL — no package manager detected" || echo "via $PM" ;;
  esac
}
plan_row() { # generic label present?
  if [ -n "$3" ]; then
    printf '    %-14s %bpresent%b\n' "$2" "$C_OK" "$C_OFF"
  else
    printf '    %-14s install: %s\n' "$2" "$(plan_method "$1")"
  fi
}

# --- go ---------------------------------------------------------------------
detect_pm
if [ "$PM" = "none" ]; then
  warn "no supported package manager detected (apt/dnf/pacman/zypper/apk/brew) — build tools must already be present"
else
  log "package manager: $PM${SUDO:+ (system packages installed with sudo)}"
fi
mkdir -p "$BINDIR"
case ":$PATH:" in *":$BINDIR:"*) : ;; *) PATH="$BINDIR:$PATH"; export PATH ;; esac

# Snapshot presence BEFORE touching anything, then show the plan.
p_git=$(have git && echo x || true)
p_curl=$(have curl && echo x || true)
p_cc=$(cc_ok && echo x || true)
p_make=$(have make && echo x || true)
p_erl=$(otp_ok && echo x || true)
p_gleam=$(gleam_ok && echo x || true)
p_rebar=$(have rebar3 && echo x || true)
p_inotify=$(have inotifywait && echo x || true)

log "dependency plan — present items are kept, missing ones installed for you:"
plan_row git     "git"           "$p_git"
plan_row curl    "curl"          "$p_curl"
plan_row cc      "C compiler"    "$p_cc"
plan_row make    "make"          "$p_make"
plan_row erlang  "Erlang/OTP26+" "$p_erl"
plan_row gleam   "Gleam"         "$p_gleam"
plan_row rebar3  "rebar3"        "$p_rebar"
plan_row inotify "inotify-tools" "$p_inotify"
echo

log "resolving dependencies"
ensure_base git  git  "git"
ensure_base curl curl "curl"
# The C compiler is either cc or gcc; check both, install the manager's gcc.
if cc_ok; then log "C compiler: present"; else pkg_for cc || true; cc_ok && add_newly "gcc($PM)" || die "a C compiler is required (sqlight's NIF); install gcc/clang and re-run"; fi
ensure_base make make "make"
ensure_erlang
ensure_gleam
ensure_rebar3
ensure_inotify

if [ -n "$NEWLY" ]; then
  log "installed:$NEWLY"
else
  log "all dependencies were already present"
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
