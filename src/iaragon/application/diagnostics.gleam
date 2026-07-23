//// The doctor's pure core: probes (I/O, composed in iaragon/doctor) produce
//// `Check`s; this module renders them as the human report and decides the
//// exit verdict. Keeping the wording and layout here — pure and tested —
//// leaves the doctor command a thin composition, like the login.

import gleam/int
import gleam/list
import gleam/string
import gleam/time/duration
import gleam/time/timestamp

pub type CheckStatus {
  Pass
  Warn
  Fail
}

pub type Check {
  Check(name: String, status: CheckStatus, detail: String)
}

pub fn render_report(checks: List(Check)) -> String {
  let name_width =
    list.fold(checks, 0, fn(widest, check) {
      int.max(widest, string.length(check.name))
    })
  let lines =
    list.map(checks, fn(check) {
      mark(check.status)
      <> " "
      <> string.pad_end(check.name, name_width, " ")
      <> "  "
      <> check.detail
      <> "\n"
    })
  string.concat(lines) <> "\n" <> summarise(checks)
}

pub fn has_failure(checks: List(Check)) -> Bool {
  list.any(checks, fn(check) { check.status == Fail })
}

/// The access token expiring is NOT a problem — the token manager refreshes
/// on the next API call. The doctor only reports which of the two states the
/// stored token is in, after proving the refresh path works.
pub fn describe_token_expiry(
  now now: Int,
  expires_at expires_at: Int,
) -> String {
  case now < expires_at {
    True ->
      "refresh works; access token valid until "
      <> {
        timestamp.from_unix_seconds(expires_at)
        |> timestamp.to_rfc3339(duration.seconds(0))
      }
    False -> "refresh works; access token will refresh on next use"
  }
}

fn mark(status: CheckStatus) -> String {
  case status {
    Pass -> "✓"
    Warn -> "!"
    Fail -> "✗"
  }
}

fn summarise(checks: List(Check)) -> String {
  let failures = list.count(checks, fn(check) { check.status == Fail })
  let warnings = list.count(checks, fn(check) { check.status == Warn })
  case failures, warnings {
    0, 0 -> "all checks passed"
    _, 0 -> count(failures, "failure")
    0, _ -> count(warnings, "warning")
    _, _ -> count(failures, "failure") <> ", " <> count(warnings, "warning")
  }
}

fn count(how_many: Int, noun: String) -> String {
  case how_many {
    1 -> "1 " <> noun
    n -> int.to_string(n) <> " " <> noun <> "s"
  }
}
