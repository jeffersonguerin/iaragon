import iaragon/application/diagnostics.{Check, Fail, Pass, Warn}

// The doctor report is pure: probes (I/O) produce Checks, this module turns
// them into the human-readable report and the exit verdict. Fixing the
// format here keeps the doctor command itself a thin composition.

pub fn a_passing_report_renders_one_line_per_check_test() {
  let report =
    diagnostics.render_report([
      Check("oauth client", Pass, "configured"),
      Check("daemon", Pass, "answering on the status socket"),
    ])
  assert report
    == "✓ oauth client  configured\n"
    <> "✓ daemon        answering on the status socket\n"
    <> "\nall checks passed"
}

pub fn warnings_and_failures_are_marked_and_counted_test() {
  let report =
    diagnostics.render_report([
      Check("oauth client", Fail, "missing — run iaragon-login"),
      Check("daemon", Warn, "not running"),
      Check("mirror", Pass, "exists"),
    ])
  assert report
    == "✗ oauth client  missing — run iaragon-login\n"
    <> "! daemon        not running\n"
    <> "✓ mirror        exists\n"
    <> "\n1 failure, 1 warning"
}

pub fn only_failures_make_the_report_a_failure_test() {
  assert diagnostics.has_failure([Check("a", Pass, ""), Check("b", Warn, "")])
    == False
  assert diagnostics.has_failure([Check("a", Pass, ""), Check("b", Fail, "")])
    == True
}

pub fn a_fresh_access_token_reports_its_expiry_test() {
  // 2026-07-23 12:00:00 UTC = 1_784_808_000; expiry an hour later.
  assert diagnostics.describe_token_expiry(
      now: 1_784_808_000,
      expires_at: 1_784_811_600,
    )
    == "refresh works; access token valid until 2026-07-23T13:00:00Z"
}

pub fn an_expired_access_token_is_not_an_error_test() {
  // Auto-refresh handles it on the next API call; the doctor only states it.
  assert diagnostics.describe_token_expiry(
      now: 1_784_811_601,
      expires_at: 1_784_811_600,
    )
    == "refresh works; access token will refresh on next use"
}
