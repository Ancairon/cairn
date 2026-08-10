import 'package:flutter/material.dart';
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

  final controller = DiscoveryController(albums, ratings, recommendations, deepLinks);

  runApp(RecordReccomendApp(controller: controller));
}

class RecordReccomendApp extends StatelessWidget {
  final DiscoveryController controller;

  const RecordReccomendApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'record_reccomend',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
          dynamicSchemeVariant: DynamicSchemeVariant.expressive,
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
          dynamicSchemeVariant: DynamicSchemeVariant.expressive,
        ),
      ),
      home: DiscoveryScreen(controller: controller),
    );
  }
}
