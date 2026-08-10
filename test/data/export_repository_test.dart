import 'package:test/test.dart';
import 'package:record_reccomend/core/db/app_database.dart';
import 'package:record_reccomend/core/network/http_client.dart';
import 'package:record_reccomend/core/network/response_cache.dart';
import 'package:record_reccomend/data/remote/musicbrainz_client.dart';
import 'package:record_reccomend/data/remote/coverart_client.dart';
import 'package:record_reccomend/data/repositories/album_repository.dart';
import 'package:record_reccomend/data/repositories/rating_repository.dart';
import 'package:record_reccomend/data/repositories/export_repository.dart';

void main() {
  test('CSV export escapes commas/quotes, JSON export includes rating fields', () async {
    // In-memory DB pre-populated directly via SQL — getOrFetch() hits the
    // local cache and never reaches the network, so this test makes no live
    // API calls despite constructing real client objects.
    final database = AppDatabase.memory();
    final http = ApiHttpClient();
    final cache = ResponseCache(database);
    final albums = AlbumRepository(database, MusicBrainzClient(http, cache), CoverArtClient(http, cache));
    final ratings = RatingRepository(database);
    final export = ExportRepository(ratings, albums);

    database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name, first_release_year, genres) VALUES (?, ?, ?, ?, ?)',
      ['a1', 'A Title, With Comma', 'Some "Artist"', 1994, '["jazz","fusion"]'],
    );
    ratings.rate('a1', 5, notes: 'great record');

    final csv = await export.toCsv();
    expect(csv, contains('"A Title, With Comma"'));
    expect(csv, contains('"Some ""Artist"""'));
    expect(csv, contains('jazz; fusion'));

    final json = await export.toJson();
    expect(json, contains('"stars":5'));
    expect(json, contains('"great record"'));
    expect(json, contains('"year":1994'));

    http.close();
    database.close();
  });
}
