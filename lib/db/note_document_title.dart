/// Older imports used "Document — Section" without a document title.
/// Explicit titles always win, including names that contain a dash.
String legacyNoteDocumentTitle(String resourceTitle) {
  final cut = resourceTitle.indexOf(' — ');
  return cut > 0 ? resourceTitle.substring(0, cut) : resourceTitle;
}

/// SQL counterpart, for grouping, sharing and deleting the same document.
/// Record titles (assignments, quizzes and PDFs) are already document names.
String noteDocumentTitleSql({String alias = ''}) {
  final p = alias.isEmpty ? '' : '$alias.';
  return 'COALESCE(${p}document_title, CASE '
      "WHEN ${p}topic_key NOT LIKE '~%' "
      "AND INSTR(${p}resource_title, ' — ') > 1 "
      "THEN SUBSTR(${p}resource_title, 1, INSTR(${p}resource_title, ' — ') - 1) "
      'ELSE ${p}resource_title END)';
}
