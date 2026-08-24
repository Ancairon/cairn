import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/network/artwork_cache.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:path_provider/path_provider.dart';
import 'core/db/app_database.dart';
import 'core/network/http_client.dart';
import 'core/network/response_cache.dart';
import 'data/remote/musicbrainz_client.dart';
import 'data/remote/coverart_client.dart';
import 'data/remote/listenbrainz_client.dart';
import 'data/remote/odesli_client.dart';
import 'data/repositories/album_repository.dart';
import 'data/repositories/rating_repository.dart';
import 'data/repositories/recommendation_repository.dart';
import 'data/repositories/deep_link_repository.dart';
import 'data/repositories/saved_filter_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'data/repositories/backup_repository.dart';
import 'data/repositories/notes_repository.dart';
import 'data/repositories/update_check_repository.dart';
import 'features/discovery/discovery_controller.dart';
import 'features/discovery/discovery_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(ArtworkCache.collect());
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
  ));

  final docsDir = await getApplicationDocumentsDirectory();
  AppDatabase.migrateLegacyFile(
    '${docsDir.path}/record_reccomend.db',
    '${docsDir.path}/cairn.db',
  );
  final database = AppDatabase.open('${docsDir.path}/cairn.db');
  final http = ApiHttpClient();
  final cache = ResponseCache(database);

  final musicBrainz = MusicBrainzClient(http, cache);
  final coverArt = CoverArtClient(http, cache);
  final listenBrainz = ListenBrainzClient(http, cache);
  final odesli = OdesliClient(http, cache);

  final albums = AlbumRepository(database, musicBrainz, coverArt);
  final ratings = RatingRepository(database);
  final recommendations = RecommendationRepository(
      database, musicBrainz, listenBrainz, albums, ratings);
  final deepLinks = DeepLinkRepository(database, musicBrainz, odesli);
  final settings = SettingsRepository(database);
  final savedFilters = SavedFilterRepository(database);
  final backups = BackupRepository(database);
  final notes = NotesRepository(database);
  final updateCheck = UpdateCheckRepository(http);

  final controller = DiscoveryController(
    albums,
    ratings,
    recommendations,
    deepLinks,
    musicBrainz,
    settings,
    savedFilters,
    backups,
    notes,
    updateCheck,
  );

  runApp(CairnApp(controller: controller));
}

class CairnApp extends StatefulWidget {
  final DiscoveryController controller;

  const CairnApp({super.key, required this.controller});

  @override
  State<CairnApp> createState() => _CairnAppState();
}

// Calls DynamicColorPlugin directly instead of using DynamicColorBuilder,
// and holds the result in this State via a plain setState — never a key
// change. DynamicColorBuilder's own initState always starts with null
// colors and fills them in a moment later (see its source), so remounting
// it on every resume — the previous approach, to notice a wallpaper change
// made while away — produced a visible fallback-color flash on every single
// app reopen, not just the first. It also tore down and rebuilt the entire
// widget tree below it (DiscoveryScreen included) on every resume, which
// broke an in-progress import mid-match and reset the Play button's screen
// state on every return from a streaming app. Calling the plugin directly
// and updating in place avoids all of that: no remount, so no flash beyond
// the one unavoidable cold-launch fetch, and no more forced teardown of
// live screen state for this reason at all.
class _CairnAppState extends State<CairnApp> with WidgetsBindingObserver {
  ColorScheme? _lightDynamic;
  ColorScheme? _darkDynamic;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPalette();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshPalette();
  }

  // Same two-tier fallback DynamicColorBuilder itself uses: a full core
  // palette where the OS provides one (Android 12+), else a single accent
  // color (macOS/Windows/Linux), else leave whatever's already showing
  // alone — never regress to the static seed color once a real one has
  // been found.
  Future<void> _refreshPalette() async {
    try {
      final corePalette = await DynamicColorPlugin.getCorePalette();
      if (!mounted) return;
      if (corePalette != null) {
        setState(() {
          _lightDynamic = corePalette.toColorScheme();
          _darkDynamic = corePalette.toColorScheme(brightness: Brightness.dark);
        });
        return;
      }
    } on PlatformException {
      // Fall through to the accent-color attempt below.
    }
    try {
      final accentColor = await DynamicColorPlugin.getAccentColor();
      if (!mounted || accentColor == null) return;
      setState(() {
        _lightDynamic = ColorScheme.fromSeed(
            seedColor: accentColor, brightness: Brightness.light);
        _darkDynamic = ColorScheme.fromSeed(
            seedColor: accentColor, brightness: Brightness.dark);
      });
    } on PlatformException {
      // Neither source available on this platform — static seed color below.
    }
  }

  @override
  Widget build(BuildContext context) {
    // On Android 12+ (and Linux/macOS/Windows), this hands us the real
    // system palette (wallpaper-derived Material You colors, including
    // whatever style — Expressive or otherwise — the user picked in their
    // OS theming settings). Null wherever the platform doesn't support it
    // (older Android, web) or before the first fetch resolves, and only
    // then do we fall back to our own fixed seed color.
    return MaterialApp(
      title: 'Cairn',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: _lightDynamic ??
            ColorScheme.fromSeed(
              seedColor: Colors.deepPurple,
              brightness: Brightness.light,
              dynamicSchemeVariant: DynamicSchemeVariant.expressive,
            ),
      ),
      darkTheme: ThemeData(
        colorScheme: _darkDynamic ??
            ColorScheme.fromSeed(
              seedColor: Colors.deepPurple,
              brightness: Brightness.dark,
              dynamicSchemeVariant: DynamicSchemeVariant.expressive,
            ),
      ),
      home: DiscoveryScreen(controller: widget.controller),
    );
  }
}
