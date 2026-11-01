import 'package:drift/drift.dart';

import '../otic_database.dart';
import '../note_document_title.dart';
import '../tables/topic_resources_table.dart';

part 'topic_resource_dao.g.dart';

/// Read/write access to teacher-supplied topic resources.
///
/// Every method here is additive to the hardcoded syllabi: nothing in this DAO
/// can read, alter or shadow `assets/curriculum/*.json`. An empty table is a
/// fully supported state — [chunksForTopic] returns `[]` and the tutor runs on
/// the core syllabus exactly as it did before this feature existed.
@DriftAccessor(tables: [TopicResources])
class TopicResourceDao extends DatabaseAccessor<OticDatabase>
    with _$TopicResourceDaoMixin {
  TopicResourceDao(super.db);

  /// Inserts one chunk. Returns the new row id.
  ///
  /// Callers should normalize [subjectId] and [topicKey] first (the
  /// `OfflineStorageService` facade does this for them) — a raw lesson title
  /// written here would never be found by a retrieval that normalizes.
  Future<int> insertChunk({
    required String subjectId,
    required String topicKey,
    required int termMarker,
    required String resourceTitle,
    required String contentChunk,
    DateTime? createdAt,

    /// Scoped sync: which class/stream this chunk is pushed to
    /// ([ClassGroups.groupUuid]). Null means every class — see the column
    /// doc on [TopicResources.classGroupUuid].
    String? classGroupUuid,
  }) {
    final at = (createdAt ?? DateTime.now()).toUtc().toIso8601String();
    return into(topicResources).insert(
      TopicResourcesCompanion.insert(
        subjectId: subjectId,
        topicKey: topicKey,
        termMarker: Value(termMarker),
        resourceTitle: resourceTitle,
        contentChunk: contentChunk,
        createdAt: at,
        classGroupUuid: Value(classGroupUuid),
        updatedAt: Value(at),
      ),
    );
  }

  /// Inserts many chunks of one document in a single transaction, so a
  /// half-written resource can never be left behind by an interrupted import.
  Future<void> insertChunks(List<TopicResourcesCompanion> rows) async {
    if (rows.isEmpty) return;
    await batch((b) => b.insertAll(topicResources, rows));
  }

  /// Candidate rows for a retrieval: one subject, one topic, optionally one
  /// term.
  ///
  /// Ranking happens in Dart rather than SQL — the row count per topic is
  /// small (a handful of documents), and scoring here keeps the relevance
  /// rule in one readable place instead of spread across a query string.
  Future<List<TopicResource>> chunksForTopic({
    required String subjectId,
    required String topicKey,
    int? termMarker,
    int limit = 200,
    String? visibleClassUuid,
  }) {
    final q = select(topicResources)
      ..where(
        (t) => t.subjectId.equals(subjectId) & t.topicKey.equals(topicKey),
      )
      ..where((t) => _visibleTo(t, visibleClassUuid));
    if (termMarker != null) {
      // Rows marked "all terms" stay visible when a specific term is selected;
      // a textbook definition does not stop being true in Term 2.
      q.where(
        (t) =>
            t.termMarker.equals(termMarker) |
            t.termMarker.equals(kAllTermsMarker),
      );
    }
    q.limit(limit);
    return q.get();
  }

  /// Every chunk for a subject, regardless of topic — the fallback a retrieval
  /// uses when the active topic has no resources of its own.
  ///
  /// A null [limit] reads every chunk, in upload order.
  Future<List<TopicResource>> chunksForSubject({
    required String subjectId,
    int? termMarker,
    int? limit = 400,
    String? visibleClassUuid,
  }) {
    final q = select(topicResources)
      ..where((t) => t.subjectId.equals(subjectId))
      // A note's original-PDF record and quiz questions aren't teaching text.
      ..where((t) => t.topicKey.like('$kRecordTopicPrefix%').not())
      ..where((t) => _visibleTo(t, visibleClassUuid))
      ..orderBy([(t) => OrderingTerm.asc(t.id)]);
    if (termMarker != null) {
      q.where(
        (t) =>
            t.termMarker.equals(termMarker) |
            t.termMarker.equals(kAllTermsMarker),
      );
    }
    if (limit != null) q.limit(limit);
    return q.get();
  }

  /// Stored quiz questions of [subjectId] a learner in [visibleClassUuid]
  /// may take — see `NoteQuizStore`.
  Future<List<TopicResource>> quizRows({
    required String subjectId,
    String? visibleClassUuid,
  }) {
    return (select(topicResources)
          ..where((t) => t.subjectId.equals(subjectId))
          ..where((t) => t.topicKey.equals(kQuizTopicKey))
          ..where((t) => _visibleTo(t, visibleClassUuid)))
        .get();
  }

  /// Adds one quiz question row to this device's note [documentTitle].
  Future<void> insertQuizRow({
    required String subjectId,
    required String documentTitle,
    required String content,
    required int termMarker,
  }) async {
    final at = DateTime.now().toUtc().toIso8601String();
    await into(topicResources).insert(
      TopicResourcesCompanion.insert(
        subjectId: subjectId,
        topicKey: kQuizTopicKey,
        termMarker: Value(termMarker),
        resourceTitle: documentTitle,
        contentChunk: content,
        createdAt: at,
        documentTitle: Value(documentTitle),
        updatedAt: Value(at),
      ),
    );
  }

  /// Drops this device's own quiz questions for [documentTitle].
  Future<int> deleteQuizRows({
    required String subjectId,
    required String documentTitle,
  }) {
    return (delete(topicResources)
          ..where((t) => t.subjectId.equals(subjectId))
          ..where((t) => t.topicKey.equals(kQuizTopicKey))
          ..where((t) => t.documentTitle.equals(documentTitle))
          ..where((t) => t.classGroupUuid.isNull()))
        .go();
  }

  /// Live [quizRows]: the Quiz tab picks up questions as they are written.
  Stream<List<TopicResource>> watchQuizRows({
    required String subjectId,
    String? visibleClassUuid,
  }) {
    return (select(topicResources)
          ..where((t) => t.subjectId.equals(subjectId))
          ..where((t) => t.topicKey.equals(kQuizTopicKey))
          ..where((t) => _visibleTo(t, visibleClassUuid)))
        .watch();
  }

  /// This device's own text rows of one note, in upload order — what its
  /// topic quizzes are written from.
  Future<List<TopicResource>> ownNoteText({
    required String subjectId,
    required String documentTitle,
  }) {
    return (select(topicResources)
          ..where((t) => t.subjectId.equals(subjectId))
          ..where(
            (t) => CustomExpression<String>(
              noteDocumentTitleSql(),
            ).equals(documentTitle),
          )
          ..where((t) => t.classGroupUuid.isNull())
          ..where((t) => t.topicKey.like('$kRecordTopicPrefix%').not())
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
  }

  /// Drops this device's own text rows of one note — all of them, or only
  /// those written after [createdAfter] (ISO-8601 UTC), which is a batch
  /// that was cut off before it was recorded as done. Record rows (the
  /// PDF marker, quiz questions) stay.
  Future<int> deleteOwnNoteText({
    required String subjectId,
    required String documentTitle,
    String? createdAfter,
  }) {
    final q = delete(topicResources)
      ..where((t) => t.subjectId.equals(subjectId))
      ..where(
        (t) => CustomExpression<String>(
          noteDocumentTitleSql(),
        ).equals(documentTitle),
      )
      ..where((t) => t.classGroupUuid.isNull())
      ..where((t) => t.topicKey.like('$kRecordTopicPrefix%').not());
    if (createdAfter != null) {
      q.where((t) => t.createdAt.isBiggerThanValue(createdAfter));
    }
    return q.go();
  }

  /// Every note written on this device that has text, as
  /// (subjectId, documentTitle).
  Future<List<(String, String)>> ownNotesWithText() async {
    final document = CustomExpression<String>(noteDocumentTitleSql());
    final q = selectOnly(topicResources, distinct: true)
      ..addColumns([topicResources.subjectId, document])
      ..where(topicResources.classGroupUuid.isNull())
      ..where(topicResources.topicKey.like('$kRecordTopicPrefix%').not());
    return [
      for (final r in await q.get())
        (r.read(topicResources.subjectId)!, r.read(document)!),
    ];
  }

  /// Every (subject, document title, resource title) a learner in
  /// [visibleClassUuid] may read, one row per note section. Quiz and other
  /// record rows are left out; a PDF-only note's marker row counts.
  Future<List<(String, String?, String)>> visibleNoteTitles({
    String? visibleClassUuid,
  }) async {
    final t = topicResources;
    final q = selectOnly(t, distinct: true)
      ..addColumns([t.subjectId, t.documentTitle, t.resourceTitle])
      ..where(_visibleTo(t, visibleClassUuid))
      ..where(
        t.topicKey.like('$kRecordTopicPrefix%').not() |
            (t.topicKey.equals(kPdfMarkerTopicKey) & notAssignmentNote),
      );
    return [
      for (final r in await q.get())
        (
          r.read(t.subjectId)!,
          r.read(t.documentTitle),
          r.read(t.resourceTitle)!,
        ),
    ];
  }

  /// True for a `topic_resources` row whose note is not a class assignment
  /// (no `~assignment` row in the same note). An assignment's PDF holds
  /// the assessment, so it is never listed or counted as a note.
  static const notAssignmentNote = CustomExpression<bool>(
    "NOT EXISTS (SELECT 1 FROM topic_resources a "
    "WHERE a.topic_key = '$kAssignmentRecordTopicKey' "
    'AND a.subject_id = topic_resources.subject_id '
    'AND a.document_title IS topic_resources.document_title '
    'AND a.class_group_uuid IS topic_resources.class_group_uuid)',
  );

  /// Subjects with at least one note a learner in [visibleClassUuid] may
  /// read — a PDF-only note's marker row counts.
  Future<List<String>> subjectIdsWithNotes({String? visibleClassUuid}) async {
    final q = selectOnly(topicResources, distinct: true)
      ..addColumns([topicResources.subjectId])
      ..where(_visibleTo(topicResources, visibleClassUuid));
    final rows = await q.get();
    return [for (final r in rows) r.read(topicResources.subjectId)!];
  }

  /// Best-matching rows for [needle] within one subject, most relevant first.
  ///
  /// Full-text search over the `topic_resources_fts` index (see
  /// `OticDatabase._createResourceSearchIndex`), ranked by BM25. [needle] is
  /// free text; it is turned into a safe `MATCH` expression by
  /// [buildFtsMatch], so a teacher's or student's punctuation can never be
  /// read as FTS5 query syntax.
  Future<List<TopicResource>> searchChunks({
    required String subjectId,
    required String needle,
    int? termMarker,
    int limit = 60,
    String? visibleClassUuid,
  }) {
    return _search(
      needle,
      subjectId: subjectId,
      termMarker: termMarker,
      limit: limit,
      visibleClassUuid: visibleClassUuid,
    );
  }

  /// Best-matching rows for [needle] across every subject.
  ///
  /// For the tutor chat, which does not know which teacher subject a question
  /// belongs to — the index decides.
  Future<List<TopicResource>> searchAllChunks({
    required String needle,
    int limit = 20,
    String? visibleClassUuid,
  }) {
    return _search(needle, limit: limit, visibleClassUuid: visibleClassUuid);
  }

  /// Notes a learner may be tutored from: this device's own notes, plus
  /// notes received for [visibleClassUuid] — never another class's, even on
  /// a device shared between classes.
  Expression<bool> _visibleTo(
    $TopicResourcesTable t,
    String? visibleClassUuid,
  ) => visibleClassUuid == null
      ? t.classGroupUuid.isNull()
      : t.classGroupUuid.isNull() | t.classGroupUuid.equals(visibleClassUuid);

  Future<List<TopicResource>> _search(
    String needle, {
    String? subjectId,
    int? termMarker,
    required int limit,
    String? visibleClassUuid,
  }) async {
    final match = buildFtsMatch(needle);
    if (match.isEmpty) return const [];

    final rows = await customSelect(
      'SELECT t.* FROM topic_resources_fts f '
      'JOIN topic_resources t ON t.id = f.rowid '
      'WHERE topic_resources_fts MATCH ? '
      "AND t.topic_key NOT LIKE '$kRecordTopicPrefix%' "
      '${subjectId == null ? '' : 'AND t.subject_id = ? '}'
      '${termMarker == null ? '' : 'AND (t.term_marker = ? OR t.term_marker = ?) '}'
      'AND (t.class_group_uuid IS NULL'
      '${visibleClassUuid == null ? '' : ' OR t.class_group_uuid = ?'}) '
      // bm25() is lower-is-better, so ascending puts the best match first.
      'ORDER BY bm25(topic_resources_fts) '
      'LIMIT ?',
      variables: [
        Variable.withString(match),
        if (subjectId != null) Variable.withString(subjectId),
        if (termMarker != null) Variable.withInt(termMarker),
        if (termMarker != null) Variable.withInt(kAllTermsMarker),
        if (visibleClassUuid != null) Variable.withString(visibleClassUuid),
        Variable.withInt(limit),
      ],
      readsFrom: {topicResources},
    ).get();

    return rows.map((r) => topicResources.map(r.data)).toList();
  }

  /// Removes an entire note — every section and chunk of the document the
  /// teacher sees as [title] (or, for older rows, every chunk titled so).
  ///
  /// Scoped by subject when [subjectId] is given so two subjects can both hold
  /// a document called "Term 1 Notes" without one deletion taking out both.
  /// Only this device's own notes: one received from a class with the same
  /// title stays. Returns the number of chunks removed.
  Future<int> deleteByTitle(String title, {String? subjectId}) async {
    // Its class shares go with it, or a later note with the same title
    // would silently inherit them.
    await customUpdate(
      'DELETE FROM resource_shares WHERE (document_title = ? OR EXISTS ('
      'SELECT 1 FROM topic_resources t WHERE t.subject_id = resource_shares.subject_id '
      'AND t.resource_title = resource_shares.document_title '
      'AND t.class_group_uuid IS NULL AND t.document_title IS NULL '
      'AND ${noteDocumentTitleSql(alias: 't')} = ?))'
      '${subjectId == null ? '' : ' AND subject_id = ?'}',
      variables: [
        Variable.withString(title),
        Variable.withString(title),
        if (subjectId != null) Variable.withString(subjectId),
      ],
      updates: {attachedDatabase.resourceShares},
    );
    final q = delete(topicResources)
      ..where(
        (t) =>
            CustomExpression<String>(noteDocumentTitleSql()).equals(title) |
            t.resourceTitle.equals(title),
      )
      ..where((t) => t.classGroupUuid.isNull());
    if (subjectId != null) {
      q.where((t) => t.subjectId.equals(subjectId));
    }
    return q.go();
  }

  /// Removes every resource belonging to a subject.
  ///
  /// Used when a teacher deletes a custom subject: the subject row and its
  /// material go together, or the material becomes unreachable rows that no
  /// screen can list and no one can delete. Only this device's own notes:
  /// ones received from a class for a subject with the same id stay.
  Future<int> deleteBySubject(String subjectId) async {
    await customStatement('DELETE FROM resource_shares WHERE subject_id = ?', [
      subjectId,
    ]);
    return (delete(topicResources)
          ..where((t) => t.subjectId.equals(subjectId))
          ..where((t) => t.classGroupUuid.isNull()))
        .go();
  }

  // What class sync may serve lives in ClassSyncDao.sharedChunks — only
  // notes written on this device with an explicit share for the class.

  /// One row per uploaded file or typed note, for the teacher's list.
  ///
  /// Grouped in SQL by document: a file is split into sections (one per
  /// heading, for retrieval) and each section into chunks, but a teacher
  /// thinks in the files they added and must never be shown either split.
  ///
  /// [ownOnly]: only notes made on this device, never ones received from a
  /// class — what a teacher may change.
  Future<List<ResourceSummary>> listResources({
    String? subjectId,
    bool ownOnly = false,
  }) async {
    final conditions = [
      if (subjectId != null) 'subject_id = ?',
      if (ownOnly) 'class_group_uuid IS NULL',
    ];
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final document = noteDocumentTitleSql();
    final rows = await customSelect(
      'SELECT $document AS resource_title, '
      '       subject_id, MIN(topic_key) AS topic_key, MIN(term_marker) AS term_marker, '
      '       COUNT(*) AS chunk_count, MIN(created_at) AS created_at, '
      "       SUM(CASE WHEN topic_key LIKE '$kRecordTopicPrefix%' THEN 0 ELSE 1 END) AS text_count, "
      "       SUM(CASE WHEN topic_key = '$kQuizTopicKey' THEN 1 ELSE 0 END) AS quiz_count "
      'FROM topic_resources $where '
      'GROUP BY $document, subject_id '
      'ORDER BY created_at DESC',
      variables: [if (subjectId != null) Variable.withString(subjectId)],
      readsFrom: {topicResources},
    ).get();

    return rows
        .map(
          (r) => ResourceSummary(
            resourceTitle: r.read<String>('resource_title'),
            subjectId: r.read<String>('subject_id'),
            topicKey: r.read<String>('topic_key'),
            termMarker: r.read<int>('term_marker'),
            chunkCount: r.read<int>('chunk_count'),
            textCount: r.read<int>('text_count'),
            quizCount: r.read<int>('quiz_count'),
            createdAt: DateTime.tryParse(r.read<String>('created_at')),
          ),
        )
        .toList();
  }

  Future<int> countChunks() async {
    final count = topicResources.id.count();
    final row = await (selectOnly(
      topicResources,
    )..addColumns([count])).getSingle();
    return row.read(count) ?? 0;
  }

  /// Wipes every teacher resource. The hardcoded syllabi are untouched.
  Future<void> clear() => delete(topicResources).go();
}

/// One teacher-visible resource, with its chunking already collapsed away.
/// Topic key of a note's original-PDF record (see `NotePdfStore`) — kept
/// out of the tutor's retrieval. Starts with `~` so `MIN(topic_key)` in
/// [TopicResourceDao.listResources] never picks it.
const kPdfMarkerTopicKey = '~pdf-original';

/// Topic key of a quiz question written from one page of a note's PDF
/// (see `NoteQuizStore`). Rides with the note like [kPdfMarkerTopicKey].
const kQuizTopicKey = '~quiz';

/// Every record row (not teaching text) has a topic key starting with this;
/// the tutor's search and the notes text skip them all.
const kRecordTopicPrefix = '~';

/// Topic key of a class assignment's row (`kAssignmentTopicKey`).
const kAssignmentRecordTopicKey = '~assignment';

class ResourceSummary {
  const ResourceSummary({
    required this.resourceTitle,
    required this.subjectId,
    required this.topicKey,
    required this.termMarker,
    required this.chunkCount,
    this.textCount = 0,
    this.quizCount = 0,
    this.createdAt,
  });

  final String resourceTitle;
  final String subjectId;
  final String topicKey;
  final int termMarker;

  /// Internal detail — never render this in a teacher-facing view.
  final int chunkCount;

  /// Rows of teaching text (0 while a PDF is still being read) and stored
  /// quiz questions.
  final int textCount;
  final int quizCount;

  final DateTime? createdAt;
}

/// Turns free text into an FTS5 `MATCH` expression, or `''` when nothing in
/// it is searchable.
///
/// Every term is double-quoted, which makes it a literal token: FTS5 gives
/// `-`, `:`, `*`, `^`, parentheses and the words AND/OR/NOT/NEAR special
/// meaning, and unquoted student text would either throw a syntax error or
/// silently search for something else. Terms are OR-ed — a question matches
/// on any of its words and BM25 ranks chunks that hit more of them higher.
///
/// The porter tokenizer folds inflections but not derivations
/// ("photosynthesizing" does not stem to "photosynthesis"), so long terms also
/// get a truncated prefix term, which does catch those.
String buildFtsMatch(String text) {
  final terms = text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.length > 2)
      .toSet();
  final parts = <String>{};
  for (final term in terms) {
    parts.add('"$term"');
    if (term.length >= 8) {
      final keep = (term.length * 0.7).round().clamp(5, term.length - 1);
      parts.add('"${term.substring(0, keep)}"*');
    }
  }
  return parts.join(' OR ');
}
