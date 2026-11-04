# JobSummit: notes for Claude

Android app (Flutter, `mobile/`) for Indian government jobs and exams, fed by a Python data
pipeline on GitHub Actions (`backend/`) that publishes JSON to the `data` branch (GitHub Pages).
No app server. Optional shared data goes to Supabase (`backend/supabase/insights.sql`).

## How to work here

- **New ideas: options first.** Suggest, then wait for a go before editing. Bug fixes and what was
  asked for can go ahead.
- **Build for everyone.** A user's own example (their degree, their exam) is one case, not the
  rule; keep features neutral, with a custom field where lists can't cover everyone.
- **Filters show when unsure.** Hide only jobs that are clearly not for the user; ambiguous ones
  stay visible with a "Check" tag.
- **Short UI text.** Settings: one short line or none. Release notes: 2–3 plain bullets, no
  internals.
- **Commits:** plain messages. Never add `Co-Authored-By: Claude` or any Claude/AI attribution.
  Committing, pushing and tagging releases is fine once the work is tested.

## Toolchain (Windows)

- Flutter is not on PATH: `C:/dev/flutter/bin/flutter.bat` (Dart: `C:/dev/flutter/bin/cache/dart-sdk/bin/dart.exe`).
- App: `cd mobile && flutter analyze && flutter test`. Debug APK:
  `JAVA_HOME='/c/Program Files/Android/Android Studio/jbr' flutter build apk --debug --flavor direct`
  (about 7 minutes; release APKs are built by CI from tags, so skip local release builds).
- Pipeline: venv `C:/Users/nac/etv/Scripts/python`: `-m pytest`, `-m ruff check app tests`,
  `-m ruff format app tests` (line length 110).
- `gh` is at `C:/Program Files/GitHub CLI/gh.exe`.
- Bash heredocs mangle backslashes and quotes: write multi-line edit scripts to a file and run them,
  or use the Edit tool (always for regexes).

## Releasing

1. Bump `version: X.Y.Z+N` in `mobile/pubspec.yaml` (build number always goes up; never lower it).
2. Commit, then an annotated tag `vX.Y.Z` whose message is a title line plus 2–3 plain bullets.
3. Push `main` and the tag: the "Android release" workflow builds and publishes the APKs; the app
   updates itself from GitHub Releases. Never move a pushed tag.

## Rules learned the hard way

- `tracked_applications.status` has a SQLite CHECK of three values: a new per-exam state gets its
  own column (ALTER TABLE migration + `_appColumns` in `database_service.dart`), never a new
  `ApplicationStatus` value. Test it through `DatabaseService` with sqflite_ffi.
- Exam watcher: a notice only counts for an exam when it names that exam's board
  (`labelNamesBoard` in `exam_watcher.dart`, `board_named` in `notice_labels.py`); Mistral's label
  alone is not enough (NTPC Limited is not RRB NTPC, UPSSSC is not SSC).
- CI pins Flutter and runs `flutter pub get --enforce-lockfile`: when upgrading Flutter locally,
  bump the pinned version in the workflows and commit `pubspec.lock`.
- Never protect the `data` branch: the pipeline force-pushes it.
- What the app sends anywhere must match `site/privacy.html`; update the policy in the same change.
  Shared data never includes names, emails, dates of birth, Google account data, IDs, passwords,
  notes, photos or response sheets.
- Secrets live in GitHub (`GEMINI_API_KEY`, `MISTRAL_API_KEY`, `SUPABASE_SECRET_KEY`). The Supabase
  publishable key in `mobile/lib/config/env.dart` is public by design (it can only call `ingest`
  and `forget`). Never put a secret key in the app or in chat.
