import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:cairn/core/db/app_database.dart';
import 'package:cairn/core/network/http_client.dart';
import 'package:cairn/core/network/response_cache.dart';
import 'package:cairn/data/models/album.dart';
import 'package:cairn/data/remote/musicbrainz_client.dart';
import 'package:cairn/data/remote/odesli_client.dart';
import 'package:cairn/data/repositories/deep_link_repository.dart';

DeepLinkRepository _repository() {
  final db = AppDatabase.memory();
  final httpClient = ApiHttpClient(MockClient((request) async {
    fail('URL-building methods must not make network requests (requested ${request.url})');
  }));
  final cache = ResponseCache(db);
  final musicBrainz = MusicBrainzClient(httpClient, cache);
  final odesli = OdesliClient(httpClient, cache);
  return DeepLinkRepository(db, musicBrainz, odesli);
}

void main() {
  group('spotifySearchUrl', () {
    test('builds a Spotify search URL from artist and title, no network call', () {
      final repo = _repository();
      final album = Album(mbid: 'm1', title: 'Kind of Blue', artistName: 'Miles Davis');
      expect(repo.spotifySearchUrl(album),
          'https://open.spotify.com/search/Miles%20Davis%20Kind%20of%20Blue');
    });

    test('URL-encodes special characters in artist/title', () {
      final repo = _repository();
      final album = Album(mbid: 'm2', title: 'Sgt. Pepper\'s & Friends', artistName: 'AC/DC');
      final url = repo.spotifySearchUrl(album);
      expect(url, startsWith('https://open.spotify.com/search/'));
      // A raw '/' would break the path-segment search format; encoding it
      // is exactly what distinguishes Uri.encodeComponent from the plain
      // query-component encoding used by searchFallbackUrl.
      expect(url, contains(Uri.encodeComponent('AC/DC')));
      expect(url, isNot(contains('AC/DC')));
    });
  });

  group('youtubeMusicSearchUrl', () {
    test('builds a YouTube Music search URL from artist and title, no network call', () {
      final repo = _repository();
      final album = Album(mbid: 'm3', title: 'Kind of Blue', artistName: 'Miles Davis');
      expect(repo.youtubeMusicSearchUrl(album),
          'https://music.youtube.com/search?q=Miles%20Davis%20Kind%20of%20Blue');
    });
  });
}
