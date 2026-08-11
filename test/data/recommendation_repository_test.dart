import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:cairn/core/db/app_database.dart';
import 'package:cairn/core/network/http_client.dart';
import 'package:cairn/core/network/response_cache.dart';
import 'package:cairn/data/models/album.dart';
import 'package:cairn/data/remote/coverart_client.dart';
import 'package:cairn/data/remote/listenbrainz_client.dart';
import 'package:cairn/data/remote/musicbrainz_client.dart';
import 'package:cairn/data/repositories/album_repository.dart';
import 'package:cairn/data/repositories/rating_repository.dart';
import 'package:cairn/data/repositories/recommendation_repository.dart';

void main() {
  group('session vibe', () {
    test('stores only in memory and can be cleared', () {
      final db = AppDatabase.memory();
      final http = ApiHttpClient(MockClient((request) async {
        fail('vibe state should not make a network request');
      }));
      final cache = ResponseCache(db);
      final musicBrainz = MusicBrainzClient(http, cache);
      final listenBrainz = ListenBrainzClient(http, cache);
      final albums =
          AlbumRepository(db, musicBrainz, CoverArtClient(http, cache));
      final ratings = RatingRepository(db);
      final repo = RecommendationRepository(
          db, musicBrainz, listenBrainz, albums, ratings);

      expect(repo.sessionVibeGenre, isNull);
      repo.setSessionVibeGenre('  Jazz ');
      expect(repo.sessionVibeGenre, 'jazz');
      repo.clearSessionVibeGenre();
      expect(repo.sessionVibeGenre, isNull);
      expect(db.db.select('PRAGMA table_info(app_state)').map((r) => r['name']),
          isNot(contains('session_vibe_genre')));
      db.close();
    });
  });

  group('restartFrom', () {
    test(
        'returns the picked album itself and sets it as the anchor, without any network call',
        () async {
      // Regression test for "search is not working, I search for something
      // and something else comes up when I click a result": restartFrom
      // used to call _nextFromSeed(album), which fetches similar artists and
      // returns a DIFFERENT album. Any such network call here throws via
      // MockClient, so this test fails loudly if that regresses.
      final db = AppDatabase.memory();
      final http = ApiHttpClient(MockClient((request) async {
        fail(
            'restartFrom must not make network requests (requested ${request.url})');
      }));
      final cache = ResponseCache(db);
      final musicBrainz = MusicBrainzClient(http, cache);
      final listenBrainz = ListenBrainzClient(http, cache);
      final coverArt = CoverArtClient(http, cache);
      final albums = AlbumRepository(db, musicBrainz, coverArt);
      final ratings = RatingRepository(db);
      final repo = RecommendationRepository(
          db, musicBrainz, listenBrainz, albums, ratings);

      const seedMbid = 'seed-album-mbid';
      db.db.execute(
        'INSERT INTO albums (mbid, title, artist_name, genres) VALUES (?, ?, ?, ?)',
        [seedMbid, 'Seed Title', 'Seed Artist', '["jazz"]'],
      );
      final seedAlbum = Album(
          mbid: seedMbid,
          title: 'Seed Title',
          artistName: 'Seed Artist',
          genres: const ['jazz']);

      final result = await repo.restartFrom(seedAlbum);

      expect(result.mbid, seedMbid);
      expect(result.title, 'Seed Title');

      final anchorRows = db.db
          .select('SELECT current_anchor_mbid FROM app_state WHERE id = 0');
      expect(anchorRows.single['current_anchor_mbid'], seedMbid);

      db.close();
    });
  });

  group('last shown album', () {
    test('restores the locally cached album from app state', () async {
      final db = AppDatabase.memory();
      final http = ApiHttpClient(MockClient((request) async {
        fail('restoring a cached album must not make a network request');
      }));
      final cache = ResponseCache(db);
      final musicBrainz = MusicBrainzClient(http, cache);
      final listenBrainz = ListenBrainzClient(http, cache);
      final coverArt = CoverArtClient(http, cache);
      final albums = AlbumRepository(db, musicBrainz, coverArt);
      final ratings = RatingRepository(db);
      final repo = RecommendationRepository(
          db, musicBrainz, listenBrainz, albums, ratings);

      const mbid = 'last-shown-album-mbid';
      db.db.execute(
        'INSERT INTO albums (mbid, title, artist_name, genres) VALUES (?, ?, ?, ?)',
        [mbid, 'Last Shown', 'Cached Artist', '["jazz"]'],
      );
      repo.saveLastShown(mbid);

      final restored = await repo.restoreLastShown();

      expect(restored?.mbid, mbid);
      expect(restored?.title, 'Last Shown');
      db.close();
    });
  });

  group('session display history', () {
    test('excludes displayed albums for this session and resets on restart',
        () async {
      final db = AppDatabase.memory();
      final cache = ResponseCache(db);
      cache.put(
        'mb:search-tag:jazz',
        {
          'release-groups': [
            {'id': 'already-shown-mbid'},
            {'id': 'fresh-mbid'},
          ],
        },
        ttlSeconds: 60,
      );
      db.db.execute(
        'INSERT INTO albums (mbid, title, artist_name, genres) VALUES (?, ?, ?, ?)',
        ['fresh-mbid', 'Fresh Album', 'Fresh Artist', '["jazz"]'],
      );
      db.db.execute(
        'INSERT INTO albums (mbid, title, artist_name, genres) VALUES (?, ?, ?, ?)',
        ['already-shown-mbid', 'Already Shown', 'Shown Artist', '["jazz"]'],
      );
      final http = ApiHttpClient(MockClient((request) async {
        fail('the cached pivot response should avoid network access');
      }));
      final musicBrainz = MusicBrainzClient(http, cache);
      final listenBrainz = ListenBrainzClient(http, cache);
      final albums =
          AlbumRepository(db, musicBrainz, CoverArtClient(http, cache));
      final ratings = RatingRepository(db);
      final repo = RecommendationRepository(
          db, musicBrainz, listenBrainz, albums, ratings);
      repo.setLikedGenres(['jazz']);
      repo.markShown('already-shown-mbid');

      expect((await repo.next()).mbid, 'fresh-mbid');

      // The history is deliberately in memory, so a new repository/session
      // can consider the same cached album again.
      final restarted = RecommendationRepository(
          db, musicBrainz, listenBrainz, albums, ratings);
      expect((await restarted.next()).mbid, 'already-shown-mbid');
      db.close();
    });
  });

  group('skip', () {
    test('reseeds from a random 4-5 star album, never the skipped album',
        () async {
      // A skip is not feedback about the skipped album. Even with an anchor,
      // use a highly-rated album as the one-off recommendation seed instead.
      final db = AppDatabase.memory();
      String? requestedSimilarArtistsFor;
      final http_ = ApiHttpClient(MockClient((request) async {
        if (request.url.host == 'labs.api.listenbrainz.org') {
          requestedSimilarArtistsFor =
              request.url.queryParameters['artist_mbids'];
        }
        return http.Response('not found', 404);
      }));
      final cache = ResponseCache(db);
      final musicBrainz = MusicBrainzClient(http_, cache);
      final listenBrainz = ListenBrainzClient(http_, cache);
      final coverArt = CoverArtClient(http_, cache);
      final albums = AlbumRepository(db, musicBrainz, coverArt);
      final ratings = RatingRepository(db);
      final repo = RecommendationRepository(
          db, musicBrainz, listenBrainz, albums, ratings);

      const anchorMbid = 'anchor-album-mbid';
      const anchorArtistMbid = 'anchor-artist-mbid';
      const skippedMbid = 'skipped-album-mbid';
      const skippedArtistMbid = 'skipped-artist-mbid';
      const ratedMbid = 'rated-album-mbid';
      const ratedArtistMbid = 'rated-artist-mbid';

      db.db.execute(
        'INSERT INTO albums (mbid, title, artist_name, artist_mbid, genres) VALUES (?, ?, ?, ?, ?)',
        [
          anchorMbid,
          'Anchor Title',
          'Anchor Artist',
          anchorArtistMbid,
          '["rock"]'
        ],
      );
      db.db.execute(
        'INSERT INTO albums (mbid, title, artist_name, artist_mbid, genres) VALUES (?, ?, ?, ?, ?)',
        [
          skippedMbid,
          'Skipped Title',
          'Skipped Artist',
          skippedArtistMbid,
          '["rock"]'
        ],
      );
      db.db.execute(
        'INSERT INTO albums (mbid, title, artist_name, artist_mbid, genres) VALUES (?, ?, ?, ?, ?)',
        [ratedMbid, 'Rated Title', 'Rated Artist', ratedArtistMbid, '["rock"]'],
      );
      ratings.rate(ratedMbid, 5);

      final anchorAlbum = Album(
        mbid: anchorMbid,
        title: 'Anchor Title',
        artistName: 'Anchor Artist',
        artistMbid: anchorArtistMbid,
        genres: const ['rock'],
      );
      await repo.restartFrom(anchorAlbum); // sets the anchor, no network call

      // similarArtists() on a 404 catches HttpException and returns [],
      // which then falls into _pivot() and throws (pool exhausted against
      // the same 404 mock) — irrelevant here; this test only cares which
      // artist the seed lookup was made for before that happens.
      await repo.skip(skippedMbid).catchError((_) => anchorAlbum);

      expect(requestedSimilarArtistsFor, ratedArtistMbid);
      expect(requestedSimilarArtistsFor, isNot(anchorArtistMbid));
      expect(requestedSimilarArtistsFor, isNot(skippedArtistMbid));

      db.close();
    });

    test('does not return a skipped album when pivot results are all excluded',
        () async {
      final db = AppDatabase.memory();
      final cache = ResponseCache(db);
      cache.put(
        'mb:search-tag:jazz',
        {
          'release-groups': [
            {'id': 'skipped-album-mbid'},
          ],
        },
        ttlSeconds: 60,
      );
      final http = ApiHttpClient(MockClient((request) async {
        fail('the cached pivot response should avoid network access');
      }));
      final musicBrainz = MusicBrainzClient(http, cache);
      final listenBrainz = ListenBrainzClient(http, cache);
      final coverArt = CoverArtClient(http, cache);
      final albums = AlbumRepository(db, musicBrainz, coverArt);
      final ratings = RatingRepository(db);
      final repo = RecommendationRepository(
          db, musicBrainz, listenBrainz, albums, ratings);
      repo.setLikedGenres(['jazz']);

      await expectLater(
          repo.skip('skipped-album-mbid'), throwsA(isA<StateError>()));

      db.close();
    });
  });
}
