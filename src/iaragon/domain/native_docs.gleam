//// How a Google-native file materialises in the local mirror under the
//// configured policy. Docs/Sheets/Slides have documented Office and ODF
//// export formats (Drive v3 export MIME reference); every other native kind
//// (drawings export only to images/PDF; forms, sites, maps have no export)
//// stays a browser link under every policy. Pure data — no I/O.

import iaragon/domain/entry.{
  type NativeDocPolicy, ExportOdf, ExportOffice, LinkFile,
}

pub type NativeMaterialisation {
  /// A `.desktop` link that opens the document in the browser.
  WriteLinkFile
  /// A real export download: `files/{id}/export?mimeType=export_mime`,
  /// materialised with the matching file extension.
  ExportDocument(export_mime: String, extension: String)
}

pub fn choose_materialisation(
  mime_type: String,
  policy: NativeDocPolicy,
) -> NativeMaterialisation {
  case policy, mime_type {
    LinkFile, _ -> WriteLinkFile
    ExportOffice, "application/vnd.google-apps.document" ->
      ExportDocument(
        export_mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        extension: "docx",
      )
    ExportOffice, "application/vnd.google-apps.spreadsheet" ->
      ExportDocument(
        export_mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        extension: "xlsx",
      )
    ExportOffice, "application/vnd.google-apps.presentation" ->
      ExportDocument(
        export_mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        extension: "pptx",
      )
    ExportOdf, "application/vnd.google-apps.document" ->
      ExportDocument(
        export_mime: "application/vnd.oasis.opendocument.text",
        extension: "odt",
      )
    ExportOdf, "application/vnd.google-apps.spreadsheet" ->
      ExportDocument(
        export_mime: "application/vnd.oasis.opendocument.spreadsheet",
        extension: "ods",
      )
    ExportOdf, "application/vnd.google-apps.presentation" ->
      ExportDocument(
        export_mime: "application/vnd.oasis.opendocument.presentation",
        extension: "odp",
      )
    ExportOffice, _ | ExportOdf, _ -> WriteLinkFile
  }
}
