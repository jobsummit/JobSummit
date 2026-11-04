# Releasing the Android app

Two build flavours:

| Flavour | Goes to | In-app updater | `REQUEST_INSTALL_PACKAGES` |
|---|---|---|---|
| `direct` | GitHub Releases, your server's `/downloads/` | ✅ | ✅ |
| `store` | Indus Appstore, Samsung Galaxy Store | ❌ (the store updates it) | removed |

Use **one signing key for both**, kept forever. Android only installs an update signed with the same key.

## 1. Create the production keystore (once)

```bash
keytool -genkeypair -v -storetype PKCS12 -keystore upload-keystore.jks \
  -keyalg RSA -keysize 4096 -validity 10000 -alias release
```

- **This key is the app's identity.** There's no Google Play App Signing here to recover it.
  If it's lost, no existing install can ever be updated again.
- Store it in two places off your laptop (password manager + encrypted cloud), along with both passwords.
- Locally: copy it to `android/app/upload-keystore.jks`, then copy
  `android/key.properties.example` → `android/key.properties` and fill it in. Both are git-ignored.
- For CI, add these repository secrets: `ANDROID_KEYSTORE_BASE64` (`base64 -w0 upload-keystore.jks`),
  `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`.

## 2. Version numbers

`pubspec.yaml` → `version: 0.4.1+5`.
- **+5 must go up by at least 1 every release.** It's what the updater compares.
- The Android `versionCode` becomes `5×10 + ABI digit` (universal 50, armeabi-v7a 51, arm64 52,
  x86_64 53). So any newer release outranks any older one, split or universal (see `android/app/build.gradle.kts`).
- Check a build: `apkanalyzer manifest version-code <file>.apk`.

## 3. Build locally

```bash
flutter create --platforms=android --org com.examtracker --project-name exam_tracker .  # first time only
flutter pub get && flutter test

# Direct: per-ABI (small downloads) + universal
flutter build apk --release --flavor direct --split-per-abi --dart-define-from-file=env/prod.json
flutter build apk --release --flavor direct --dart-define-from-file=env/prod.json
# Store: universal
flutter build apk --release --flavor store --dart-define-from-file=env/prod.json
# → build/app/outputs/flutter-apk/
```

`flutter run` also needs a flavour now: `flutter run --flavor direct --dart-define-from-file=env/prod.json`.

> **Don't put `API_KEY`/`USER_ID` in a public build.** Anything inside a published APK can be
> extracted, and that key unlocks admin endpoints. Public builds run offline + updater only until
> the app moves to Google sign-in (the backend already supports it).

## 4. Publish

### GitHub Releases (automated)
```bash
git commit -am "Release 0.4.1"
git tag -a v0.4.1 -m "Clearer countdowns; calendar sync fix"   # message = in-app release notes
git push origin main v0.4.1
```
`.github/workflows/android-release.yml` then does the rest:
1. Builds and signs all APKs.
2. Writes `latest.json` (version, notes, SHA-256 of each APK) and `SHA256SUMS`.
3. Creates the release.

The `store` APK is attached to the workflow run as an artifact, not to the public release.
Phones read `latest.json` from the GitHub release itself.

**Forcing an update** (e.g. after an API change): set the repository variable
`MIN_SUPPORTED_VERSION_CODE`. Installs below it get the update prompt without a "Later" button.

### Indus Appstore (PhonePe)
1. Register at the Indus Appstore developer console (PAN/Aadhaar or business KYC).
   Listing was free until 1 Apr 2025, and a "nominal annual fee" was announced after that, so
   check the current terms.
2. Create the app with package `com.examtracker.exam_tracker`, category Education / Productivity.
3. Upload `jobsummit-<ver>-store.apk` (or build an AAB with `flutter build appbundle --flavor store`
   if the console asks for one).
4. Store listing:
   - Short and long description (Hindi too if you can).
   - At least 2 phone screenshots and a 512×512 icon.
   - A privacy-policy URL. Host one; it has to explain the calendar access, the Google sign-in
     email, and that credentials stay on the device.
5. Data-safety / permissions answers:
   - Calendar: writes deadline and exam events.
   - Notifications: deadline alerts.
   - Internet.
   - No location, contacts or SMS.
6. Submit; review typically takes a few days. Upload each later release as a new version with a
   higher version code.

### Samsung Galaxy Store
1. Register a seller account at seller.samsungapps.com (free). An individual account is fine for a free app.
2. *Add New Application* → Android → fill in title, description, category, age rating (questionnaire).
3. Binary: upload the `store` APK. Galaxy Store checks the version code is higher than the live one.
4. Screenshots (≥ 4 recommended), icon 512×512, privacy-policy URL.
5. Select countries (India at minimum), price *Free*, then submit for certification (usually 3–7 days).

### Not worth it: Amazon Appstore
Amazon shut its Appstore down on non-Amazon Android phones on 20 Aug 2025 and stopped
accepting new Android app submissions. Only Fire tablets remain.

## 5. Things users may hit

- **"App not installed" on update:** the APK wasn't signed with the release key, or the version
  code didn't go up.
- **Samsung (One UI 6+) Auto Blocker** blocks *all* installs from outside Galaxy Store and Play,
  including our updater. The update dialog explains how to allow it; Galaxy Store users are unaffected.
- **Switching channels** (GitHub ↔ store) works only if the store doesn't re-sign the app with its
  own key. Keep "use my signature" if a store offers the choice.
- **Install from the browser:** Android asks once to "Allow from this source". The updater
  triggers the same prompt for the app itself.
