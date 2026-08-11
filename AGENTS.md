# Cairn

Open-source, album-first mobile music discovery app (Flutter/Dart). See an album, tap play (deep link into whatever streaming app is installed), rate it 1-5 stars, get the next album dynamically based on that rating.

## Goals

Bridge human curation with a fast, active, album-centric discovery loop on mobile — as an alternative to streaming algorithms that optimize for passive/repeat listening rather than full-album discovery. Success means: see an album, play it via deep link into whatever streaming app is installed, rate it, and get a genuinely relevant next album with no backend, no login, and no API keys required.

Locked-in architecture decisions:

- **No Spotify API integration** — no developer account, OAuth, or client secret anywhere in the app. A Spotify link may appear only as a deep-link *target*, and only if sourced from MusicBrainz's own public external-link data.
- **No Last.fm.** `album.getSimilar` doesn't exist in Last.fm's API (verified against Last.fm's docs), and MusicBrainz's own API already provides genre/tag data for free. Result: **zero API keys anywhere in this app.**
- **Data sources, all public and keyless:** MusicBrainz API (identity, genres, external links), Cover Art Archive (artwork), ListenBrainz Labs `similar-artists` (recommendation signal, real listening-session data), Odesli (cross-platform link resolution).
- **DB: `sqlite3` (pure-Dart FFI), not `sqflite`.** Works identically in a plain terminal Dart program and later inside the Flutter app (with `sqlite3_flutter_libs` on Android) — one DB package for the whole project's lifetime.
- **State management: plain `ChangeNotifier`.** No Riverpod/Bloc/Provider — deliberately minimal.
- **Recommendation algorithm: a single global "anchor" album**, not a branch/lineage tree. 4-5 stars sets the anchor; 3 is neutral; 1-2 pivots immediately to an unexplored decade/genre. No streak-counting.
- **Simplicity is a deliberate, explicit priority** — plain SQL over query builders, no codegen/build_runner steps, no premature abstraction. Code should be readable by a human, not just generated and trusted.
- **Build order:** terminal app (`bin/cli.dart`) + data layer first, fully headless on any Linux machine, no phone/Android SDK needed — then verified on a physical Android device over wireless ADB — then a Flutter UI on top of the same data layer.

### Project-specific commands

- `dart pub get` — install dependencies.
- `dart run bin/cli.dart` — run the terminal app (Milestone 1).
- `flutter test` — run the test suite (recommendation scoring/dedup, export formatting, repository logic) against fixture JSON, no live API calls. `dart test` no longer compiles: `RatingRepository` extends `ChangeNotifier`, so the suite now needs the Flutter SDK's compiler, not the standalone Dart SDK.
- `flutter analyze` — static analysis; run from repo root.
- `flutter build apk --debug` — build a debug APK for on-device install.

### Common investigation commands

- Find existing tests for a pure function before adding more: `grep -rn "<functionName>" test/`
- Find where a DB column/field is read or written: `grep -rn "<column_name>" lib/`
- Find all call sites of a repository method: `grep -rn "<methodName>(" lib/`
- Confirm the Android application ID: `grep applicationId android/app/build.gradle.kts`
- Check whether a symlink/file is already in the target bootstrap state: `readlink -f <path>`

### Verification handoff rule

- After every implementation fix, explicitly tell the user what to test.
- Include concrete manual steps, expected results, and the relevant automated command(s).
- Report build, install, device, or environment limitations immediately instead of implying that verification happened when it did not.

### Alpha versioning rule

- Every implementation fix must increment the alpha patch version and Android build number in `pubspec.yaml` before building an APK.
- Keep the app below `1.0.0` while it is alpha; use the next `0.x.(patch)+build` version for each fix.
- Tell the user the exact version installed with each checkpoint.

### Device inspection rule

- Never capture or request screenshots from the user's device.
- Use source inspection, automated tests, accessibility/UI hierarchy dumps, and logs for device verification instead.
