import 'package:flutter/material.dart';
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
import 'features/discovery/discovery_controller.dart';
import 'features/discovery/discovery_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final docsDir = await getApplicationDocumentsDirectory();
  final database = AppDatabase.open('${docsDir.path}/record_reccomend.db');
  final http = ApiHttpClient();
  final cache = ResponseCache(database);

  final musicBrainz = MusicBrainzClient(http, cache);
  final coverArt = CoverArtClient(http, cache);
  final listenBrainz = ListenBrainzClient(http, cache);
  final odesli = OdesliClient(http, cache);

  final albums = AlbumRepository(database, musicBrainz, coverArt);
  final ratings = RatingRepository(database);
  final recommendations = RecommendationRepository(database, musicBrainz, listenBrainz, albums, ratings);
  final deepLinks = DeepLinkRepository(database, musicBrainz, odesli);

  final controller = DiscoveryController(albums, ratings, recommendations, deepLinks, musicBrainz);

  runApp(RecordReccomendApp(controller: controller));
}

class RecordReccomendApp extends StatefulWidget {
  final DiscoveryController controller;

  const RecordReccomendApp({super.key, required this.controller});

  @override
  State<RecordReccomendApp> createState() => _RecordReccomendAppState();
}

// DynamicColorBuilder only ever reads the system palette once, in its own
// initState — it has no listener for the palette changing later (verified
// against its source: no WidgetsBindingObserver, no repeated platform
// calls). The realistic moment a change would happen is the user leaving
// this app, changing wallpaper/style in system Settings, and coming back —
// so we watch for that resume and force DynamicColorBuilder to re-mount
// (via a fresh Key, since that's the only way to make it re-run initState)
// rather than trusting it to notice on its own.
class _RecordReccomendAppState extends State<RecordReccomendApp> with WidgetsBindingObserver {
  int _paletteGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() => _paletteGeneration++);
    }
  }

  @override
  Widget build(BuildContext context) {
    // On Android 12+ (and Linux/macOS/Windows), this hands us the real
    // system palette (wallpaper-derived Material You colors, including
    // whatever style — Expressive or otherwise — the user picked in their
    // OS theming settings). lightDynamic/darkDynamic are null wherever the
    // platform doesn't support it (older Android, web), and only then do we
    // fall back to our own fixed seed color.
    return DynamicColorBuilder(
      key: ValueKey(_paletteGeneration),
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        return MaterialApp(
          title: 'record_reccomend',
          themeMode: ThemeMode.system,
          theme: ThemeData(
            colorScheme: lightDynamic ??
                ColorScheme.fromSeed(
                  seedColor: Colors.deepPurple,
                  brightness: Brightness.light,
                  dynamicSchemeVariant: DynamicSchemeVariant.expressive,
                ),
          ),
          darkTheme: ThemeData(
            colorScheme: darkDynamic ??
                ColorScheme.fromSeed(
                  seedColor: Colors.deepPurple,
                  brightness: Brightness.dark,
                  dynamicSchemeVariant: DynamicSchemeVariant.expressive,
                ),
          ),
          home: DiscoveryScreen(controller: widget.controller),
        );
      },
    );
  }
}
