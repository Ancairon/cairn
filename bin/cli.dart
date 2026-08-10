import 'package:record_reccomend/core/db/app_database.dart';
import 'package:record_reccomend/core/network/http_client.dart';
import 'package:record_reccomend/core/network/response_cache.dart';
import 'package:record_reccomend/data/remote/musicbrainz_client.dart';
import 'package:record_reccomend/data/remote/coverart_client.dart';
import 'package:record_reccomend/data/remote/listenbrainz_client.dart';
import 'package:record_reccomend/data/remote/odesli_client.dart';
import 'package:record_reccomend/data/repositories/album_repository.dart';
import 'package:record_reccomend/data/repositories/rating_repository.dart';
import 'package:record_reccomend/data/repositories/recommendation_repository.dart';
import 'package:record_reccomend/data/repositories/deep_link_repository.dart';
import 'package:record_reccomend/data/repositories/export_repository.dart';
import 'package:record_reccomend/data/models/album.dart';

Future<void> main(List<String> args) async {
  final database = AppDatabase.open('record_reccomend.db');
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
  final export = ExportRepository(ratings, albums);

  final command = args.isNotEmpty ? args.first : 'next';

  switch (command) {
    case 'next':
      final album = await recommendations.next();
      _printAlbum(album);
      await _printPlayLinks(album, deepLinks);
      break;

    case 'rate':
      if (args.length < 3) {
        print('Usage: dart run bin/cli.dart rate <album-mbid> <stars 1-5>');
        break;
      }
      final mbid = args[1];
      final stars = int.parse(args[2]);
      final album = await albums.getOrFetch(mbid);
      ratings.rate(mbid, stars);
      print('Rated "${album.title}" by ${album.artistName}: $stars stars.\n');

      final next = await recommendations.onRated(album, stars);
      print('Next up:');
      _printAlbum(next);
      await _printPlayLinks(next, deepLinks);
      break;

    case 'journal':
      for (final rating in ratings.allRatings()) {
        final album = await albums.getOrFetch(rating.albumMbid);
        final stars = '${'*' * rating.stars}${'.' * (5 - rating.stars)}';
        print('$stars  ${album.title} — ${album.artistName}  (rated ${rating.ratedAt.toLocal()})');
      }
      break;

    case 'export-json':
      print(await export.toJson());
      break;

    case 'export-csv':
      print(await export.toCsv());
      break;

    default:
      print('Unknown command: $command');
      print('Usage: dart run bin/cli.dart [next|rate <mbid> <stars>|journal|export-json|export-csv]');
  }

  http.close();
  database.close();
}

void _printAlbum(Album album) {
  print('${album.title} — ${album.artistName} (${album.firstReleaseYear ?? 'unknown year'})');
  print('  mbid: ${album.mbid}');
  print('  genres: ${album.genres.join(', ')}');
  if (album.coverArtUrl != null) print('  cover art: ${album.coverArtUrl}');
}

Future<void> _printPlayLinks(Album album, DeepLinkRepository deepLinks) async {
  final links = await deepLinks.playLinksFor(album);
  if (links.isEmpty) {
    print('  play: ${deepLinks.searchFallbackUrl(album)} (no direct link found)');
    return;
  }
  print('  play:');
  for (final entry in links.entries) {
    print('    ${entry.key}: ${entry.value}');
  }
}
