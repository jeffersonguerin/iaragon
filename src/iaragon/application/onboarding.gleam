//// The assisted first-run: the walkthrough the login prints when no OAuth
//// client is configured yet. Google requires every app to register its own
//// OAuth client, and the full-drive scope is "restricted" — shipping a
//// shared client inside iaragon would demand Google verification plus a
//// yearly CASA security audit, so (like rclone recommends) each user
//// creates a personal client once. This module holds the words; keeping
//// them pure keeps them tested.
////
//// Console links verified against the Google Cloud console layout
//// (2026-07): OAuth consent lives under "Google Auth Platform" —
//// /auth/branding (consent screen), /auth/clients (OAuth clients),
//// /auth/audience (publishing status). The wording tolerates UI drift.

pub fn describe_missing_client(client_path: String) -> String {
  "No OAuth client is configured yet — one-time setup (10-15 minutes).

iaragon talks to YOUR Google Drive through YOUR own (free) Google Cloud
OAuth client. Create it once:

  1. Create (or pick) a Google Cloud project:
       https://console.cloud.google.com/projectcreate
  2. Enable the Google Drive API for that project:
       https://console.cloud.google.com/apis/library/drive.googleapis.com
  3. Configure the consent screen (app name + your e-mail; External):
       https://console.cloud.google.com/auth/branding
  4. Create the client — \"Create OAuth client\" (or Credentials >
     Create credentials > OAuth client ID), application type \"Desktop app\":
       https://console.cloud.google.com/auth/clients
  5. Copy the client ID and secret into
       " <> client_path <> "
     shaped exactly like this:
       {\"client_id\": \"...\", \"client_secret\": \"...\"}
  6. IMPORTANT — publish the app \"In production\" (Audience > Publishing
     status > Publish app):
       https://console.cloud.google.com/auth/audience
     Left in \"Testing\", Google expires your login every 7 days (and you
     must list yourself as a test user). Publishing shows an \"unverified
     app\" warning on the consent screen — expected: it is your own app,
     used only by you.

(The console UI moves around; if a link 404s, search the console for
\"OAuth\". Steps and shape stay the same.)

Then run iaragon-login again."
}
