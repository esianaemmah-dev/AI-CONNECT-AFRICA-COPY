# GALS draft release: validation and handover

This is a fictional-data pilot for facilitator and champion preparation, not an
approved curriculum or a production participant register. Existing work on
`feature/gals-vision-road-journey` was extended; unrelated local changes were
preserved. Nothing was pushed, merged or deployed.

## Entry point and reuse

Open Staff access, sign in as an existing teacher, then choose **GALS · draft
field tools** (`/teacher/gals`). New installations need the existing Admin
setup and teacher provisioning. No GALS bypass or separate login was added.

GALS reuses the app's Studio page, Material widgets, Riverpod, staff route,
UUID dependency, bundled asset delivery, and Drift/SQLite database. It follows
the lesson, practice quiz and reflection pattern. The school curriculum schema
does not carry source versions or community champion identities, so GALS uses
its existing pack extension and separate tables. Teach Back was removed from
the current app; peer sharing serves that participatory purpose. School Projects,
Achievements and Certificates remain separate. Draft completion awards no
certificate and does not claim facilitator competence.

## Run and try the journey

From the repository root in PowerShell, with Flutter installed:

```powershell
flutter pub get
dart run build_runner build
flutter run -d windows
```

If the llama.cpp native hook reports missing `unzip`, add the installed Git
utility for that terminal before running Flutter:

```powershell
$env:PATH = 'C:\Program Files\Git\usr\bin;' + $env:PATH
```

Do not reset or uninstall an installation containing existing data. Use a
development device or OS account for the fictional-data demonstration.

1. Open Staff access, sign in, and open GALS.
2. Read the introduction. Select **Vision Road Journey** in the programme list.
3. Read the step cards and draw a fictional example on paper. Answer the quiz
   and enter a short fictional practice reflection.
4. Continue to Champion. Save **Fictional Neri**, optionally entering fictional
   group/location and a training date. Save lesson completion.
5. In Peer sharing, read materials and tips, then tick the activities after
   practising them. Select a date and enter a fictional location.
6. Enter an attendance category, age band and count. Use **Add attendance group**
   for additional categories, counting each attendance once. Use Not recorded
   and Unknown if the breakdown is unavailable. Save sharing on this device.
7. In Review, optionally save goal, progress, enabling factors, challenges and
   next steps; all five may remain blank. Never transcribe a private drawing.
8. In Saved, open the session and check the content version and counts.
9. Close the app, disconnect networking, reopen, sign in again and select the
   same champion. Retrieve the session in Saved and the reflection in Review.

The learning and recording flow requires neither an AI model nor a network.
Automated persistence checks close and reopen a real SQLite file; the screen
test traverses the lesson, champion, session and Saved screens. These tests do
not replace a physical-device airplane-mode usability trial.

## Source verification and permissions

On 11 November 2026 the three supplied Oxfam publication pages and the 55-page
Growing Together facilitator PDF were accessible. The integration page confirms
the three implementation phases; the methodology page supports the community-led
and inclusive framing. The other two publications provide adaptation and youth
facilitation context. Access does not establish permission to reuse every asset.

The pack credits all four sources and labels its original English adaptations
draft. Source PDFs, photos, illustrations, translations and recordings are not
bundled. Their specific permissions remain unverified. The opening visioning
outline is an original draft; no Soulmate Visioning pack is reproduced or approved.
The other three downloadable manuals were not individually verified in this
validation pass; only their landing pages were read.

## Boundaries before real participant use

- Review the lesson, quiz, five tools, suggested timings and facilitator prompts
  with Oxfam and community facilitators. Run low-literacy and accessibility trials.
- Agree demographic categories, age bands, consent/notice, safeguarding, access,
  ownership, retention, correction/deletion and backup arrangements.
- There is no GALS-specific role policy or database encryption guarantee. Staff
  navigation reuses school sign-in; the field store itself has no role boundary.
  School learner reset deliberately retains independent community records.
- Records are local only. GALS has no sync adapter, export, upload or remote
  backup, and never writes to the school cloud outbox. Unique people reached is
  unknown; attendance counts must never be presented as unique reach.
- No photo or voice-note capture exists, so there is no new media-consent control.
- Audio metadata is supported in packs, but no recordings or GALS audio player
  are delivered. Reviewed audio playback, import/hash validation and language
  selection need follow-up implementation and approved assets. English is the
  only available content language; device TTS is not a reviewed recording.
- Content replacement currently requires a new bundled version and catalog entry;
  older versions remain resolvable. There is no field pack installer.
- Per-item source mappings, explicit module identifiers, session notes/emerging
  issues and links to project objectives are follow-up work. Current content
  inherits pack-wide source, version and review status.

## Checks

```powershell
flutter test --no-pub --concurrency=1 test/gals_field_store_test.dart test/gals_journey_widget_test.dart test/gals_release_validation_test.dart test/learner_data_wiper_test.dart test/teacher_pin_test.dart test/policy_test.dart
dart analyze lib/features/gals lib/db/tables/gals_tables.dart test/gals_field_store_test.dart test/gals_journey_widget_test.dart test/gals_release_validation_test.dart
flutter build windows --debug --no-pub
```

The initial four field-store tests passed. The next run passed 36 tests and
identified one missing classification in the learner-wiper test, now repaired.
Final targeted test run: **42 passed**, including all six files in the command
above, schema migration, multiple attendance categories, the screen journey,
and file-backed close/reopen persistence. Tests used fictional data only.

Targeted Dart analysis completed with exit code 0: no errors or warnings,
12 informational `curly_braces_in_flow_control_structures` suggestions.
Windows CMake reports that the bundled `vulkan-1.dll` is absent; translation on
machines without a suitable system loader is not verified by this build. GALS
does not invoke that runtime. See the existing `tools/fetch_vulkan_loader.ps1`
for packaging the loader before distribution.

Files involved in this release (including pre-existing work completed here):

- `assets/gals/packs/catalog.json`, `gals-foundation-v2.json`, `gals-foundation-v3.json`
- `lib/features/gals/gals_pack.dart`, `gals_field_store.dart`, `gals_screen.dart`
- `lib/db/tables/gals_tables.dart`, `lib/db/otic_database.dart` and generated
  `otic_database.g.dart`; missing generated `lib/db/daos/*.g.dart` were recovered
  from Drift outputs so the existing application could compile.
- `test/gals_field_store_test.dart`, `test/gals_journey_widget_test.dart`,
  `test/gals_release_validation_test.dart`, `test/learner_data_wiper_test.dart`
- `docs/GALS_CONTENT_AND_DATA.md`, this validation guide.

The pre-existing platform registrant changes and deleted public font were not
reverted. Database generation used the installed Drift toolchain; its generated
output also contains formatting changes. No new package was introduced.
