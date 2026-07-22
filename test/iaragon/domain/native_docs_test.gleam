import iaragon/domain/entry.{ExportOdf, ExportOffice, LinkFile}
import iaragon/domain/native_docs.{ExportDocument, WriteLinkFile}

const docs_mime = "application/vnd.google-apps.document"

const sheets_mime = "application/vnd.google-apps.spreadsheet"

const slides_mime = "application/vnd.google-apps.presentation"

pub fn the_link_policy_always_materializes_a_link_test() {
  assert native_docs.choose_materialisation(docs_mime, LinkFile)
    == WriteLinkFile
  assert native_docs.choose_materialisation(sheets_mime, LinkFile)
    == WriteLinkFile
  assert native_docs.choose_materialisation(slides_mime, LinkFile)
    == WriteLinkFile
}

// Export MIME types verified against the official Drive v3 reference
// (Export MIME types for Google Workspace documents).
pub fn the_office_policy_exports_docs_sheets_and_slides_test() {
  assert native_docs.choose_materialisation(docs_mime, ExportOffice)
    == ExportDocument(
      export_mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      extension: "docx",
    )
  assert native_docs.choose_materialisation(sheets_mime, ExportOffice)
    == ExportDocument(
      export_mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      extension: "xlsx",
    )
  assert native_docs.choose_materialisation(slides_mime, ExportOffice)
    == ExportDocument(
      export_mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      extension: "pptx",
    )
}

pub fn the_odf_policy_exports_docs_sheets_and_slides_test() {
  assert native_docs.choose_materialisation(docs_mime, ExportOdf)
    == ExportDocument(
      export_mime: "application/vnd.oasis.opendocument.text",
      extension: "odt",
    )
  assert native_docs.choose_materialisation(sheets_mime, ExportOdf)
    == ExportDocument(
      export_mime: "application/vnd.oasis.opendocument.spreadsheet",
      extension: "ods",
    )
  assert native_docs.choose_materialisation(slides_mime, ExportOdf)
    == ExportDocument(
      export_mime: "application/vnd.oasis.opendocument.presentation",
      extension: "odp",
    )
}

// Drawings only export to images/PDF (no Office/ODF equivalent) and the
// remaining native kinds (forms, sites, maps…) have no export at all, so
// every non-document native stays a link under every policy.
pub fn natives_without_a_document_export_stay_links_test() {
  assert native_docs.choose_materialisation(
      "application/vnd.google-apps.drawing",
      ExportOffice,
    )
    == WriteLinkFile
  assert native_docs.choose_materialisation(
      "application/vnd.google-apps.form",
      ExportOdf,
    )
    == WriteLinkFile
}
