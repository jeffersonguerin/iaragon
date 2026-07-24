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
#   REBAR3_VERSION  pin the rebar3 release to fetch if your manager has none
#                   (default: unset -> latest)
#   IARAGON_NO_SUDO set to 1 to never call sudo (fail instead if a dep is missing)
#
# Honest about its limits: the daemon needs Erlang/OTP >= 29 at RUNTIME. If
# your distro ships an older Erlang, this script stops and tells you how to
# get a newer one rather than installing something that would crash on first
# use.
#
# Trust model: packages come from your package manager (its own signing).
# The two direct downloads (the Gleam binary, the rebar3 escript) come over
# HTTPS from the projects' official GitHub release URLs; transport authenticity
# is TLS, and there is no additional pinned-checksum verification. If you need
# that, install Gleam/rebar3 yourself first (they will be detected and kept).
#
# All the imperative work lives in main(), invoked on the very last line, so a
# truncated `curl | sh` download never executes a partial script.
set -eu

REPO="${IARAGON_REPO:-https://github.com/jeffersonguerin/iaragon.git}"
REF="${IARAGON_REF:-main}"
PREFIX="${IARAGON_PREFIX:-$HOME/.local}"
GLEAM_VERSION="${GLEAM_VERSION:-1.17.0}"

# Guard the install prefix before it feeds an `rm -rf` and gets interpolated
# (unquoted) into the generated launcher/unit files: it must be an absolute
# path, never the filesystem root, and free of characters that could break or
# inject into those files (whitespace, quotes, backslash, control chars).
case "$PREFIX" in
  /)  echo "error: IARAGON_PREFIX must not be '/'" >&2; exit 1 ;;
  /*) : ;;
  *)  echo "error: IARAGON_PREFIX must be an absolute path (got '$PREFIX')" >&2; exit 1 ;;
esac
case "$PREFIX" in
  *[!A-Za-z0-9._/-]*)
    echo "error: IARAGON_PREFIX may only contain [A-Za-z0-9._/-] (got '$PREFIX')" >&2; exit 1 ;;
esac

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
  if [ -n "${IARAGON_PM:-}" ]; then
    case "$IARAGON_PM" in
      apt|dnf|pacman|zypper|apk|brew) PM="$IARAGON_PM" ;;
      *) die "IARAGON_PM must be one of apt|dnf|pacman|zypper|apk|brew (got '$IARAGON_PM')" ;;
    esac
    return
  fi
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
# The floor is 29, the current OTP branch. It used to be 26, which was wrong on
# its own terms: no OTP 26 release ever carried the CVE-2026-48856 fix for
# httpc (only the 27/28/29 branches got it), so anyone left on 26 had no
# upgrade path within their branch for a credential-leak fix in the very HTTP
# client this daemon runs on. Rather than track the oldest still-patchable
# branch, the requirement is simply the current one — a daemon holding a Google
# OAuth token has no business running on a runtime nobody is fixing anymore.
otp_ok() {
  rel="$(otp_release 2>/dev/null || true)"
  [ -n "$rel" ] || return 1
  major="${rel%%.*}"
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -ge 29 ]
}
# CVE-2026-48856: httpc forwarded Authorization/Cookie/... verbatim when
# following a redirect to a different host or port. iaragon does not depend on
# the runtime for that guarantee — its downloader follows redirects itself and
# strips the credential across origins, and every other Drive call goes through
# gleam_httpc, which does not follow redirects at all — so this is a warning,
# never a blocker. It is reported because the daemon holds a Google OAuth token
# and the operator should know the Erlang underneath is missing a security fix.
# Patched in inets 9.7.1 (OTP 29.0.2); the 27 and 28 branches got it as 9.3.2.6
# and 9.6.2.2, but otp_ok already refuses those, so 9.7.1 is the only bar left
# to check — it still catches an OTP 29.0 or 29.0.1 that predates the fix.
# Version parts are compared numerically, not lexically: "9.10" outranks "9.7".
inets_patched() {
  have erl || return 1
  verdict="$(erl -noshell -eval '
    _ = application:load(inets),
    {ok, Vsn} = application:get_key(inets, vsn),
    Parts = [list_to_integer(P) || P <- string:lexemes(Vsn, ".")],
    io:format("~s", [case Parts >= [9,7,1] of true -> "yes"; false -> "no" end]),
    halt().' 2>/dev/null)"
  [ "$verdict" = "yes" ]
}
warn_if_inets_vulnerable() {
  inets_patched && return 0
  warn "Erlang/OTP $(otp_release)'s httpc is missing the CVE-2026-48856 fix (credentials forwarded across redirects) — iaragon strips the token itself and is not exposed, but updating Erlang is still advisable"
}
gleam_ok() { have gleam; }
gleam_ver() { gleam --version 2>/dev/null | awk '{print $NF}'; }
# The project needs Gleam >= 1.17 (see gleam.toml). An older Gleam would fail
# `gleam export erlang-shipment` with a confusing error, so gate it like OTP.
GLEAM_MIN_MAJOR=1
GLEAM_MIN_MINOR=17
gleam_new_enough() {
  v="$(gleam_ver)"; [ -n "$v" ] || return 1
  maj="${v%%.*}"; rest="${v#*.}"; min="${rest%%.*}"
  case "$maj" in ''|*[!0-9]*) return 1 ;; esac
  case "$min" in ''|*[!0-9]*) min=0 ;; esac
  [ "$maj" -gt "$GLEAM_MIN_MAJOR" ] && return 0
  [ "$maj" -eq "$GLEAM_MIN_MAJOR" ] && [ "$min" -ge "$GLEAM_MIN_MINOR" ]
}
cc_ok() { have cc || have gcc; }

# rebar3 must match the runtime: OTP 29 (this script's floor) needs
# rebar3 >= 3.27.0 — older rebar3 dies with `rebar_uri:parse undef` the moment
# it runs, so a stale distro rebar3 (Debian/Ubuntu ship 3.19-ish) or one
# already on PATH would fail the build cryptically on the very OTP we require.
# Gate it like Gleam and OTP.
REBAR3_MIN_MAJOR=3
REBAR3_MIN_MINOR=27
rebar3_ver() { rebar3 version 2>/dev/null | awk '{print $2}'; }
rebar3_new_enough() {
  v="$(rebar3_ver)"; [ -n "$v" ] || return 1
  maj="${v%%.*}"; rest="${v#*.}"; min="${rest%%.*}"
  case "$maj" in ''|*[!0-9]*) return 1 ;; esac
  case "$min" in ''|*[!0-9]*) min=0 ;; esac
  [ "$maj" -gt "$REBAR3_MIN_MAJOR" ] && return 0
  [ "$maj" -eq "$REBAR3_MIN_MAJOR" ] && [ "$min" -ge "$REBAR3_MIN_MINOR" ]
}

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
  if have erl; then
    # Present but too old. Do NOT install a distro Erlang over the user's
    # existing toolchain (kerl/asdf/manual): it would duplicate it and, on the
    # distros that ship an old Erlang, still not reach 26. Send them to a real
    # upgrade path instead.
    warn "Erlang/OTP $(otp_release) is older than the required 29 — keeping your install untouched"
  else
    log "installing Erlang via $PM"
    pkg_for erlang || true
    otp_ok && { add_newly "erlang($PM)"; log "Erlang/OTP $(otp_release): installed via $PM"; return 0; }
  fi
  cat >&2 <<EOF
$(printf '%berror:%b' "$C_ERR" "$C_OFF") iaragon needs Erlang/OTP >= 29 at runtime, and $PM could not
provide one$( { have erl && printf ' (found OTP %s)' "$(otp_release)"; } || true ).

Install a recent Erlang, then re-run this script. Options:
  * kerl / asdf (any distro):   https://github.com/kerl/kerl
  * a prebuilt OTP tarball (e.g. Ubuntu 24.04):
      curl -fsSLO https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-29.0.3.tar.gz
      tar xzf OTP-29.0.3.tar.gz && (cd OTP-29.0.3 && ./Install -minimal "\$PWD")
      export PATH="\$PWD/OTP-29.0.3/bin:\$PATH"
EOF
  exit 1
}

ensure_gleam() {
  if gleam_ok; then
    gleam_new_enough && { log "Gleam $(gleam_ver): present"; return 0; }
    die "Gleam $(gleam_ver) is older than the required ${GLEAM_MIN_MAJOR}.${GLEAM_MIN_MINOR}; upgrade it and re-run (your install is left untouched)"
  fi
  # Method preserved: try the detected manager first.
  if [ "$PM" != "none" ]; then
    log "installing Gleam via $PM"
    pkg_for gleam || true
    if gleam_ok && gleam_new_enough; then
      add_newly "gleam($PM)"; log "Gleam $(gleam_ver): installed via $PM"; return 0
    fi
    note "$PM has no suitable Gleam (>= ${GLEAM_MIN_MAJOR}.${GLEAM_MIN_MINOR}) — falling back to the official static binary (upstream's recommended install)"
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
  # A rebar3 already on PATH is kept ONLY if it is new enough for OTP 29;
  # an older one (common on distros) would crash the build on the very OTP
  # this script requires, so fall through to the official escript rather
  # than accept it. The user's own rebar3 is never modified — the fresh
  # escript lands in BINDIR, which precedes PATH for the build.
  if have rebar3; then
    rebar3_new_enough && { log "rebar3 $(rebar3_ver): present"; return 0; }
    note "rebar3 $(rebar3_ver) predates ${REBAR3_MIN_MAJOR}.${REBAR3_MIN_MINOR} (needed for OTP 29) — fetching the official escript into $BINDIR (your rebar3 is left untouched)"
  elif [ "$PM" != "none" ]; then
    log "installing rebar3 via $PM"
    pkg_for rebar3 || true
    if have rebar3 && rebar3_new_enough; then
      add_newly "rebar3($PM)"; log "rebar3 $(rebar3_ver): installed via $PM"; return 0
    fi
    have rebar3 \
      && note "$PM's rebar3 $(rebar3_ver) predates ${REBAR3_MIN_MAJOR}.${REBAR3_MIN_MINOR} (needed for OTP 29) — falling back to the official escript" \
      || note "$PM does not package rebar3 — falling back to the official escript"
  fi
  if [ -n "${REBAR3_VERSION:-}" ]; then
    url="https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3"
  else
    url="https://github.com/erlang/rebar3/releases/latest/download/rebar3"
  fi
  log "fetching rebar3 (escript)"
  printf '%b    $ curl -fsSL %s%b\n' "$C_DIM" "$url" "$C_OFF"
  mkdir -p "$BINDIR"
  # Download to a temp path and move into place only on success, so a dropped
  # connection never leaves a truncated rebar3 behind.
  rtmp="$(mktemp)"
  trap 'rm -f "$rtmp"' EXIT
  curl -fsSL "$url" -o "$rtmp" || die "could not download rebar3"
  chmod +x "$rtmp"
  mv "$rtmp" "$BINDIR/rebar3"
  trap - EXIT
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
main() {
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
# Version-aware like p_erl: a present-but-too-old rebar3 (crashes on OTP 29)
# must show in the plan as "install", not "present".
p_rebar=$(rebar3_new_enough && echo x || true)
p_inotify=$(have inotifywait && echo x || true)

log "dependency plan — present items are kept, missing ones installed for you:"
plan_row git     "git"           "$p_git"
plan_row curl    "curl"          "$p_curl"
plan_row cc      "C compiler"    "$p_cc"
plan_row make    "make"          "$p_make"
plan_row erlang  "Erlang/OTP29+" "$p_erl"
plan_row gleam   "Gleam"         "$p_gleam"
plan_row rebar3  "rebar3"        "$p_rebar"
plan_row inotify "inotify-tools" "$p_inotify"
echo

log "resolving dependencies"
ensure_base git  git  "git"
ensure_base curl curl "curl"
# The C compiler is either cc or gcc; check both, install the manager's gcc.
if cc_ok; then
  log "C compiler: present"
else
  log "installing a C compiler via $PM"
  pkg_for cc || true
  if cc_ok; then
    add_newly "gcc($PM)"; log "C compiler: installed via $PM"
  else
    die "a C compiler is required (sqlight's NIF); install gcc/clang and re-run"
  fi
fi
ensure_base make make "make"
ensure_erlang
warn_if_inets_vulnerable
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

cat > "$BINDIR/iaragon-doctor" <<EOF
#!/bin/sh
# iaragon health check launcher (generated by install.sh)
PATH="$ERL_DIR:\$PATH"; export PATH
exec erl -pa "$LIBDIR"/*/ebin -noshell -eval 'iaragon@doctor:main(), halt(0)' -extra "\$@"
EOF
chmod +x "$BINDIR/iaragon-doctor"

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
# Anti-crash-loop: give up after 5 exits in 5 minutes (unit -> failed,
# visible to iaragon-doctor) rather than hammering the Drive API forever.
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$BINDIR/iaragon
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  # Optional daily health check: a timer'd doctor run lands in the user
  # journal and shows the unit as failed when a check fails (e.g. a dead
  # refresh token). Passive — it never touches the running daemon. Installed
  # but NOT enabled; opting in is one command (see the closing notes).
  cat > "$UNITDIR/iaragon-doctor.service" <<EOF
[Unit]
Description=iaragon — health check (iaragon-doctor)
Documentation=https://github.com/jeffersonguerin/iaragon

[Service]
Type=oneshot
ExecStart=$BINDIR/iaragon-doctor
EOF
  cat > "$UNITDIR/iaragon-doctor.timer" <<EOF
[Unit]
Description=iaragon — daily health check

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
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
  5. Check health any time with: iaragon-doctor
     Optional daily check in the journal:
       systemctl --user enable --now iaragon-doctor.timer

Your mirror will live at ~/GoogleDrive.
EOF
}

main "$@"
