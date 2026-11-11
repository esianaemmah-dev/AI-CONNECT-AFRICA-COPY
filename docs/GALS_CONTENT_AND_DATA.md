# GALS draft content and field records (schema 1)

This is an implementation contract for a **draft for Oxfam review**, not an
Oxfam-approved adaptation. The sample pack contains original English text and
credits the GALS sources without reproducing manual text or pictures. Paper
drawing and participant-led facilitation remain the activity.

## Replaceable content pack

`assets/gals/packs/catalog.json` selects the active UTF-8 JSON pack; the active
release is `gals-foundation-v3.json` (`1.0.0-draft.3`). Keep old
content versions available when replacing it: field records pin the version
used at the session. `schemaVersion` is the parser contract (integer, currently
1); `contentVersion` is an immutable release identifier (currently `1.0.0-draft.3`).
Changing a step, translation, quiz or audio mapping requires a new content
version, never an in-place overwrite. A future USB/local installer should
validate the manifest, asset paths and hashes before installing; the current
slice loads only the bundled pack and does **not** implement updates.

| Field | Rule |
|---|---|
| `packId`, `schemaVersion`, `contentVersion`, `status`, `defaultLanguage` | Required; stable pack ID, `draft`, `review` or `approved` status. This pack is `draft`. |
| `sources` | Required credit entries with name, publisher, URL and optional section/page reference; credit is not permission to reproduce a work. |
| `languages` | Required map of BCP-47 language code to review status (`draft`, `native_reviewed`) and optional reviewer/date. Only `en` exists here. |
| `programme` | Optional localized programme title and audience. The active pack introduces GALS, its draft audience and the three high-level implementation phases. |
| `lessons` | Stable lesson ID, localized title/body, and quiz questions with stable IDs, choices, correct answer and explanation. A tool lesson links both a tool and a session plan; an introduction may link neither. |
| `tools` | Stable tool ID, localized title, purpose, preparation, facilitator prompts and ordered steps. A step may have an `audio` map keyed by language. Each audio entry needs path, SHA-256, duration and review status. An absent entry means **no audio**, not synthesized or completed audio. |
| `sessionPlans` | Stable plan ID, localized title, objective, materials, facilitator tips, ordered activities with duration and optional tool/step IDs, and homework. |

Localized strings use language-code maps. Missing language variants are shown
as English with their language clearly indicated; do not silently translate
or use model output as an approved script. Before shipping a clip, check the
script and recording with native speakers and ensure the clip's hash matches
the manifest. IDs remain stable across revisions; if meaning changes, create
a new ID. Pack references resolve only against the matching content version.

## Offline field records

All IDs are device-created UUIDs. `createdAt` and `updatedAt` are UTC ISO-8601
device-clock timestamps, not trusted server times. In schema 1 the **implemented**
rows are:

| Record | Required | Optional / provisional |
|---|---|---|
| `gals_champions` | `id`, `displayName`, `createdAt`, `updatedAt` | `groupName`, `sex`, `ageBand`, `location`, `trainingAt` are optional/provisional. The UI requests a fictional alias; no real people are seeded. |
| `gals_sharing_sessions` | `id`, `championId`, `occurredAt`, `createdAt`, `updatedAt` | Location/notes are deferred. A session belongs to one champion. |
| `gals_session_tools` | `sessionId`, `packId`, `toolId`, `contentVersion` | Multiple rows allow multiple tools at one session. All four fields are required; the first slice uses one tool. |
| `gals_session_attendance` | `id`, `sessionId`, `sex`, `ageBand`, `location`, `count`, `createdAt` | Count is non-negative; categories `female`, `male`, `another`, `not_recorded` and locally entered age band/location are **provisional**, pending Oxfam's indicator definitions. This is an aggregate, with no participant identity. |
| `gals_achievement_reviews` | `id`, `championId`, `packId`, `contentVersion`, `toolId`, `reviewedAt`, timestamps | All five prompts (goal, progress, enabling factors, challenges, next steps) are optional, short local text. The row is a voluntary reflection, not proof of achievement or an impact indicator. |

A sharing session refers to a tool through `gals_session_tools`, not through a
copy of its text. The app checks that `(packId, contentVersion, toolId)` exists
in the bundled pack before saving. A past record must retain the exact pack
version it references, or display an explicit "pack unavailable" state.
`SUM(attendance.count)` is **session attendances**: someone attending twice
counts twice. Verified unique people reached is **unknown**, not that sum.
The form can save multiple sex/age-band groups in one atomic session. Use
Not recorded / Unknown when the breakdown is unavailable, and count an attendee
in only one group per event. The UI does not identify or deduplicate people.
Do not add a unique-reach number until Oxfam decides an identification,
consent and deduplication method. A row in the champion register is also not
evidence of training or peer reach.

**Specified for later, not implemented:** A `gals_consents` record would require
UUID, subject type/id, scope (e.g. photo
capture, local storage, transfer), decision, recorded-at time and withdrawal
time; optional witness/method. Consent is separate from the data it governs.
No photos or voice notes are captured by this slice.

## Boundaries and decisions

- GALS records stay in the local app SQLite database. **No GALS sync, cloud
  upload, encryption at rest, backup or GALS-specific role policy exists yet.**
  The staff route uses the app's existing teacher sign-in, which is not a
  GALS role model or a confidentiality guarantee on shared devices.
- Oxfam must confirm first languages/districts, indicator definitions and age
  bands, who may create/view/export records, data ownership and retention,
  whether and how unique reach is verified, review-form scope and source
  adaptation/media permissions. Until then, do not record relationship maps
  or attach drawings/photos/audio to field records.
- This pack is an original educational draft, not a transcription of the cited
  Oxfam publications. The linked Oxfam pages and facilitator PDF were checked
  on 11 November 2026. No actual local-language translation, audio, source
  illustrations or source photos are included; permissions for those assets are
  unknown and must be cleared before use.
