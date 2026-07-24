# Packaging

Native packages for iaragon. All install a per-user daemon and system-provided
systemd **user** units, so after install each user runs
`systemctl --user enable --now iaragon.service` (and `loginctl enable-linger`
to keep syncing after logout).

| Format | Recipe | Runtime model | Verified |
|---|---|---|---|
| Debian/Ubuntu `.deb` | [`deb/build-deb.sh`](deb/build-deb.sh) | Bundles its own BEAM (self-contained) | Built + `dpkg -i`/run/remove tested |
| Arch `PKGBUILD` (AUR) | [`aur/PKGBUILD`](aur/PKGBUILD) | Builds from source, depends on distro `erlang` | Recipe (build it on Arch) |
| Fedora/RHEL `.rpm` | [`rpm/iaragon.spec`](rpm/iaragon.spec) | Bundles its own BEAM (self-contained) | Recipe (build it with `rpmbuild`) |

Two runtime models on purpose:

- **Bundled** (`.deb`, `.rpm`): ships its own OTP, so nothing to install and it
  works where the distro Erlang is older than the OTP ≥ 29 floor (Debian
  stable, RHEL/CentOS). The trade-off is that the runtime is frozen until the
  next package update.
- **Source, depends on distro erlang** (AUR): idiomatic on a rolling distro
  where `erlang` is already current, and strictly better there — the daemon
  inherits OTP security updates through `pacman` instead of carrying a frozen
  runtime.

Every bundled package carries native code (ERTS + the esqlite/fs NIFs), so it
is per-(os, arch) and must be built on the **oldest glibc** you intend to
support (same rule as `scripts/build-release.sh`).

## Building

```sh
# .deb (from a freshly built bundle):
packaging/deb/build-deb.sh
#   -> build/deb/iaragon_<ver>_<arch>.deb

# .rpm (on an RPM host): build the bundle, drop the tarball into SOURCES, then
scripts/build-release.sh
cp build/release/iaragon-linux-x86_64.tar.gz ~/rpmbuild/SOURCES/
rpmbuild -bb --define "iaragon_ver 0.0.$(git rev-list --count HEAD)+g$(git rev-parse --short HEAD)" \
  packaging/rpm/iaragon.spec

# AUR: publish packaging/aur/PKGBUILD as the `iaragon-git` package; users build
# it with makepkg -si (it clones main and builds from source).
```

Version is derived from git — a monotone commit count plus the short SHA
(`0.0.<n>+g<sha>`) — since the project is a rolling release with no version
tags.

## Publishing & auto-updates

The self-contained tarball that `install.sh` downloads is published with
[`scripts/publish-release.sh`](../scripts/publish-release.sh) to a single
rolling GitHub release tagged `latest` (a distribution pointer, not a version
tag). Run it once per architecture you ship, on a build host, with `gh`
authenticated.

For **`.deb`/`.rpm` auto-updates through the system updater** — the highest
ongoing-friction win — the packages must live behind a **signed apt/yum
repository** you host (e.g. GitHub Pages + `apt-ftparchive`/`createrepo_c` and
a GPG signing key). That hosting is deliberate infrastructure, not something
this repo automates: point the repo's `deb`/`rpm` lines at your server, sign
the metadata, and `apt upgrade`/`dnf upgrade` carry new versions from then on.
Until that repo exists, the packages install and update by hand
(`apt install ./iaragon_*.deb`), and `install.sh`'s curl path already gives
everyone the rolling self-contained release.
