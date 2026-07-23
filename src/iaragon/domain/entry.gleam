//// State of a single file as seen from each of the three vantage points of
//// the three-way diff: the local disk, the remote Drive, and the last state
//// this daemon knows to have been synced. Pure data — no I/O, no OTP.

import gleam/option.{type Option}

/// What kind of thing a Drive item is. Google-native files (Docs, Sheets,
/// Slides…) have no bytes and no checksum, so they get special treatment.
pub type FileKind {
  Blob
  GoogleNative
  Folder
  Shortcut(target_id: String)
}

/// A file as observed on the local disk. `path` is relative to the sync root.
/// `md5` is computed on demand and may be absent when only cheap metadata
/// (size + mtime) has been gathered.
pub type LocalFile {
  LocalFile(path: String, size: Int, mtime_seconds: Int, md5: Option(String))
}

/// A file as observed on Drive. Identity is `file_id` — names are not unique
/// within a folder. `path` is the POSIX path already resolved by the
/// path-mapping layer (that mapping is lossy and lives outside the domain).
/// `md5` is `None` for Google-native files, folders, and shortcuts.
pub type RemoteFile {
  RemoteFile(
    file_id: String,
    name: String,
    path: String,
    mime_type: String,
    parent_id: Option(String),
    modified_time: String,
    size: Option(Int),
    md5: Option(String),
    trashed: Bool,
    kind: FileKind,
  )
}

/// The last state known to have been synced: the link between a Drive
/// `file_id` and a local path, plus the metadata snapshot taken at sync time.
/// Without this record it is impossible to tell changed-locally from
/// changed-remotely from conflict.
pub type KnownFile {
  KnownFile(
    file_id: String,
    path: String,
    remote_modified_time: String,
    md5: Option(String),
    size: Int,
    local_mtime_seconds: Int,
    kind: FileKind,
  )
}

/// How Google-native files are materialised in the local mirror. They are
/// download-only in every mode: exports are lossy and capped at 10 MB, so a
/// local edit is never uploaded back.
pub type NativeDocPolicy {
  LinkFile
  ExportOffice
  ExportOdf
}

/// The user-visible sync state of a mirrored path: a transfer in flight,
/// bytes settled on both sides, or a transfer that burnt all its retries
/// (the next round re-decides it, flipping the state back to Syncing).
/// Presentation adapters (file-manager emblems…) translate this into
/// whatever their medium shows.
pub type SyncStatus {
  Syncing
  Synced
  SyncFailed
}

pub fn default_native_doc_policy() -> NativeDocPolicy {
  LinkFile
}
