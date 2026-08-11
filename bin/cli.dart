// print() is this CLI's actual output, not a debug leftover — avoid_print
// (from flutter_lints, aimed at app code) doesn't apply here.
// ignore_for_file: avoid_print
import 'dart:io';
import 'package:cairn/core/db/app_database.dart';
import 'package:cairn/core/network/http_client.dart';
import 'package:cairn/core/network/response_cache.dart';
import 'package:cairn/data/remote/musicbrainz_client.dart';
import 'package:cairn/data/remote/coverart_client.dart';
import 'package:cairn/data/remote/listenbrainz_client.dart';
import 'package:cairn/data/remote/odesli_client.dart';
import 'package:cairn/data/repositories/album_repository.dart';
import 'package:cairn/data/repositories/rating_repository.dart';
import 'package:cairn/data/repositories/recommendation_repository.dart';
import 'package:cairn/data/repositories/deep_link_repository.dart';
import 'package:cairn/data/repositories/export_repository.dart';
import 'package:cairn/data/models/album.dart';
import 'package:cairn/data/genre_pool.dart';

Future<void> main(List<String> args) async {
  AppDatabase.migrateLegacyFile('record_reccomend.db', 'cairn.db');
  final database = AppDatabase.open('cairn.db');
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
      if (recommendations.likedGenres().isEmpty && ratings.allRatings().isEmpty) {
        print("First time here — run 'dart run bin/cli.dart onboard' to pick genres you like.\n"
            'Picking a recommendation from generic defaults for now:\n');
      }
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

    case 'onboard':
      print('Pick the genres you like (comma-separated numbers, e.g. 1,5,12):\n');
      for (var i = 0; i < genrePool.length; i++) {
        print('  ${i + 1}. ${genrePool[i]}');
      }
      stdout.write('\n> ');
      final input = stdin.readLineSync() ?? '';
      final picks = input
          .split(',')
          .map((s) => int.tryParse(s.trim()))
          .whereType<int>()
          .where((n) => n >= 1 && n <= genrePool.length)
          .map((n) => genrePool[n - 1])
          .toSet()
          .toList();
      if (picks.isEmpty) {
        print('No valid picks — liked genres unchanged.');
        break;
      }
      recommendations.setLikedGenres(picks);
      print('\nSaved. Cold-start recommendations will now draw from: ${picks.join(', ')}');
      break;

    case 'search':
      if (args.length < 2) {
        print('Usage: dart run bin/cli.dart search <query>');
        break;
      }
      final query = args.sublist(1).join(' ');
      final results = await musicBrainz.searchReleaseGroupsByText(query);
      if (results.isEmpty) {
        print('No matches for "$query".');
        break;
      }
      print('Results for "$query":\n');
      for (var i = 0; i < results.length; i++) {
        final r = results[i];
        final artist = ((r['artist-credit'] as List?) ?? [])
            .cast<Map<String, dynamic>>()
            .map((c) => c['name'] as String)
            .join(', ');
        final year = (r['first-release-date'] as String?)?.split('-').first ?? 'unknown year';
        print('  ${i + 1}. ${r['title']} — $artist ($year)');
      }
      stdout.write('\nStart from which one? (number, or Enter to cancel) > ');
      final choice = int.tryParse(stdin.readLineSync() ?? '');
      if (choice == null || choice < 1 || choice > results.length) {
        print('Cancelled.');
        break;
      }
      final picked = await albums.getOrFetch(results[choice - 1]['id'] as String);
      print('\nStarting from "${picked.title}" by ${picked.artistName}.\n');
      final started = await recommendations.restartFrom(picked);
      print('Next up:');
      _printAlbum(started);
      await _printPlayLinks(started, deepLinks);
      break;

    default:
      print('Unknown command: $command');
      print(
        'Usage: dart run bin/cli.dart '
        '[next|rate <mbid> <stars>|journal|export-json|export-csv|onboard|search <query>]',
      );
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
