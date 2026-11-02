# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

AI Connect Africa is a **fully offline AI-powered Learning Operating System**. It runs entirely on-device — no internet, no cloud, no external APIs, ever. Two on-device models are bundled and run locally.

**One runtime per platform, never mixed** (`lib/ai_core/model/model_runtime_policy.dart`):

- **Android → LiteRT-LM only.** Both models are `.litertlm` files.
  - Each role gets its own engine (`LiteRtLmEngineImpl`, built with
    `LiteRtLmEngine().createModel`, not flutter_gemma's single active slot).
  - Hardware order is NPU (Qualcomm QNN / MediaTek / Tensor) → GPU → LiteRT
    CPU. The backend that worked is remembered per role.
  - LiteRT-LM has **no NNAPI**; Google deprecated it in Android 15, and the
    vendor NPU dispatch replaces it.
  - llama.cpp's native libraries are excluded from the APK
    (`android/app/build.gradle.kts`).
  - On 4 GB phones the GPU often can't fit the model, so LiteRT lands on its
    CPU backend. Settings → AI engine shows the backend actually in use.
- **Windows / Linux → llama.cpp GGUF only.** LiteRT is never started.
- **A model file in the other platform's format is not "installed".**
  Every engine is built by `createBrainEngine` / `createTranslatorEngine`
  in `ai_provider.dart`.

- **Brain — Qwen2.5-Coder-1.5B-Instruct** (int4 `.litertlm` on Android, GGUF on desktop) → the one reasoning model. It does **all** reasoning and answer generation: tutoring, practice, learning paths, *and* code for the labs and builders (programming subjects just get the programming contract, `kProgrammingTutorContract`, on the same engine). See `lib/ai_core/model/model_manager.dart` and `dualModelRuntimeProvider` in `lib/ai_core/providers/ai_provider.dart`. Apache-2.0. **There is no Qwen3-0.6B any more** — it was removed on 2026-09-23 so one model does both jobs; don't reintroduce a separate chat or coder model.
- **Translation — TranslatePsy-AfriSLM** (int8 `.litertlm` on Android, converted by `.github/workflows/convert-afrislm-litertlm.yml` behind a round-trip quality gate — see `tools/litert/`; Q4 GGUF on desktop) → translates English ↔ 19 Sub-Saharan African languages so students can learn in their own language while the tutor reasons in English. In-process on both runtimes, no server. `/no_think` is sent to AfriSLM (a Qwen3.5 fine-tune) but not to the Qwen2.5 brain (`appendNoThink` on both engine classes). On Android every translation is a fresh conversation (`isolatedTurns`), never a pinned chat. See `lib/ai_core/translate/afrislm_model_manager.dart`.

Decoding is greedy everywhere (exact, repeatable code/JSON/translation)
**except the chat bubble**: `TutorPipeline.respond` and `QwenChatService`
run inside `runAsProse` (`decode_profile.dart`), which gives light seeded
sampling, a repeat penalty on llama.cpp, and `RepetitionGuard`, which cuts a
reply off before a repeated sentence is shown. Greedy decoding on the 1.5B
brain wrote the same paragraph until it ran out of tokens.

Both models expose the same Dart inference interface from `lib/ai_core/inference/inference_engine.dart`. Chat and translation are both wired up and shipping. On Windows, llama.cpp's `ggml.dll` carries a load-time import on `ggml-vulkan.dll` → `vulkan-1.dll` even though inference runs CPU-only (`nGpuLayers: 0`); the build ships a bundled Vulkan loader (`tools/fetch_vulkan_loader.ps1`, `windows/CMakeLists.txt`) so machines without a Vulkan-capable display driver can still load llama.cpp at all.

Target platforms: Android (4 GB RAM / 32 GB storage minimum), Windows (8 GB RAM), Ubuntu (8 GB RAM).

## Core Constraint: Offline-First

Every feature must work with zero network connectivity. Before adding any dependency or API call, verify it works fully offline.

**Amended 2026-10-12 at the user's request:** the core stays offline and P2P,
and a school may add an optional **cloud plug-in**: off by default, never
needed by any feature (`lib/collaboration/cloud/cloud_sync.dart`). Records
(assignments, answers, grades) are queued in `cloud_outbox` as they are made
and sent only when a `CloudSyncAdapter` is plugged in by overriding
`cloudSyncAdapterProvider`. Each record has a stable id (`submission:<uuid>`,
`grade:<uuid>:<version>`), so the server must treat a repeat as a no-op. An
outbox row names a record only; its content is read at send time, so a
deleted record is dropped, not sent.

**Amended 2026-10-13 at the user's request:** this repo now has the school
cloud's server (`backend/`, FastAPI, one database per school; contract in
`docs/CLOUD_API.md`) and the app's HTTP adapter for it. The server is the
cloud plug-in's backup and recovery copy, **not** a sync hub: it stays off
by default, no feature may depend on it, and P2P stays the primary path.
Nothing secret ships in the app; a device joins a school's cloud only with
a one-time code. The hosted Kigali backend may differ; the adapter is the
one place to change. Security model: `docs/SECURITY.md`. **Amended 2026-10-21 at the user's request (stop-gap until the official
curriculum database arrives):** an optional **online topic look-up**
(`lib/curriculum/online_topic_lookup.dart`). Off by default; a teacher
switches it on (Teachers → Look up topics online). When on and connected, a
"What is …?" question that no bundled lesson or pack covers is answered from
Wikipedia's introduction and lead picture, marked "not from your syllabus"
and credited (CC BY-SA). Only the question is sent; the emotional-safety
check runs first; non-school pages (films, songs, sport…) are refused. No
feature depends on it. Whole-topic explanations — every curriculum lesson
(`TopicExplanation.fromLesson`) and reviewed packs in
`assets/topic_explanations/` — are shown as written, without waiting for the
model. Lesson diagrams added from Wikimedia Commons are bundled
(`assets/topic_explanations/images/`, credits in `diagrams.json`), never
fetched at runtime.

**Amended 2026-10-21 at the user's request (quality for school roll-out):**
an optional **online AI tutor**. The school's tutor service
(`backend/otic_cloud/tutor.py`, `uvicorn otic_cloud.tutor:app`) answers with
Claude (`claude-opus-5-5`); the API key (`ANTHROPIC_API_KEY`) and the
guardrail system prompt live only on that server, never in the app. The app
side is `lib/ai_core/online/online_tutor.dart`: off by default, a teacher
turns it on (Teachers → Online AI tutor, with the server address and an
optional `OTIC_TUTOR_TOKEN`). Whole-topic lessons still show first and
instantly; other English questions go to the online tutor, grounded in any
matched lesson; any failure (offline, no key, timeout) falls back to the
on-device model, and the service is skipped for a minute after a failure.
Only the question, recent chat and lesson text are sent. This is the one
exception to "no hosted LLM API" below. The rules below apply to everything
else. This means:

- No calls to OpenAI, Anthropic, Google, or any hosted LLM API
- No Firebase, Supabase, or cloud sync
- SQLite or local file storage only (no cloud databases)
- Offline STT/TTS only (e.g., Vosk, Coqui, or platform-native offline engines)
- Certificate/badge PDF generation must work locally (e.g., jsPDF, PDFKit)
- Updates deploy via USB drive or local school server, not the internet

## Planned Architecture

When code exists, it will follow this structure:

```
ai-connect-africa/
  apps/
    desktop/          # Electron app (Windows + Ubuntu)
    android/          # React Native or Flutter app
  packages/
    ai-core/          # Local LLM inference wrapper — LiteRT-LM on Android, llama.cpp on desktop
    learning-engine/  # Learning paths, adaptive logic, mode routing
    memory-engine/    # Student profile, compressed summaries, local storage
    voice/            # Offline STT + TTS integration
    simulation/       # Domain simulations (science, math, business, etc.)
    gamification/     # Points, badges, streaks, achievements
    certification/    # Offline PDF certificate generation
    collaboration/    # Local network peer collaboration (no internet)
    safety/           # Emotional safety detection, prompt safety
  data/
    models/           # GGUF model files (gitignored, distributed separately)
    knowledge/        # Seed curriculum content
```

## AI Tutor Behavior Contract

Every AI response must follow this pipeline — do not short-circuit it:

```
Answer → Clarify → Practice → Apply → Create → Reflect
```

OTIC is a mentor, not a search engine. It must never stop at answering.

## Learning Modes

Four modes are routed through the same AI pipeline:

| Mode     | Purpose                        | Outcome            |
|----------|--------------------------------|--------------------|
| Learn    | Understand concepts            | Conceptual clarity |
| Practice | Exercises, challenges          | Retention          |
| Apply    | Real-world scenarios           | Practical competence |
| Create   | Build projects                 | Creation           |

A fifth "Teach back" mode (student explains → OTIC scores) was removed — it was
a bolt-on that bypassed the tutor pipeline entirely, calling the engine with its
own prompt. Don't confuse it with the Teacher *role*/dashboard, which stays.

## User Roles

`Guest` → `Student` → `Teacher` → `Admin`

- Guests: no saved state, no certificates, demonstration only
- Students: full learning features, memory, certificates
- Teachers: read student data, create groups/quizzes, cannot modify platform
- Admins: the school's records, no learning features. Admin came back as a
  separate role on 2026-10-06 (it had been folded into Teachers on
  2026-10-01). One Admin per school, on whichever device they use — see
  **Admin and teaching assignments** below. `/admin` is the Admin section
  (`lib/features/admin/`), behind the Admin's own PIN, not the Teachers PIN.
  Since 2026-11-02 Staff access (`/teachers`) always shows "Admin sign
  in", whether or not a teacher is signed in (it is not in the side menu),
  and `/admin` opens even before anyone has onboarded on the device.
  Admin PIN recovery codes were removed on 2026-11-02 at the user's request:
  no code is made or shown, there is no "Forgot PIN?", and a forgotten
  Admin PIN can't be reset in the app. The `admin_identity.recovery_*`
  columns stay (always null) so no schema change was needed. The home page no longer shows the
  class quick-access card (My notes / Assignments / Join class); those are
  in the side menu, and the card stays on My notes.
- **Teachers** (`/teachers`, `lib/features/teachers/teachers_screen.dart`)
  is where teachers sign in, plus their tools and the device/packages
  info. It is gated by the Teachers PIN only, not by a profile.

### Shared devices, classes and the teacher PIN

Devices are **shared**: learners take turns on one classroom PC/tablet.

- **Active learner** is the id saved in `SharedPreferences` (`active_student_id`),
  resolved by `resolveActiveStudent`. It falls back to the most recently
  active profile on installs that predate it. Every screen reads it through
  `activeStudentProvider`.
- **Switching** (`LearnerSwitcher.switchTo`, `/learners`) is a privacy
  boundary. It resets the chat thread, the tutor memory and the engine KV
  session. It also takes the new learner's language and re-locks the teacher
  area.
- **Adding a learner** uses `StudentNotifier.addLearner`, which always inserts
  and never switches. `createProfile` stays onboarding-only and keeps its
  "update instead of insert" guard.
- **Classes/streams** live in the `class_groups` table plus
  `students.class_group_id`. A learner is in at most one; a stream is a
  separate row, e.g. "S2 East". Progress rollups are computed on read from
  `topic_progress` and never stored. Subjects stay device-wide.
- **No teacher device.** Every device can do teacher duties; what a person
  can do comes from their role and PINs, not from the device. The teacher
  is the app's manager (subjects, materials, classes, learners, sync,
  updates). Removed 2026-10-06 at the user's request: the Co-teaching and
  Standby device screens (routes redirect to `/teacher/sync`; the roster
  and failover code stay — the roster is the cross-device teaching
  assignment), package details and the Updates section on Teachers
  (packages show one "Installed" checkbox), and the name "Class sync" (it
  is "Sync" in the UI). Also removed: the old "one teacher
  device per school" gate. Every device may host classes, join others'
  classes (never its own), co-teach and be a standby; don't reintroduce a
  device-type gate. `sync_identity.device_role` is kept as a record only,
  and `/teacher-setup` and `/student-device` redirect to Teachers.
  Lesson materials lists and deletes only this device's own notes
  (`class_group_uuid IS NULL`), never ones received for the same subject.
- **Teachers PIN** (`teacher_pin.dart`) is one PIN every teacher on the
  device knows. It gates `/teacher*`, `/teachers` and `/admin*`. It stores
  only a salted hash, and with no PIN set nothing is gated. It keeps
  learners out; it is not real security.
- **Teacher profiles (schema 22).** Several teachers share a device; the
  Admin adds them (`AdminService.addTeacher`), and each signs in on
  Teachers with their own PIN (`teacher_profiles.dart`).
  - `/teacher*` (the teacher tools) needs a teacher signed in
    (`activeTeacherProvider`, in memory only) and otherwise goes to
    Teachers. Signing out happens with every learner switch and reset, and
    `kSessionLife` (60 min) after signing in. The Admin session works the
    same way.
  - The `owner_teacher_id` columns from schema 22 are no longer used for
    permissions; teaching assignments are (below).
- **Learner PIN (schema 23).** A learner may set "My PIN" (Settings →
  Student Profile; `students.pin_salt`/`pin_hash`, `learner_pin.dart`).
  Switching the device to them asks for it (`LearnerPickerScreen`). A
  teacher clears a forgotten one from Teachers → the learner's row.
- **Admin and teaching assignments (schemas 24–25).** Every device runs
  the same app; there is no school server.
  - Only the Admin creates or changes teachers, classes/streams, subjects,
    teaching assignments (teacher × class/stream × subject × year/term),
    learners and enrolments (learner × class/stream × year; re-enrolling
    withdraws the old one, never deletes it). Every change needs an
    `AdminSession`, which only the Admin PIN yields (`AdminService`).
  - A teacher's reach follows from their assignments (`TeachingScope`):
    they upload only to subjects they teach, change and share only the
    notes they uploaded (`note_owners`), share only into classes they
    teach that subject to, and see only learners of those classes. Shares
    no assignment covers are dropped (`pruneShares`) whenever assignments
    change, so Sync stops serving them.
  - **Teacher-made subjects (schema 36).** Lesson materials → "Upload a
    PDF" lets a signed-in teacher pick one of their subjects or name a new
    one, made on the spot and recorded in `teacher_subjects` (local only,
    never in Admin records, so an Admin sync leaves it alone). It lets that
    teacher upload and change notes there (`TeachingScope.mayUpload`);
    sharing into a class still needs a teaching assignment. Removing the
    teacher or deleting the subject drops the row. Students get "Take quiz"
    on each note in My notes once it has questions.
  - Schema 24 turned the old ownership into assignments, enrolments and
    note owners, so existing teachers kept their access. Learners and
    teachers have portable `uuid`s (set by a trigger on insert).
  - **Admin sync** (`lib/collaboration/admin/`) is one way: from the
    Admin's device to one the Admin picks (it types the code + address the
    Admin shows; the Admin taps Accept). The whole set of records is
    signed with the Admin key; a receiver pins that key on its first
    records and takes only higher versions; applying is one idempotent
    transaction. Teachers and learners are added or updated, never
    deleted; assignments and enrolments are replaced whole. With a 12+
    character passphrase the Admin's details travel sealed (PBKDF2 600k)
    so the Admin can take over there. A device holding records is never
    set up as a second Admin.
  - A device whose learners all came from the Admin and where nobody has
    picked themselves yet opens "Who's learning?".
  - **Subjects (schema 30).** A school subject's card icon and colour are
    picked from its name, locally (`subject_style.dart`; rows still on the
    old indigo default are styled from the name on display). The Admin can
    delete built-in subjects: they are hidden (`removed_subjects`, carried
    in Admin records) and their name is freed; a school "Chemistry" made
    after that gets the id `chemistry_school`, never the built-in's id.
  - A school subject has no Lessons tab: its content is its notes, one
    per uploaded file on the subject's Notes tab (never per section), and
    its card counts notes (`noteCountsProvider`). My notes and the chat's
    class-notes sheet group notes under each subject with its icon/colour.
- **Class Teachers (schema 35, 2026-10-13).** The Admin enrols each Class
  Teacher (their own name and PIN, signing in on Teachers like any teacher)
  and gives them classes/streams (`class_teacher_assignments`, in the Admin's
  records). Registering learners into those classes/streams is all the role
  allows (`Policy` → `RegisterLearner`).
  - It's separate from teaching subjects: one person may hold both.
  - They register on their own device (Teacher → Register learners,
    `ClassTeacherService`), which writes the learner, the enrolment and a
    `learner_registrations` row.
  - Registrations ride the next Admin sync **to** the Admin's device,
    sealed with the code's secret. The Admin's Accept prompt names them,
    and `AdminRecords.takeRegistrations` keeps only classes that teacher was
    given (others are audited as refused).
  - The records that come back mark them sent. Unsent ones keep their local
    enrolment until the Admin takes them.
  - The Admin sees "registered by" on each learner.
- **Class assignments (schema 26).** A teacher adds one in Lesson
  materials; it is a `~assignment` row of a note, so it is signed and goes
  only to the classes the teacher shares it with. Learners answer on
  Assignments; answers ride their progress report to the teacher on Sync,
  and the reply carries back the grades of exactly those answers
  (`class_assignments.dart`). Answers are written once with a stable id
  (a new answer is a new row; created vs received times kept apart);
  grades change only with a higher version; answers to an assignment not
  shared with that class are refused.
- **Homework, holiday assessments, timing (schema 32).** An assignment
  has a type (Assignment / Homework / Holiday assessment), an optional
  opening and closing time, and an optional time limit, all inside its
  signed JSON (keys written only when set, so plain ones read as before).
  A PDF can be attached: it becomes the assignment note's original
  (`NotePdfStore.recordOwn`), so it syncs and opens like any note PDF.
  - Timed (a limit or a closing time) means one attempt: Start records
    the time in `assignment_attempts` (with the draft, saved while
    typing), and it is handed in on Submit or, when the limit or closing
    time comes first, automatically as the draft stands, stamped at the
    deadline (`submitExpired`, also run when Assignments opens).
  - The start time rides the answer to the teacher (`started_at`), who
    sees started/handed-in times and "late". Times are the learner
    device's clock.
- **Report follow-ups (schema 33, 2026-10-13).** There is no exam mode:
  assessment is continuous, so the tutor is never switched off.
  - **Tutor used on answers.** `assignment_submissions.tutor_used` is true
    when the tutor replied while the learner worked on it. For a timed
    one, that window runs from Start; for an untimed one, from when the
    learner first saw it on Assignments (`markSeen`, an
    `assignment_attempts` row with no draft).
    - `recordTutorReply` stamps `assignment_attempts.tutor_at` once per
      reply, so an attempt handed in by itself still knows.
    - Null means unknown (never seen there, or an older build). As with
      quizzes, there is no "without tutor" label.
  - **Old builds and clocks.** Reports carry `sent_at` (the learner
    device's clock), left out of `reportDigest`. A report without it is
    shown as "last sync from an older app".
    - Class progress and the gradebook name a clock more than 5 minutes
      off (`clockNote`).
    - A timed answer without `started_at` reads "older app: not timed".
  - **Extra help for one learner** (`learner_support`,
    `learner_support.dart`): from Class progress → Send help, a teacher
    who teaches that subject to the class (`Policy` → `SupportLearner`)
    sends a message, a note shared with the class and/or that topic's quiz.
    - It rides only the reply to that learner's own progress report, never
      a note channel, so classmates' devices never get it. Like grades, a
      higher version wins; withdrawing bumps it.
    - The learner sees it at the top of Assignments. Opened/done ride the
      next report (`support`).
    - The teacher sees the quiz score on the topic when sent → now, with
      tutor use.
- **Roadmap agreed 2026-10-06** (user's P2P/RBAC spec). Done: Admin role,
  teaching assignments and enrolments, one-way Admin sync, assignment
  submission and grade sync, session expiry, tutor sources, the memory
  check before loading the AI. Done 2026-10-07 (architecture plan): one
  `Policy.can` for permissions (`lib/core/policy/`), PBKDF2 PINs (old
  hashes upgrade on next entry), model manifests with SHA-256 checks
  (`model_manifest.dart`, `model_verifier.dart`), and device registry and
  revocation (schema 27, `device_registry.dart`): every Sync request is
  signed by the device key; revoking per class (Teacher → Sync → Devices)
  or school-wide (Admin → Devices, carried in Admin records) refuses the
  device and replaces the class key, sealed to each trusted device's
  X25519 key. Done 2026-10-07: durability status (schema 28,
  `channel_receipts`): after a teacher sync a student device posts the
  subject versions it holds (`api/v4/sync/ack`, best-effort), and Lesson
  materials shows each shared note as "On N devices" or "Only on this
  device"; the report reply lists the answers the teacher holds, so a
  learner's answer reads "with your teacher" before it is graded. Not
  done yet: teacher recovery
  (per-teacher signing keys, one recovery passphrase per teacher),
  encrypted local storage (SQLCipher + OS secure storage), a signed audit
  log, per-learner peer authorization, archiving materials, and
  measurements on minimum hardware. Stay P2P — the school cloud
  (`backend/`) is an optional backup, never a hub every device needs.

### Teacher notes → tutor (offline knowledge base)

Uploaded files become plain text, which is split into sections and then into
~500-char rows in `topic_resources`. Only a PDF's original is kept (see
**Original PDFs** below); other files are not. That
split is for the tutor's search only. People see, share and delete **one
note per uploaded file** (`topic_resources.document_title`). Never list the
per-heading sections or chunks in the UI.
`topic_resources_fts` is an external-content **FTS5** index: porter
tokenizer, BM25 ranking, kept in sync by triggers. It comes from the SQLite
that `sqlite3_flutter_libs` ships. It is created by raw SQL in
`OticDatabase._createResourceSearchIndex`, because drift has no FTS5 table
class, so `createAll` doesn't know about it.

**PDFs, including scans.** `ResourceImportService` reads a PDF page by
page with PDFium (`pdfrx`, bundled at build time, never downloaded at
runtime; `lib/services/pdf/`). The hand-rolled `extractPdfText` is only
the fallback for files PDFium can't open.
- A page with real embedded text uses it. Any other page is rendered and
  read by on-device OCR (`lib/services/ocr/`):
  - Android: ML Kit, with the Latin model bundled in the APK.
  - Windows: built-in `Windows.Media.Ocr` through the `otic/ocr` channel
    (`windows/runner/ocr_channel.cpp`, on a worker thread).
  - Linux: the system `tesseract`, if it's installed.
- OCR text passes the same `looksLikeRealText` gate, so garbage is dropped.
  The teacher is told how many pages were scanned, marked or unreadable.
  Cancel stores nothing (for a PDF read before it is saved; see below).
- **Uploads never wait on reading.** Teachers add several files at once
  to an existing subject (a clashing name gets " (2)"). A PDF that can be
  kept is saved and listed at once (marker row only), so it opens straight
  away; `NoteTextIndexer` (`lib/services/notes/note_text_indexer.dart`)
  then reads its pages in the background, 10 per batch, saving progress
  after each batch and resuming at launch. PDFs over 40 MB or that PDFium
  can't open are still read before saving.
- **Diagrams:** the tutor can't see pictures. A caption line ("Figure 3.2
  …") or a picture region (ink that no text covers) becomes a marker
  paragraph, e.g. `[DIAGRAM: Figure 3.2 The heart | page 14 of the PDF
  "Biology Term 1"]`.
  - The marker travels in the chunk text, through FTS and class sync.
    `chunkContent` never splits one.
  - When a retrieved marker relates to the question, `TutorPipeline`
    appends "Diagram: see …, page 14 of the PDF … open the PDF on your phone
    or look in the printed copy".
  - That line is shown once per topic, is added after `_remember` so it
    never enters memory, and is added before translation.
  - Page numbers are PDF page numbers, so the caption comes first.
  - The markers also go to the chat as data (`TutorResponse.diagrams` →
    `ChatMessage.diagrams`). The bubble shows "Open page N"
    (`DiagramPageButtons`) only for PDFs this learner may open, so a
    translated reply still opens the right page.

**Original PDFs (kept, viewable, synced).** Reversed 2026-10-01 at the user's
request: the tutor uses the notes as a source of truth, so people must be
able to read them as uploaded.
- At upload, before any page is read (never on cancel or failure),
  `NotePdfStore` (`lib/services/notes/note_pdf_store.dart`) stores the file
  as `<app support>/otic_note_pdfs/<sha256>.pdf`, up to 40 MB.
- It also writes one **marker row** in the note: `topic_key = '~pdf-original'`,
  content `[PDF: sha256=… | pages=… | bytes=…]`.
  - Because the marker is part of the note, the teacher's signed channel
    digest covers it. It is shared and unshared, relayed verbatim by
    classmates, deleted, and carried in a failover ledger exactly like the
    note.
  - The `~` keeps it out of `MIN(topic_key)`. FTS search, `chunksForSubject`
    and the notes text exclude **every** `~` row (`kRecordTopicPrefix`).
- **Quiz questions** are `~quiz` rows of the same note (`[QUIZ: page=N] {json}`,
  topic inside the JSON), written per **topic** (section heading) from the
  note's stored text by `NoteQuizBuilder` as it arrives — up to 8 per topic,
  the last topic waiting until reading ends (resumed at launch, own notes
  only, retried — never skipped — when the engine fails).
  - Each question is checked before it's kept
    (`NotesQuizGenerator.checkedQuestion`): options shuffled, the key must be
    supported by the passage, and the model, shown only the passage, must
    pick the same answer. Otherwise it's dropped.
  - They sync, share and delete with the note; Quiz shows them instantly,
    by topic (`NoteQuizStore`).
  - Finished rounds are saved per learner and topic in `quiz_results`
    (schema 21, `quiz_scores.dart`) and shown under Quiz scores in
    Achievements.
  - **Tutor used (schema 31).** An answer given after the tutor replied to
    the learner (and after the question appeared) is marked "Tutor used"
    (`tutor_use.dart`: chat replies, including while streaming, and
    Practice scenario feedback; in memory, cleared on learner switch). It
    records that they happened together, never that the tutor gave the
    answer, and can't see help from outside the app, so there is no
    "without tutor" label. `quiz_results.tutor_used` counts
    them; null (older rounds) means unknown. The latest round per topic
    rides the progress report as counts (`quizzes`, only when there are
    any) to Teacher → Class progress.
- **Bytes** come from `api/v4/sync/file` (`ClassShareServer._noteFile`).
  - It serves a file only if its marker is in a channel the requester may
    pull.
  - The client (`SelectiveSyncManager._fetchMissingPdfs`) downloads only
    files it doesn't have, and stores them only if they hash to the signed
    SHA-256.
  - It is best-effort: a build without the endpoint answers 404, and the
    note still syncs as text.
- `collectGarbage` deletes files no marker refers to. It skips files younger
  than 10 minutes, because an import may not have recorded them yet.
- **Viewer:** `/note-pdf` (`NotePdfScreen`, pdfrx `PdfViewer`). It is opened
  from Lesson materials (teacher), Class sync → Notes as PDFs (student) and
  the tutor's page buttons.
- **Known gaps:**
  - PDFs uploaded before this change have no original. Re-upload them to
    view.
  - A promoted standby has the markers but not the bytes, so it can't serve
    files until they are re-uploaded. Students keep theirs.

`TutorPipeline` searches it on every turn using the matched curriculum
lesson's title and key terms plus the student's words. The notes share the
existing 700-char notes slot, because the question sits at the end of the
prompt and the engines clip from the end. Notes *supplement* the model; they
do not override it. There are no embeddings: a third model does not fit
4 GB Android.

### Class sync (teacher ↔ students ↔ classmates over the local Wi-Fi)

Notes are shared only within one **school + class/stream + subject**.
The code is in `lib/collaboration/sync/` (one server, `ClassShareServer`,
with a teacher role and a classmate role), with tests in
`test/class_sync_e2e_test.dart` and `test/class_crypto_test.dart`. Don't
loosen any of these rules:

- **The sharer approves every join.** After a correct code, the joining
  device waits (2 min) while the teacher — or the sharing student — sees
  its learner's name and taps Accept/Decline (`JoinRequestsCard`). Decline
  or no answer hands over nothing.

- **School.** It's set in Teachers → School on the device the teacher uses. A
  joining device adopts it at its first join and refuses classes from any other
  school.
- **Joining.** The teacher's Class sync screen (Teacher → Class sync,
  PIN-gated) shows a join code (30 min, locked after 20 wrong tries). The
  student types it on **Class sync** in the main menu (`/class-sync`,
  `ClassSyncScreen`), deliberately outside `/teacher*` so no PIN is needed.
  Either side can be any Android phone or Windows/Linux PC.
  - The sharing device is found by UDP broadcast + mDNS. Phone hotspots
    often block both, so the teacher screen also shows its IP address and
    the student screen accepts it typed in (`sync_address.dart`).
  - The code never crosses the network. A PBKDF2-stretched proof does. One
    random code per sharing session (`Random.secure`), 30 minutes.
  - The reply gives the device the class key and pins the sharing device's
    Ed25519 public key. The class is created locally with the teacher's
    `groupUuid`.
- **Serving.** `ClassSyncDao.sharedChunks` is the only rule. A chunk is
  served only if it was written on this device (`class_group_uuid IS NULL`)
  *and* has a `resource_shares` row for that class.
  - Notes are never shared until the teacher ticks a class (Lesson
    materials → Share with classes). **Amended 2026-11-02 at the user's
    request:** an upload counts as that tick — new files are shared at
    once with every class the teacher teaches that subject to
    (`_shareWithAll`, still through `Policy` → `ShareNote`); the teacher
    unticks classes afterwards with Share with classes.
  - Background note-quiz writing stays out of the brain while a learner
    uses it: chat replies and every `HybridModelOrchestrator.runExclusive`
    job (builders, labs) count, for `chatQuietFor` after they finish, and a
    question yields between its two model calls. llama.cpp can't stop a
    decode once started, so waiting is the only lever.
  - A learner device asks the teacher for new materials every
    `kAutoSyncEvery` (30 s) while the app is open and the teacher is
    reachable (`LearnerSyncController`), not only when discovery changes.
  - Received notes are never served *as this device's own* (teacher role).
- **Teacher-signed manifests.** Every channel (class+subject) carries the
  teacher's Ed25519 signature over school, class, subject, digest and a
  **version that only goes up** (`served_channels`, bumped on every digest
  change including an unshare). Receivers keep it in `sync_state`.
- **Classmates pass notes on — verbatim only.** A student device that
  joined through the teacher can share that class's received notes
  (Class sync → Share with classmates, own code + Accept). Rules:
  - Only to devices that **already joined the class through the teacher**
    (`joinClassmate` refuses otherwise). A classmate can't admit anyone.
  - A relayed subject is taken only if its manifest verifies against the
    **pinned teacher key**, its chunks hash to the signed digest, and its
    version is **strictly newer** than this device's (including a
    tombstone left when the teacher unshared it). A classmate can't edit,
    invent or remove anything, and can't roll back a subject this device
    already synced. Known gap: a device that hasn't synced with the teacher
    since an unshare has no tombstone yet, so it still accepts that subject
    from a classmate until its next teacher sync.
  - A classmate sync never deletes; only a teacher sync drops subjects.
  - Pulling from a classmate needs the session token they handed over at
    Accept (requests are MAC'd with it), not just the class key.
- **Every request** is MAC'd (class key; classmate role: session token) and
  names the school. Anything wrong gets the same bare 404.
- **Every reply** is AES-GCM encrypted with the class key and bound to the
  requester's nonce. Teacher replies are also signed with the teacher key,
  so a classmate can't pose as the teacher and old replies can't be
  replayed.
- **Receiving.** Each subject is replaced whole, in one transaction, and
  only if every chunk verifies. Edits and removals from the teacher
  propagate; removed subjects leave a tombstone row.
- **Progress back to the teacher.** On every sync *with the teacher*, the
  student device sends an encrypted report per learner of that class on
  the device (`progress_report.dart`): totals, per-topic mastery,
  strengths/weaknesses — never chats. The teacher stores the latest per
  learner in `member_reports` and shows it in Teacher → Class sync →
  Class progress. Deleting the class clears it.
- **Shared devices.** Tutor retrieval sees this device's own notes plus
  received notes for the **active learner's** class only
  (`TopicResourceDao._visibleTo`).
- **Co-teachers (schema 19).** A class's root (host) device can invite
  other teachers' devices as co-teachers for specific subjects
  (`api/v4/coteacher/join`, own code + Accept; `CoTeacherDao`).
  - Allocation is **disjoint**: one signer per (class, subject), enforced
    at invite time.
  - Root publishes a root-signed, versioned `ClassRoster`
    (`class_crypto.dart`) saying which key may sign which subject. It
    travels in join bundles and handshakes and is forwarded verbatim by
    co-teachers and classmates. Only root ever signs one.
  - A manifest is accepted only from the key the roster allocates its
    subject to. Undelegated subjects stay root's.
  - Version floors are **per signer** (`sync_state.signer_versions_json`),
    so handoffs are safe both ways.
  - A signer's own sync only drops its own channels (`dropChannelsForSigner`).
  - Revoking a co-teacher bumps the roster, and clients drop its channels
    on their next sync with a device holding the newer roster.
  - Co-teachers can't admit students, publish a subject catalog, or
    receive progress reports.
  - A delegated class lives in `co_teaching_classes`, never in
    `class_groups`.
- **Host failover (schema 20).** A standby can take over as the root
  (host) device (`P2PFailoverService`, `lib/collaboration/sync/p2p_failover_service.dart`).
  - The teacher sets a failover passphrase (≥12 chars). A standby pairs
    with a code + Accept (`api/v4/failover/pair`), then pulls the host
    ledger (`api/v4/failover/ledger`, requests signed by the standby's
    pinned key, replies signed by the root key).
  - The ledger holds the root **signing seed**, classes + keys, served
    versions, roster/co-teachers, subjects, shares and the shared notes,
    AES-GCM sealed under a PBKDF2 (600k) passphrase key — never a class key.
    The root private key therefore leaves the host device, protected
    only by the passphrase.
  - `promoteToHostNode` opens it offline and becomes root under the same
    key at `hostGeneration + 1`. Served/roster versions are lifted to
    `generationFloor(gen)` so they outrank the old device. Students change
    nothing; root handshakes carry `host_epoch`, and a student refuses a
    lower one (`class_groups.host_epoch`), so a returning old device can't
    drop notes.
  - Refused on devices serving their own classes, and (when the key
    changes) on devices that joined classes as a student — their key names
    them in progress reports.
    Not carried: `member_reports` (re-sent next sync) and the standby list.
  - Screens: the host side is the "Standby device" card on Teacher →
    Class sync (passphrase, pair code, standby list, save backup to a file);
    the standby side is `/teacher/standby` (`standby_screen.dart`: pair,
    back up while open, take over from the held backup or a file).
- **Android keeps sharing in the background.** While any `ClassShareServer`
  runs, `ShareKeepAlive` (ref-counted) starts `ClassShareService.kt`: a
  `connectedDevice` foreground service with an ongoing notification, a
  Wi-Fi lock and a partial wake lock (capped at 3 h). It stops with the
  last server. If Android refuses it, sharing still works on screen.
- **Speed (no protocol change).**
  - The server caches each class+subject's envelopes and digest
    (`ClassShareServer._cachedChannel`). The cache is cleared by drift
    table updates on `topic_resources`, `resource_shares` and
    `class_groups`. Raw-SQL writes to those tables don't notify drift, so
    follow them with a drift write.
  - Every sync, join and standby call first drops addresses that don't
    accept a TCP connection within 2 s (`SelectiveSyncManager.reachable`).
  - Changed subjects are fetched 4 at a time, but each one is still
    verified and replaced on its own, in order.
  - Unchanged subjects were already skipped by digest.
- **Protocol v4 only.** Devices on older builds can't sync with upgraded
  ones.

## Student Memory Engine

Store compressed summaries only — never full conversation logs. Stored fields: age, interests, learning style, strengths, weaknesses, projects, achievements, certificates, progress, goals. Storage is local SQLite per device.

## Voice Learning

- Use offline STT/TTS only (no cloud speech APIs)
- Store converted text only — never store audio recordings

## AI Model Files

Model files are large and are never committed to git — always gitignored. Two distribution paths now exist:

1. **USB / local school server** (original, still supported) — the model file is transferred by hand and dropped into the platform's expected folder (see `ModelManager`/`AfriSlmModelManager`). No internet needed anywhere in this path.
2. **Bundled in the GitHub Release zip** (Windows, added for a plug-and-play download) — the release zip ships with a `models/` folder next to the executable, containing the brain (`qwen2.5-coder-1.5b-instruct.gguf`) and `afrislm-0.8b-q4_k_m.gguf`. Both model managers check this bundled path automatically (`<exe dir>/models/...`), so the app works immediately after extracting, no manual install step. The app itself still runs fully offline once downloaded — this only changes how the model bytes are *obtained*, not the offline runtime constraint.

Bundling a model into a public release requires its license to permit redistribution — verify before adding a new model here (Qwen2.5-Coder-1.5B is confirmed Apache-2.0).

| Role | Platform | Format | Model | Size |
|------|----------|--------|-------|------|
| Brain (tutor + code) | Android | `.litertlm` int4 (LiteRT-LM) | Qwen2.5-Coder-1.5B-Instruct | ~1.1 GB |
| Translation | Android | `.litertlm` int8 (LiteRT-LM) | AfriSLM 0.8B (converted) | ~0.9 GB |
| Brain (tutor + code) | Windows, Linux | GGUF 4-bit (llama.cpp) | Qwen2.5-Coder-1.5B-Instruct | ~1.1 GB |
| Translation | Windows, Linux | GGUF 4-bit (llama.cpp) | AfriSLM 0.8B Q4 | ~0.6 GB |

The app must detect whether the model file is present at startup (checking the bundled path before falling back to the USB-installed path) and show a clear "Model not installed — transfer via USB" screen rather than failing silently when neither is found.

Translation needs no external server. On desktop `llm_llamacpp` loads the AfriSLM GGUF in-process; on Android LiteRT-LM loads its `.litertlm`. There is no separate runtime to install.

## Local History (Student Memory)

Use SQLite via the `drift` Flutter package. Store compressed summaries only — never full conversation logs. One database file per device, never synced.

Stored fields: `userId`, `age`, `interests`, `learningStyle`, `strengths`, `weaknesses`, `activeProjects`, `achievements`, `certificates`, `progressByTopic`, `goals`, `lastActive`.

### Chat recall (Recent chats)

Reopening a past chat is backed by **one small JSON file per session** in
`<app storage>/otic_sessions/`, indexed by the `chat_sessions` drift table
(`ChatSessionDao`). The split matters: the sidebar lists chats from the index
alone, so listing never opens a file, and a session body is read only when
that chat is actually reopened.

Each file (~2–8 KB, hard-capped) holds a **compressed recall, never a
transcript** — a clipped question/answer gist plus a `ConversationMemory`
snapshot, which is what lets a reopened chat resume at the right stage
instead of cold-starting. `SessionRecall` enforces the clipping, so the file
cannot grow into a conversation log however long the chat runs.

`SessionSummaries` is unchanged and still writes one row per assistant reply —
topic progress and the teacher dashboard are built on it. It is no longer what
the Recent chats sidebar reads.

Note: nothing in this app issues `PRAGMA foreign_keys = ON`, so the
`onDelete: cascade` declared on child tables is never enforced. Deleting a
student must clear dependent rows explicitly — `LearnerDataWiper`
(`lib/services/learner_data_wiper.dart`) is the one place that does this for
every table actually scoped to a student; route both the Teachers per-learner
delete and the Teachers "Reset all student data" action through it rather than
deleting a student row directly. Its `wipedTableNames` set is checked against
the database's own table list in `test/learner_data_wiper_test.dart`, so a
newly added student-scoped table fails that test until it's classified as
wiped or kept (kept = shared resources: `topic_resources`, `custom_subjects`,
`class_groups`, the translation cache, `sync_state`).

## Create → Projects (full-stack project folders)

Every creation is a **real folder**, and the disk is the source of truth. There
is no index table. `ProjectStore` (`lib/services/projects/project_store.dart`)
writes `<root>/<learner>-<id>/<Websites|Applications|Python|Guided>/<slug>/`,
each folder with an `otic-project.json` manifest. `root` depends on the
platform:

- **Windows / Linux:** `Documents/OTIC/Projects`, which opens in Explorer or
  VS Code.
- **Android:** `<app docs>/projects`, which is private, so Projects exports
  zips or shares them instead.

Folders cut, deleted or pasted in Explorer show up on the next list.

- **Describe first, pick from a list second.** The App and Website chat
  builders open on a free-text prompt ("describe the app you want").
  - The coder model writes the **page** from that description
    (`generateAppHtml` / `generateSiteHtml` in `ai_coder_service.dart`).
    If it's missing, refuses or fails, the build falls back to the template
    for the classified type — never a blank screen.
  - The description is also classified **locally, with no model call**
    (`classifyAppType` / `classifySiteTemplate`, scored keywords). That picks
    the app type whose backend resources and fallback template the build
    uses. Attached pictures go into a gallery afterwards; the model never
    sees them.
  - The ☰ list picker runs the original guided questions and pure template
    build, with no model call.
- **Instant first version (2026-11-02, at the user's request).** A
  described app or website paints its ready-made template at once and is
  saved; the coder's custom page is written in the background and swapped
  into the same project folder when ready (with Undo), or offered with
  "Use it" if the learner already changed the code. A build counter
  (`_buildGen`) stops a late page landing on a newer build.
- **App templates are interactive** (`assets/templates/apps/interactive_kit.*`,
  added by `withInteractiveKit` in `_assembleAppHtml`): tabs and chips,
  hearts, a working cart and checkout, real search, "+" adds an item, a
  till on POS "Register", every bottom-bar icon opens its own screen
  (saved, cart, profile with dark mode, stats, messages…), count-up numbers,
  growing bars, ripples and confetti. Template pages only; model-written
  pages don't get it. State is kept in `localStorage` per app, best effort.
- **The project scaffold is never model-written.** The code lives in
  `lib/features/projects/scaffold/`.
  - It turns the builder's page into `frontend/` (split CSS/JS, embedded
    pictures extracted to `frontend/images/`).
  - It adds a FastAPI + SQLAlchemy + SQLite `backend/` with CRUD routes per
    app type (`resource_spec.dart`), plus a pytest suite. The backend schema
    always comes from that fixed table — the model never invents resources
    or fields.
  - It adds README / DEPLOY.md (free hosts), a Dockerfile, `render.yaml`
    and `.vscode/`.
  - After changing any scaffold, run `tools/verify_scaffolds.ps1`: it
    installs and runs every generated backend's tests.
- **One save path.** Every builder saves through `saveCreation`
  (`project_providers.dart`), which awards badges and refreshes
  `studentProjectFoldersProvider`. Achievements counts from that provider.
- **Legacy rows are synced into folders.** Older DB-row saves are
  `app_builder_projects`, the removed Block canvas's `website_projects`
  and the guided chat's `student_projects`. `LegacyProjectSync` gives each one a
  folder once, and a ledger stops deleted ones from coming back.
- **Style and pictures need no model.** Style requests ("make the text
  red") are applied through `quick_style_edit.dart` in a
  `<style id="otic-style">` block. Pictures are embedded as data URIs while
  editing (`html_images.dart`) and become real files on save.
- **A picture in the Tell-AI bar** comes with what to do with it. The model
  can't see images, so none of this sends the picture to the model:
  - "make the UI like this" → `ui_look.dart` measures the screenshot's
    pixels (theme, colours, bar, card colour, corner radius, columns) and
    restyles the page in one `<style id="otic-look">` block. It never
    copies layout or fonts.
  - "make it the logo / the background / put it in the about section /
    make it round" → `image_instruction.dart` places and styles it.
  - Only styling those can't express goes to the coder, as a CSS patch
    aimed at the placed picture (`image_instruction_runner.dart`).
- **Deleting a learner.** `LearnerDataWiper` also deletes the learner's
  project folder.

## Update Mechanism

Updates ship as packages deployable via USB flash drive or a local school LAN server. The app must support applying an update bundle without internet access.

## Development Commands

```powershell
# Get dependencies
flutter pub get

# Run on Windows desktop (primary dev target)
flutter run -d windows

# Run on Android device/emulator
flutter run -d android

# Build release
flutter build windows
flutter build apk

# Analyze code
flutter analyze

# Run tests
flutter test

# After adding a new package to pubspec.yaml
flutter pub get
```

Flutter SDK is installed at the path managed by winget (`Google.Flutter`).
After install, PATH must include the Flutter `bin` directory — open a new terminal if `flutter` is not found.

## What to Build First

Follow this order — do not jump ahead to gamification or certificates before the core tutor works:

1. Local LLM integration (brain loading + inference via llama.cpp)
2. Basic Learn mode (ask question → get mentor response)
3. Student memory (profile creation + summary storage)
4. Learning paths (auto-generate curriculum for a topic)
5. Practice + Apply modes
6. Voice learning
7. Simulation engine
8. Create mode
9. Gamification + Certification
10. Teacher dashboard
11. Admin dashboard
12. Collaboration (local network)
13. Emotional safety engine
14. Android app
15. Update deployment tooling
