# RPM spec for iaragon — bidirectional Google Drive sync daemon.
#
# Like the .deb, this packages the SELF-CONTAINED release: it repackages a
# prebuilt bundle (its own BEAM runtime + the app), so the installed system
# needs no Erlang/Gleam/rebar3/gcc. Bundling on RHEL/CentOS is deliberate —
# their distro Erlang lags behind the OTP >= 29 floor, so vendoring the
# runtime is what makes it "just work" (the trade-off the Arch package makes
# differently, depending on the distro's current erlang).
#
# NOT verified in this repo's CI (no rpmbuild in the dev container). Build on
# an RPM host:
#   1. Build the bundle:  ./scripts/build-release.sh
#   2. Copy the tarball into rpmbuild/SOURCES/ as iaragon-linux-%{_arch}.tar.gz
#   3. rpmbuild -bb --define "iaragon_ver 0.0.<n>+g<sha>" packaging/rpm/iaragon.spec
# rpmlint will note the bundled interpreter/runtime — expected, same as the .deb.

Name:           iaragon
Version:        %{?iaragon_ver}%{!?iaragon_ver:0.0.0}
Release:        1%{?dist}
Summary:        Bidirectional Google Drive sync daemon (Mirror mode) for Linux

License:        Apache-2.0
URL:            https://github.com/jeffersonguerin/iaragon
# The prebuilt, self-contained bundle for this arch (from build-release.sh).
Source0:        iaragon-linux-%{_arch}.tar.gz

# Self-contained: the BEAM runtime is bundled, so no Erlang dependency.
Recommends:     inotify-tools
# The bundled ERTS/NIFs are prebuilt native code; nothing to compile or debug here.
%global debug_package %{nil}
AutoReqProv:    no

%description
iaragon keeps a full, browsable local copy of your Google Drive in sync in
both directions, like Google Drive for Desktop's Mirror mode. This package is
self-contained: it bundles its own BEAM runtime, so no Erlang, Gleam, rebar3
or C compiler is required. inotify-tools is recommended for instant
local-change detection (the daemon falls back to polling without it).

%prep
# The tarball extracts to a single iaragon-<os>-<arch>/ directory.
%setup -q -n iaragon-linux-%{_arch}

%install
rm -rf %{buildroot}
install -d %{buildroot}%{_prefix}/lib/iaragon
install -d %{buildroot}%{_bindir}
install -d %{buildroot}%{_prefix}/lib/systemd/user

# The bundle (otp/ app/ bin/) under %{_prefix}/lib/iaragon.
cp -a otp app bin %{buildroot}%{_prefix}/lib/iaragon/

# Thin launchers over the bundle's self-locating launchers.
for name in iaragon iaragon-login iaragon-doctor; do
  cat > %{buildroot}%{_bindir}/$name <<EOF
#!/bin/sh
# iaragon launcher (packaged) — self-contained, no system Erlang needed.
exec %{_prefix}/lib/iaragon/bin/$name "\$@"
EOF
  chmod 0755 %{buildroot}%{_bindir}/$name
done

# systemd USER units (system-provided; each user runs `systemctl --user enable`).
cat > %{buildroot}%{_prefix}/lib/systemd/user/iaragon.service <<'EOF'
[Unit]
Description=iaragon — bidirectional Google Drive sync daemon
Documentation=https://github.com/jeffersonguerin/iaragon
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart=%{_bindir}/iaragon
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
cat > %{buildroot}%{_prefix}/lib/systemd/user/iaragon-doctor.service <<'EOF'
[Unit]
Description=iaragon — health check (iaragon-doctor)
Documentation=https://github.com/jeffersonguerin/iaragon

[Service]
Type=oneshot
ExecStart=%{_bindir}/iaragon-doctor
EOF
cat > %{buildroot}%{_prefix}/lib/systemd/user/iaragon-doctor.timer <<'EOF'
[Unit]
Description=iaragon — daily health check

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF

%files
%{_bindir}/iaragon
%{_bindir}/iaragon-login
%{_bindir}/iaragon-doctor
%{_prefix}/lib/iaragon/
%{_prefix}/lib/systemd/user/iaragon.service
%{_prefix}/lib/systemd/user/iaragon-doctor.service
%{_prefix}/lib/systemd/user/iaragon-doctor.timer

%changelog
* Thu Jan 01 2026 iaragon maintainers - rolling
- Rolling release; version derived from git via --define iaragon_ver.
