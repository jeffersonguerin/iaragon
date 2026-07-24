# Homebrew formula for iaragon.
#
# Rolling release: there are no version tags, so this is a HEAD-only formula.
# Install it straight from the tap-less local file or a tap:
#
#   brew install --HEAD jeffersonguerin/iaragon/iaragon
#
# or, from a local checkout:
#
#   brew install --HEAD ./Formula/iaragon.rb
#
# Note: the daemon itself targets Linux (inotify watcher, GVfs/KDE status
# emblems). The formula builds and installs cleanly on macOS too, but the
# sync daemon is meant to run on a Linux desktop.
class Iaragon < Formula
  desc "Bidirectional Google Drive sync daemon for Linux, on the BEAM"
  homepage "https://github.com/jeffersonguerin/iaragon"
  license "Apache-2.0"
  head "https://github.com/jeffersonguerin/iaragon.git", branch: "main"

  # When installed via Homebrew, the whole toolchain comes via Homebrew — one
  # consistent source, no mixing with a system package manager. Existing brew
  # installs of these are reused, not duplicated.
  depends_on "gleam" => :build
  depends_on "rebar3" => :build
  depends_on "erlang"

  # The inotify watcher is a Linux-only runtime dependency; on macOS the
  # daemon uses polling. Brought in through brew too, to keep the method
  # consistent.
  on_linux do
    depends_on "inotify-tools"
  end

  def install
    # Produce a self-contained precompiled Erlang release.
    system "gleam", "export", "erlang-shipment"
    libexec.install Dir["build/erlang-shipment/*"]

    erl = Formula["erlang"].opt_bin/"erl"

    (bin/"iaragon").write <<~SH
      #!/bin/sh
      # iaragon sync daemon launcher
      PATH="#{Formula["erlang"].opt_bin}:$PATH"; export PATH
      exec "#{libexec}/entrypoint.sh" run "$@"
    SH

    (bin/"iaragon-login").write <<~SH
      #!/bin/sh
      # iaragon interactive OAuth login launcher
      exec "#{erl}" -pa "#{libexec}"/*/ebin -noshell -eval 'iaragon@login:main(), halt(0)' -extra "$@"
    SH

    (bin/"iaragon-doctor").write <<~SH
      #!/bin/sh
      # iaragon health check launcher
      exec "#{erl}" -pa "#{libexec}"/*/ebin -noshell -eval 'iaragon@doctor:main(), halt(0)' -extra "$@"
    SH

    # Pathname#write creates files 0644; a launcher that is not executable
    # fails every invocation with "Permission denied" (observed on
    # Homebrew 6 / Linux). Verified: write alone does NOT preserve or add
    # the execute bit.
    [bin/"iaragon", bin/"iaragon-login", bin/"iaragon-doctor"].each do |launcher|
      launcher.chmod 0755
    end
  end

  # Supervision parity with the native packages (.deb/.rpm ship a systemd
  # user unit): `brew services start iaragon` — on Linux brew services
  # renders this into a systemd user unit, on macOS into launchd. keep_alive
  # on crash only: a clean exit stays down (mirrors Restart=on-failure).
  service do
    run [opt_bin/"iaragon"]
    keep_alive crashed: true
    log_path var/"log/iaragon.log"
    error_log_path var/"log/iaragon.log"
  end

  def caveats
    <<~EOS
      Set up a Google Cloud "Desktop app" OAuth client and save it as
      ~/.config/iaragon/oauth_client.json:
        {"client_id": "...", "client_secret": "..."}

      Then log in and start the daemon under supervision:
        iaragon-login                  # opens your browser (loopback + PKCE)
        brew services start iaragon    # supervised (systemd --user on Linux)

      (Or run `iaragon` in the foreground.) The mirror lives at ~/GoogleDrive.

      Erlang, Gleam, rebar3 (and inotify-tools on Linux) were installed as
      Homebrew dependencies, so the whole toolchain stays under brew.
    EOS
  end

  test do
    # Login exits 0 even with no config, reporting the missing client file:
    # a cheap end-to-end proof that the release loads and the module runs.
    output = shell_output("#{bin}/iaragon-login 2>&1")
    assert_match "oauth_client.json", output
  end
end
