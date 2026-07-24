#!/bin/sh
# publish-apt.sh — build the current .deb and publish it to the signed apt
# repository, so users update through `apt upgrade` like any other package.
#
#   scripts/publish-apt.sh [DEB_PATH]
#
# DEB_PATH: an already-built .deb. If omitted, packaging/deb/build-deb.sh is
# run first (which builds the self-contained bundle when needed).
#
# The apt repository is a SEPARATE git repository (default:
# github.com/<owner>/iaragon-apt served via raw.githubusercontent.com) on
# purpose: every publish commits a ~65 MB binary, and git history never
# forgets — inside the source repo that would bloat every clone forever,
# while the dedicated repo quarantines the weight and can be squashed or
# reset without touching source history (apt clients only read the tip).
#
# Retention: only the newest KEEP debs stay in pool/ (older ones remain in
# the apt repo's git history until that history is squashed). GitHub's hard
# limit is 100 MB per file; the bundle sits ~65 MB, so headroom is real but
# not infinite — the size is printed on every publish.
#
# Signing: metadata is signed (InRelease + Release.gpg) with the dedicated
# key in IARAGON_APT_GNUPGHOME. The private key lives only on the
# maintainer's machine; nothing under the repo tree ever contains it.
#
# Overridable by environment:
#   IARAGON_APT_DIR        checkout of the apt repository
#                          (default: <this repo>/../iaragon-apt)
#   IARAGON_APT_GNUPGHOME  GNUPGHOME holding the signing key
#                          (default: ~/.local/share/iaragon-apt-signing)
#   IARAGON_APT_KEY        signing key uid/fingerprint
#                          (default: "iaragon apt repository")
#   IARAGON_APT_KEEP       how many debs to keep in pool/ (default: 2)
#   IARAGON_APT_NO_PUSH    set to 1 to commit locally without pushing
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APT_DIR="${IARAGON_APT_DIR:-$ROOT_DIR/../iaragon-apt}"
SIGN_HOME="${IARAGON_APT_GNUPGHOME:-$HOME/.local/share/iaragon-apt-signing}"
KEY="${IARAGON_APT_KEY:-iaragon apt repository}"
KEEP="${IARAGON_APT_KEEP:-2}"

die() { echo "error: $1" >&2; exit 1; }
log() { echo "==> $1"; }

command -v apt-ftparchive >/dev/null 2>&1 || die "apt-ftparchive is required (apt-utils package)"
command -v gpg >/dev/null 2>&1 || die "gpg is required"
[ -d "$APT_DIR/.git" ] || die "no apt repo checkout at $APT_DIR (set IARAGON_APT_DIR)"
GNUPGHOME="$SIGN_HOME" gpg --list-secret-keys "$KEY" >/dev/null 2>&1 \
  || die "signing key '$KEY' not found in $SIGN_HOME (set IARAGON_APT_GNUPGHOME/IARAGON_APT_KEY)"

DEB="${1:-}"
if [ -z "$DEB" ]; then
  log "building the .deb"
  "$ROOT_DIR/packaging/deb/build-deb.sh" >/dev/null
  for f in "$ROOT_DIR"/build/deb/iaragon_*.deb; do DEB="$f"; done
fi
[ -f "$DEB" ] || die "no .deb at '${DEB:-<unset>}'"
log "publishing $(basename "$DEB") ($(du -h "$DEB" | cut -f1))"

POOL="$APT_DIR/pool/main/i/iaragon"
mkdir -p "$POOL" "$APT_DIR/dists/stable/main/binary-amd64"
cp "$DEB" "$POOL/"

# Retention: newest KEEP debs stay; the rest leave the tip (history keeps
# them until the apt repo history is squashed — see header).
ls -1t "$POOL"/iaragon_*.deb 2>/dev/null | tail -n +"$((KEEP + 1))" | while IFS= read -r old; do
  log "pruning $(basename "$old") from the pool tip"
  rm -f "$old"
done

cd "$APT_DIR"
apt-ftparchive packages pool > dists/stable/main/binary-amd64/Packages
gzip -k9f dists/stable/main/binary-amd64/Packages
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin=iaragon \
  -o APT::FTPArchive::Release::Label=iaragon \
  -o APT::FTPArchive::Release::Suite=stable \
  -o APT::FTPArchive::Release::Codename=stable \
  -o APT::FTPArchive::Release::Architectures=amd64 \
  -o APT::FTPArchive::Release::Components=main \
  -o "APT::FTPArchive::Release::Description=iaragon rolling apt repository" \
  release dists/stable > dists/stable/Release
GNUPGHOME="$SIGN_HOME" gpg --batch --yes --clearsign --digest-algo SHA512 \
  -u "$KEY" -o dists/stable/InRelease dists/stable/Release
GNUPGHOME="$SIGN_HOME" gpg --batch --yes -abs --digest-algo SHA512 \
  -u "$KEY" -o dists/stable/Release.gpg dists/stable/Release

VERSION=$(dpkg-deb -f "$DEB" Version 2>/dev/null || basename "$DEB")
git add -A
if git diff --cached --quiet; then
  log "nothing changed — repo already carries this build"
  exit 0
fi
git commit -q -m "Publish iaragon $VERSION"
if [ "${IARAGON_APT_NO_PUSH:-0}" = "1" ]; then
  log "committed locally (IARAGON_APT_NO_PUSH=1) — push when ready"
else
  git push -q origin main
  log "pushed — apt clients pick it up on their next 'apt update'"
fi
