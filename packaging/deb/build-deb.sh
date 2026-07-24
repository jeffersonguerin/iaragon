#!/bin/sh
# build-deb.sh — wrap the self-contained release into a Debian package.
#
#   packaging/deb/build-deb.sh [BUNDLE_DIR]
#
# The .deb is the prebuilt bundle (its own BEAM runtime + the app) laid out
# under /usr, plus thin /usr/bin launchers and system-provided systemd USER
# units — so `apt install ./iaragon_*.deb` needs no Erlang/Gleam/rebar3/gcc,
# and (behind a signed apt repo) auto-updates through the system updater.
#
# BUNDLE_DIR: an already-staged iaragon-<os>-<arch>/ dir from
# build-release.sh. If omitted, one is built. Because the bundle carries
# native code (ERTS + NIFs), the .deb is per-(os, arch) and must be built on
# the oldest glibc you intend to support (same rule as build-release.sh).
#
# Version is derived from git (rolling release, no version tags): a monotone
# commit count plus the short SHA, which apt orders correctly.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT_DIR"

die() { echo "error: $1" >&2; exit 1; }
log() { echo "==> $1"; }
command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb is required to build a .deb"

BUNDLE="${1:-}"
if [ -z "$BUNDLE" ]; then
  log "building the self-contained bundle"
  ./scripts/build-release.sh "$ROOT_DIR/build/release" >/dev/null
  for d in "$ROOT_DIR"/build/release/iaragon-*/; do [ -d "$d" ] && BUNDLE="${d%/}"; done
fi
[ -n "$BUNDLE" ] && [ -x "$BUNDLE/bin/iaragon" ] || die "no runnable bundle at '${BUNDLE:-<unset>}'"

# Map the bundle arch to a Debian arch.
case "$(basename "$BUNDLE")" in
  *-x86_64)  DEB_ARCH=amd64 ;;
  *-aarch64) DEB_ARCH=arm64 ;;
  *)         die "unknown bundle arch in $(basename "$BUNDLE")" ;;
esac

VERSION="0.0.$(git rev-list --count HEAD)+g$(git rev-parse --short HEAD)"
PKGDIR="$ROOT_DIR/build/deb/iaragon_${VERSION}_${DEB_ARCH}"
DEB="$ROOT_DIR/build/deb/iaragon_${VERSION}_${DEB_ARCH}.deb"

log "staging $DEB_ARCH package $VERSION"
rm -rf "$PKGDIR"
mkdir -p "$PKGDIR/DEBIAN" \
         "$PKGDIR/usr/lib/iaragon" \
         "$PKGDIR/usr/bin" \
         "$PKGDIR/usr/lib/systemd/user"

# The bundle (otp/ app/ bin/) under /usr/lib/iaragon.
cp -a "$BUNDLE/otp" "$BUNDLE/app" "$BUNDLE/bin" "$PKGDIR/usr/lib/iaragon/"

# Thin /usr/bin launchers over the bundle's self-locating launchers.
for name in iaragon iaragon-login iaragon-doctor; do
  cat > "$PKGDIR/usr/bin/$name" <<EOF
#!/bin/sh
# iaragon launcher (packaged) — self-contained, no system Erlang needed.
exec /usr/lib/iaragon/bin/$name "\$@"
EOF
  chmod 0755 "$PKGDIR/usr/bin/$name"
done

# systemd USER units (system-provided: every user can `systemctl --user enable`).
cat > "$PKGDIR/usr/lib/systemd/user/iaragon.service" <<'EOF'
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
ExecStart=/usr/bin/iaragon
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
cat > "$PKGDIR/usr/lib/systemd/user/iaragon-doctor.service" <<'EOF'
[Unit]
Description=iaragon — health check (iaragon-doctor)
Documentation=https://github.com/jeffersonguerin/iaragon

[Service]
Type=oneshot
ExecStart=/usr/bin/iaragon-doctor
EOF
cat > "$PKGDIR/usr/lib/systemd/user/iaragon-doctor.timer" <<'EOF'
[Unit]
Description=iaragon — daily health check

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF

INSTALLED_KB=$(du -sk "$PKGDIR/usr" | cut -f1)
cat > "$PKGDIR/DEBIAN/control" <<EOF
Package: iaragon
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: Jefferson Guerin <jeffersonguerin@users.noreply.github.com>
Installed-Size: $INSTALLED_KB
Section: utils
Priority: optional
Recommends: inotify-tools
Homepage: https://github.com/jeffersonguerin/iaragon
Description: Bidirectional Google Drive sync daemon (Mirror mode) for Linux
 iaragon keeps a full, browsable local copy of your Google Drive in sync in
 both directions, like Google Drive for Desktop's Mirror mode. This package
 is self-contained: it bundles its own BEAM runtime, so no Erlang, Gleam,
 rebar3 or C compiler is required on the system. inotify-tools is recommended
 for instant local-change detection (the daemon falls back to polling
 without it).
EOF

# Ship the units read-only; everything root-owned regardless of build uid.
chmod -R u+rwX,go+rX "$PKGDIR/usr/lib/systemd"
log "building $DEB"
dpkg-deb --root-owner-group --build "$PKGDIR" "$DEB" >/dev/null

SIZE=$(du -sh "$DEB" | cut -f1)
cat <<EOF

==> built $DEB ($SIZE)

  Install (no toolchain needed):
    sudo apt install ./$(basename "$DEB")     # or: sudo dpkg -i ./$(basename "$DEB")
  Then, per user:
    systemctl --user enable --now iaragon.service
    loginctl enable-linger "\$USER"            # keep syncing after logout
EOF
