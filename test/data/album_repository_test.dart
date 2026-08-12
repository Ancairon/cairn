import 'dart:convert';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:cairn/core/db/app_database.dart';
import 'package:cairn/core/network/http_client.dart';
import 'package:cairn/core/network/response_cache.dart';
import 'package:cairn/data/remote/coverart_client.dart';
import 'package:cairn/data/remote/musicbrainz_client.dart';
import 'package:cairn/data/repositories/album_repository.dart';

AlbumRepository _repository(Map<String, dynamic> Function(Uri) respond) {
  final db = AppDatabase.memory();
  final httpClient = ApiHttpClient(MockClient((request) async {
    if (request.url.host == 'coverartarchive.org') {
      return http.Response(jsonEncode({'images': []}), 200);
    }
    return http.Response(jsonEncode(respond(request.url)), 200);
  }));
  final cache = ResponseCache(db);
  return AlbumRepository(
    db,
    MusicBrainzClient(httpClient, cache),
    CoverArtClient(httpClient, cache),
  );
}

Map<String, dynamic> _releaseGroupResponse(List<Map<String, dynamic>> releases) {
  return {
    'title': 'Appetite for Destruction',
    'artist-credit': [
      {'name': "Guns N' Roses", 'artist': {'name': "Guns N' Roses"}}
    ],
    'first-release-date': '1987-07-21',
    'genres': [],
    'releases': releases,
  };
}

void main() {
  group('getOrFetch release selection', () {
    test('prefers a later-dated Vinyl release over an earlier CD release',
        () async {
      final repo = _repository((_) => _releaseGroupResponse([
            {
              'id': 'cd-release',
              'date': '1987-07-21',
              'media': [
                {'format': 'CD', 'track-count': 12}
              ],
            },
            {
              'id': 'vinyl-release',
              'date': '1987-08-01',
              'media': [
                {'format': '12" Vinyl', 'track-count': 12}
              ],
            },
          ]));

      final album = await repo.getOrFetch('release-group-1');
      expect(album.representativeReleaseMbid, 'vinyl-release');
    });

    test('falls back to the earliest release when none are side-labelled',
        () async {
      final repo = _repository((_) => _releaseGroupResponse([
            {
              'id': 'later-cd',
              'date': '1990-01-01',
              'media': [
                {'format': 'CD', 'track-count': 12}
              ],
            },
            {
              'id': 'earliest-cd',
              'date': '1987-07-21',
              'media': [
                {'format': 'CD', 'track-count': 12}
              ],
            },
          ]));

      final album = await repo.getOrFetch('release-group-2');
      expect(album.representativeReleaseMbid, 'earliest-cd');
    });

    test('a Cassette release also counts as side-labelled', () async {
      final repo = _repository((_) => _releaseGroupResponse([
            {
              'id': 'cd-release',
              'date': '1987-07-21',
              'media': [
                {'format': 'CD', 'track-count': 12}
              ],
            },
            {
              'id': 'cassette-release',
              'date': '1987-08-01',
              'media': [
                {'format': 'Cassette', 'track-count': 12}
              ],
            },
          ]));

      final album = await repo.getOrFetch('release-group-3');
      expect(album.representativeReleaseMbid, 'cassette-release');
    });
  });

  group('refreshMetadata', () {
    test('overwrites an existing row while preserving ownership flags',
        () async {
      final repo = _repository((_) => _releaseGroupResponse([
            {
              'id': 'r1',
              'date': '1987-07-21',
              'media': [
                {'format': 'CD', 'track-count': 12}
              ],
            },
          ]));
      await repo.getOrFetch('release-group-1');
      repo.setOwnership('release-group-1', ownsCd: true);

      final refreshed = await repo.refreshMetadata('release-group-1');

      expect(refreshed.title, 'Appetite for Destruction');
      expect(refreshed.ownsCd, isTrue);
    });

    test('strips a bracket-only title, same as getOrFetch', () async {
      final repo = _repository((_) => {
            'title': '[Untitled]',
            'artist-credit': [
              {
                'name': 'Some Artist',
                'artist': {'name': 'Some Artist'}
              }
            ],
            'first-release-date': '2000-01-01',
            'genres': [],
            'releases': <Map<String, dynamic>>[],
          });

      final refreshed = await repo.refreshMetadata('release-group-untitled');

      expect(refreshed.title, 'Untitled');
    });
  });
}
