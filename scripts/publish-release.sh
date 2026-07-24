#!/bin/sh
# publish-release.sh — publish the self-contained release to GitHub.
#
#   ./scripts/publish-release.sh
#
# Local CI is githook-based (no remote pipeline), so releases are cut by a
# maintainer running this on a build host — once per architecture you ship,
# on a machine with the OLDEST glibc you intend to support (see
# build-release.sh for why the tarball is per-(os, arch)).
#
# It builds the bundle with build-release.sh and uploads it to a single
# rolling GitHub release tagged `latest`, which install.sh consumes via the
# TAG path `releases/download/latest/iaragon-linux-<arch>.tar.gz`. The
# `latest` tag is a DISTRIBUTION POINTER, not a version tag — the
# rolling-release rule (no version tags, no changelog) still holds; there is
# exactly one moving release and `--clobber` replaces its asset in place.
# The release must NOT be a prerelease or a draft: GitHub's
# `releases/latest` alias skips those entirely, and even the tag path 404s
# for drafts.
#
# Requires the GitHub CLI `gh`, authenticated (`gh auth login`) with a token
# that can create releases and upload assets on this repo. Nothing here talks
# to GitHub except gh.
#
# Env:
#   IARAGON_RELEASE_TAG   the rolling tag to publish under (default: latest)
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

TAG="${IARAGON_RELEASE_TAG:-latest}"

have() { command -v "$1" >/dev/null 2>&1; }
die()  { echo "error: $1" >&2; exit 1; }
log()  { echo "==> $1"; }

have gh || die "the GitHub CLI 'gh' is required (authenticate with: gh auth login)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"

# Build the bundle into a CLEAN output dir, so a stale tarball from an
# earlier run (e.g. a different REL_NAME) can never be picked up and
# published instead of the fresh build.
log "building the self-contained release"
OUT="$ROOT_DIR/build/release"
rm -rf "$OUT"
./scripts/build-release.sh "$OUT" >/dev/null
tarball=""
for f in "$OUT"/iaragon-*.tar.gz; do [ -f "$f" ] && tarball="$f"; done
[ -n "$tarball" ] || die "build-release.sh produced no tarball in $OUT"
log "built $(basename "$tarball")"

# Ensure the rolling release exists (create it once, pinned to this commit),
# then replace this arch's asset in place. Other arches keep their assets.
# Plain release on purpose — NEVER --prerelease/--draft: GitHub's
# releases/latest alias ignores prereleases and drafts, which would 404 the
# installer's download and silently push every user onto the source build.
if ! gh release view "$TAG" >/dev/null 2>&1; then
  log "creating the rolling '$TAG' release"
  gh release create "$TAG" \
    --title "iaragon (rolling)" \
    --notes "Rolling self-contained release, installed by install.sh. This is a moving distribution pointer, not a versioned release." \
    --target "$(git rev-parse HEAD)"
fi

log "uploading $(basename "$tarball") to '$TAG' (replacing any existing asset)"
gh release upload "$TAG" "$tarball" --clobber

log "published: $(gh release view "$TAG" --json url --jq .url 2>/dev/null || echo "release '$TAG'")"
