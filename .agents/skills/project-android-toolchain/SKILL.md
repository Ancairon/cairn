# Project Skill: Android Toolchain

## Trigger

Load this skill before any work that touches Android builds, Gradle, `flutter build apk`, on-device install, or `adb` — including debugging a Gradle failure, running the app on a physical device, or clearing/reinstalling the app during testing.

## Why this exists

Two separate SOWs (SOW-0002 and SOW-0003) independently hit the same JDK/Gradle toolchain friction and the same install-time app-data staleness. This is a confirmed recurrence, not a one-off — see `.agents/sow/done/SOW-0002-20260810-onboarding-search-android-ui.md` and `.agents/sow/done/SOW-0003-20260810-discovery-ui-overhaul.md` (Followup mapping).

## JDK / Gradle toolchain

This machine's default Java install is JRE-only: `dpkg -l` shows `openjdk-25-jre`/`openjdk-25-jre-headless` but no `openjdk-25-jdk` package, so the default `java` on `PATH` cannot compile (`javac` is not part of a JRE-only install). Gradle (and therefore `flutter build apk` / `flutter run` on Android) needs a real JDK.

A JDK 21 is separately installed (`openjdk-21-jdk-headless`, resolving to `/usr/lib/jvm/java-21-openjdk-amd64`), and Flutter must be told to use it explicitly:

```bash
flutter config --jdk-dir /usr/lib/jvm/java-1.21.0-openjdk-amd64
```

(Both `/usr/lib/jvm/java-21-openjdk-amd64` and the alternatives-managed `/usr/lib/jvm/java-1.21.0-openjdk-amd64` path resolve to the same JDK 21 install — `flutter config --list` reports the latter form. Confirm the current path with `update-alternatives --list java` or `ls /usr/lib/jvm/` if the exact directory name has since changed, rather than assuming this value is still current.)

This setting has been observed lost or needing a reset more than once *per session*, across two separate SOWs — the underlying cause hasn't been root-caused (a plausible but unconfirmed theory is that each shell invocation starts fresh and doesn't inherit prior state), but the fix is cheap and the failure mode is not: a Gradle build that suddenly can't find `javac`.

**Recommendation: check/reset this proactively before starting Android build work**, rather than waiting for the Gradle toolchain error to appear:

```bash
flutter config --list | grep jdk-dir
```

If it's empty or missing, set it with the command above before running any Gradle/Flutter Android build.

## `adb install -r` and stale schema data

`adb install -r` reinstalls the APK but preserves the app's existing data directory — including any SQLite schema from a previous build. `CREATE TABLE IF NOT EXISTS` is a no-op on a table that already exists, so a plain column addition would silently never reach an install that updates on top of an existing app.

**Update (SOW-0004): the user explicitly decided to add a minimal, additive-only column migration** rather than keep wiping app data — this reverses the earlier "no migration machinery pre-release" stance recorded below, on purpose, not quietly. See `AppDatabase._ensureAdditiveColumns()` in `lib/core/db/app_database.dart`: on every open, it checks `PRAGMA table_info` for each table in the `_additiveColumns` map and runs `ALTER TABLE ... ADD COLUMN` for anything missing. It only ever adds columns with their declared default — never renames, drops, or rewrites existing data. Any new `app_state` (or other table) column added going forward must be added to `_additiveColumns` too, or it won't reach an updated install.

This covers plain column additions only. A real structural change (renaming/dropping a column, splitting a table) still has no machinery and still needs `pm clear`:

```bash
adb shell pm clear com.ancairon.cairn
```

(Package/application ID confirmed in `android/app/build.gradle.kts`: `applicationId = "com.ancairon.cairn"`. Re-check that file if this skill is being read long after this line was written — the ID could change before a public release.)

## Debug-keystore signature mismatch

`INSTALL_FAILED_UPDATE_INCOMPATIBLE` on `adb install` means the on-device app was signed with a different debug keystore than the one currently building it (common after a toolchain reset, a new machine, or switching build environments). The fix is uninstall then reinstall:

```bash
adb uninstall com.ancairon.cairn
adb install -r <path-to-apk>
```

This is acceptable **only** because the project is pre-release and there's no real user data to protect — losing on-device app data this way is a non-issue right now. This paragraph is specifically about *debug* builds — `flutter build apk --debug` still signs with Flutter's own auto-generated debug keystore, unaffected by the below. **Release builds no longer have this problem** (SOW-0014): `android/app/build.gradle.kts` now signs `release` builds with a real keystore (`android/key.properties` + the `.jks` it points at, both gitignored — never assume either exists on a fresh checkout, the build falls back to the debug keystore only when `key.properties` is genuinely absent). Losing that keystore or its password blocks seamless future updates for anyone already on a release signed with it; it is not tracked anywhere in this repo, and the user is responsible for backing it up outside this machine.

## Wireless ADB port rotation

Wireless ADB's connection port rotates whenever the connection toggles or the device reboots — this is expected `adb` behavior, not a bug. If `adb devices` stops showing the device or a command errors with a connection failure, the fix is reconnecting via `adb connect <ip>:<new-port>` (or re-pairing if the device dropped the pairing entirely), not debugging the build.
