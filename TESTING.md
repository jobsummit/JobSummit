# Testing on your phone

There is no server: the app reads the pipeline's files from GitHub Pages, so the release build
from GitHub works on any phone with no setup.

## Install

- **Releases:** github.com/jobsummit/JobSummit/releases/latest (most phones: the `arm64-v8a`
  APK). After that, the app updates itself over Wi-Fi.
- **Your own build:** release builds are signed with the release key, so they install over the
  GitHub version and keep your data. A **debug** build is signed with the debug key: Android
  only installs it after uninstalling the release, which wipes the app's data (back up to
  Drive first).

## Connect the phone to the computer (wireless debugging)

1. Phone and computer on the same Wi-Fi. On the phone: Settings → Developer options →
   Wireless debugging → on.
2. Pair once: "Pair device with QR code" (Android Studio shows the QR), or "Pair device with
   pairing code" and `adb pair <ip>:<port> <code>`.
3. Connect: `adb mdns services` lists the phone's `_adb-tls-connect` address, then
   `adb connect <ip>:<port>`.

adb is at `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`. In Git Bash, set
`MSYS_NO_PATHCONV=1` before `adb shell` commands with paths.

## What to look at

- Screens: `adb exec-out screencap -p > screen.png`.
- Notification channels: `adb shell dumpsys notification --noredact | grep -A3 com.examtracker`.
- Background check (every 15 minutes, WorkManager): `adb shell dumpsys jobscheduler | grep -c examtracker`
  is 0 when nothing is scheduled; opening the app schedules it again.
- Battery: `adb shell dumpsys deviceidle whitelist | grep exam_tracker` (listed = not restricted).
- Logs: `adb logcat --pid=$(adb shell pidof com.examtracker.exam_tracker)`.

In the app, Settings → About → Self-check (debug builds) tests sign-in, saving, the job list and
reminders.
