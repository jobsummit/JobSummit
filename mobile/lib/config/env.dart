import 'package:flutter/services.dart' show appFlavor;

/// Build-time configuration, injected with `--dart-define-from-file=env/<name>.json`
/// (examples in `env/*.example.json`). Every value has a working default, so a plain
/// `flutter build apk --flavor direct` produces a usable app.
///
/// There is no server: jobs come from the data pipeline's files on GitHub, matching and
/// the exam watcher run on the phone, and the only account is Google (for the Drive backup).
abstract final class Env {
  /// The *Web application* OAuth client ID from Google Cloud ("serverClientId").
  /// A public identifier, not a secret. Empty = this build has no Google sign-in,
  /// so the app runs without backup.
  static const googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue: '586998998046-3r460abp9kps2kdo3vhdlmitqkdk92oq.apps.googleusercontent.com',
  );

  static bool get canSignIn => googleServerClientId.isNotEmpty;

  /// The GitHub repo (under the JobSummit organization, so no personal name shows
  /// in links). Release builds pass the real addresses; these are the fallbacks.
  static const _repo = 'jobsummit/JobSummit';

  /// Code, releases and "report a problem".
  static const repoUrl = String.fromEnvironment('REPO_URL', defaultValue: 'https://github.com/$_repo');

  /// Where the data pipeline publishes jobs.json / notices.json: the repo's `data`
  /// branch. No server needed: the phone matches jobs itself.
  static const _dataBaseUrl = String.fromEnvironment(
    'DATA_BASE_URL',
    defaultValue: 'https://raw.githubusercontent.com/$_repo/data',
  );

  /// The same files on GitHub Pages. Some Indian ISPs (Jio, at times) block
  /// raw.githubusercontent.com, so downloads fall back from one to the other.
  /// The home page and privacy policy live here too.
  static const _dataMirrorUrl = String.fromEnvironment(
    'DATA_MIRROR_URL',
    defaultValue: 'https://jobsummit.github.io/JobSummit',
  );

  /// The home page (with the download button), ending in a slash.
  static String get homePageUrl => '${_dataMirrorUrl.trim().replaceFirst(RegExp(r'/+$'), '')}/';

  /// Both addresses, mirror first, without trailing slashes or duplicates.
  static List<String> get dataBaseUrls => {
        for (final url in [_dataMirrorUrl, _dataBaseUrl])
          if (url.trim().isNotEmpty) url.trim().replaceFirst(RegExp(r'/+$'), ''),
      }.toList();

  /// Builds can leave out the Private (corporate) jobs workspace entirely with
  /// `--dart-define=ENABLE_PRIVATE_JOBS=false`. On by default; users still switch it
  /// on themselves in Settings › Jobs.
  /// "Send a review" posts to this Google Form (its responses go to a Google Sheet
  /// the team reads). The entry numbers are the form's question ids.
  static const reviewFormId = String.fromEnvironment(
    'REVIEW_FORM_ID',
    defaultValue: '1FAIpQLSeK4Z0iN-d5lg-W6DTTVIN1sYegseR2nDDESNG_zHYR3OcKHg',
  );
  static const reviewRatingEntry = 'entry.178685883';
  static const reviewTextEntry = 'entry.907586785';
  static const reviewEmailEntry = 'entry.2080412853';

  /// "Help improve job picks" (opt-in): the Supabase project phones share with.
  /// The publishable key is meant to be public: it can only call ingest() and
  /// forget() (backend/supabase/insights.sql), never read anything.
  static const supabaseUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://mowurjbmifkwlaogidns.supabase.co');
  static const supabaseKey =
      String.fromEnvironment('SUPABASE_KEY', defaultValue: 'sb_publishable_TOsXmJkb6qn3zI2_B3ZIdg_3Z2LQLyq');

  static const privateJobsAvailable =bool.fromEnvironment('ENABLE_PRIVATE_JOBS', defaultValue: true);

  /// Calendar events are written in this zone. The audience is India-only, so
  /// a fixed zone avoids a native timezone-lookup dependency.
  static const timeZone = String.fromEnvironment('TIME_ZONE', defaultValue: 'Asia/Kolkata');

  /// The in-app updater's source, e.g.
  /// https://github.com/OWNER/REPO/releases/latest/download/latest.json
  static const releaseManifestUrl = String.fromEnvironment('RELEASE_MANIFEST_URL');

  /// Human-readable download page (opened if in-app install is blocked).
  static const releasesPageUrl = String.fromEnvironment('RELEASES_PAGE_URL');

  /// Self-updating is only for the `direct` (GitHub / website) build. Store builds
  /// are updated by their store, and stores generally reject self-updating apps.
  static bool get updatesEnabled => appFlavor == 'direct';
}
