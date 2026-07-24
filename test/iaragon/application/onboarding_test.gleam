import gleam/string
import iaragon/application/onboarding

// The assisted setup: when the login finds no oauth_client.json it prints a
// complete, self-sufficient walkthrough of the Google Cloud steps. These
// tests pin the load-bearing content — the exact links, the client type,
// the JSON shape and the 7-day "Testing" trap — so a reword can never drop
// the parts a stuck user actually needs.

fn guide() -> String {
  onboarding.describe_missing_client(
    "/home/u/.config/iaragon/oauth_client.json",
  )
}

pub fn the_guide_names_the_missing_file_test() {
  assert string.contains(guide(), "/home/u/.config/iaragon/oauth_client.json")
}

pub fn the_guide_links_every_console_step_test() {
  let guide = guide()
  assert string.contains(
    guide,
    "https://console.cloud.google.com/projectcreate",
  )
  assert string.contains(
    guide,
    "https://console.cloud.google.com/apis/library/drive.googleapis.com",
  )
  assert string.contains(
    guide,
    "https://console.cloud.google.com/auth/branding",
  )
  assert string.contains(guide, "https://console.cloud.google.com/auth/clients")
  assert string.contains(
    guide,
    "https://console.cloud.google.com/auth/audience",
  )
}

pub fn the_guide_asks_for_a_desktop_app_client_test() {
  assert string.contains(guide(), "Desktop app")
}

pub fn the_guide_tells_you_to_download_and_save_the_json_test() {
  // The smooth path: download Google's client JSON and save it as-is, no
  // hand-transcribing fields. Pin the load-bearing words — the "Download
  // JSON" action and that the downloaded `installed` wrapper is accepted.
  let guide = guide()
  assert string.contains(guide, "Download JSON")
  assert string.contains(guide, "installed")
}

pub fn the_guide_warns_about_the_testing_expiry_test() {
  let guide = guide()
  assert string.contains(guide, "In production")
  assert string.contains(guide, "7 days")
}
