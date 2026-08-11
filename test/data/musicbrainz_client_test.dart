import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:cairn/core/db/app_database.dart';
import 'package:cairn/core/network/http_client.dart';
import 'package:cairn/core/network/response_cache.dart';
import 'package:cairn/data/remote/musicbrainz_client.dart';

void main() {
  group('searchReleaseGroupsByText', () {
    test('tokenizes input into fuzzy album-only Lucene terms', () async {
      final db = AppDatabase.memory();
      Uri? requestedUrl;
      final httpClient = ApiHttpClient(MockClient((request) async {
        requestedUrl = request.url;
        return http.Response('{"release-groups": []}', 200);
      }));
      final cache = ResponseCache(db);
      final musicBrainz = MusicBrainzClient(httpClient, cache);

      await musicBrainz.searchReleaseGroupsByText('Queen');

      expect(requestedUrl, isNotNull);
      expect(
        requestedUrl!.queryParameters['query'],
        'Queen~ AND type:album',
      );

      db.close();
    });

    test('mixed title and artist words are matched in either field', () async {
      final db = AppDatabase.memory();
      Uri? requestedUrl;
      final httpClient = ApiHttpClient(MockClient((request) async {
        requestedUrl = request.url;
        return http.Response('{"release-groups": []}', 200);
      }));
      final musicBrainz = MusicBrainzClient(httpClient, ResponseCache(db));

      await musicBrainz
          .searchReleaseGroupsByText('lord of the rings howard shore');

      expect(requestedUrl!.queryParameters['query'],
          'lord~ AND of~ AND the~ AND rings~ AND howard~ AND shore~ AND type:album');
      db.close();
    });

    test('keeps artist and album words searchable across fields', () async {
      final db = AppDatabase.memory();
      Uri? requestedUrl;
      final httpClient = ApiHttpClient(MockClient((request) async {
        requestedUrl = request.url;
        return http.Response('{"release-groups": []}', 200);
      }));
      final musicBrainz = MusicBrainzClient(httpClient, ResponseCache(db));

      await musicBrainz.searchReleaseGroupsByText('jimi hendrix cornerstones');

      expect(requestedUrl!.queryParameters['query'],
          'jimi~ AND hendrix~ AND cornerstones~ AND type:album');
      db.close();
    });

    test('strips punctuation from tokens so the Lucene query stays well-formed',
        () async {
      final db = AppDatabase.memory();
      Uri? requestedUrl;
      final httpClient = ApiHttpClient(MockClient((request) async {
        requestedUrl = request.url;
        return http.Response('{"release-groups": []}', 200);
      }));
      final cache = ResponseCache(db);
      final musicBrainz = MusicBrainzClient(httpClient, cache);

      await musicBrainz.searchReleaseGroupsByText('The "Best" Album');

      expect(
        requestedUrl!.queryParameters['query'],
        'The~ AND Best~ AND Album~ AND type:album',
      );

      db.close();
    });

    test(
        'caches by the raw text, so a repeated search for the same input hits cache',
        () async {
      final db = AppDatabase.memory();
      var requestCount = 0;
      final httpClient = ApiHttpClient(MockClient((request) async {
        requestCount++;
        return http.Response('{"release-groups": []}', 200);
      }));
      final cache = ResponseCache(db);
      final musicBrainz = MusicBrainzClient(httpClient, cache);

      await musicBrainz.searchReleaseGroupsByText('Queen');
      await musicBrainz.searchReleaseGroupsByText('Queen');

      expect(requestCount, 1);

      db.close();
    });
  });
}
