import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:cairn/core/db/app_database.dart';
import 'package:cairn/core/network/http_client.dart';
import 'package:cairn/core/network/response_cache.dart';
import 'package:cairn/data/remote/musicbrainz_client.dart';
import 'package:cairn/data/remote/coverart_client.dart';
import 'package:cairn/data/repositories/album_repository.dart';
import 'package:cairn/data/repositories/backup_repository.dart';
import 'package:cairn/data/repositories/export_repository.dart';
import 'package:cairn/data/repositories/import_repository.dart';
import 'package:cairn/data/repositories/rating_repository.dart';

void main() {
  test(
      'previews new/overwrite/unmatched, then apply writes with imported-always-overwrites semantics and preserved rated_at',
      () async {
    // Both mbids are pre-populated in the local `albums` cache, so
    // getOrFetch() never reaches the network — matching export_repository_test's
    // no-live-API-calls convention.
    final database = AppDatabase.memory();
    final http = ApiHttpClient(MockClient((request) async {
      fail('cached albums should not trigger a network request');
    }));
    final cache = ResponseCache(database);
    final albums = AlbumRepository(
        database, MusicBrainzClient(http, cache), CoverArtClient(http, cache));
    final ratings = RatingRepository(database);
    final backups = BackupRepository(database);
    final import = ImportRepository(ratings, albums, backups);

    database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
      ['new-album', 'New Album', 'Artist'],
    );
    database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
      ['existing-album', 'Existing Album', 'Artist'],
    );
    ratings.rate('existing-album', 4,
        notes: 'old note', ratedAt: DateTime.utc(2020, 1, 1));

    final json = '''
    [
      {"mbid":"new-album","title":"New Album","artist":"Artist","year":2020,"genres":[],"stars":5,"rated_at":"2021-06-01T00:00:00.000Z","notes":"fresh"},
      {"mbid":"existing-album","title":"Existing Album","artist":"Artist","year":2020,"genres":[],"stars":2,"rated_at":"2022-06-01T00:00:00.000Z","notes":"replaced"},
      {"mbid":null,"title":"No Id Album","artist":"Artist","year":2020,"genres":[],"stars":5,"rated_at":"2021-06-01T00:00:00.000Z","notes":null}
    ]
    ''';

    final preview = await import.preview(json);
    expect(preview.newCount, 1);
    expect(preview.overwriteCount, 1);
    expect(preview.unmatchedCount, 1);
    expect(preview.newRows.single.mbid, 'new-album');
    expect(preview.overwriteRows.single.mbid, 'existing-album');
    expect(preview.unmatchedRows.single.title, 'No Id Album');

    final directory =
        await Directory.systemTemp.createTemp('cairn-import-test-');
    final written = await import.apply(preview, directory.path);
    expect(written, 2);

    final newRating = ratings.ratingFor('new-album');
    expect(newRating?.stars, 5);
    expect(newRating?.notes, 'fresh');
    expect(newRating?.ratedAt, DateTime.parse('2021-06-01T00:00:00.000Z'));

    final overwritten = ratings.ratingFor('existing-album');
    expect(overwritten?.stars, 2);
    expect(overwritten?.notes, 'replaced');
    expect(overwritten?.ratedAt, DateTime.parse('2022-06-01T00:00:00.000Z'));

    // The pre-import safety snapshot must exist and reflect the database
    // *before* this apply() call — verified by BackupRepository's own
    // atomic-replace machinery, which this reuses.
    final snapshotPath =
        '${directory.path}/${BackupRepository.preImportFileName}';
    expect(await File(snapshotPath).exists(), isTrue);
    final snapshot = AppDatabase.open(snapshotPath);
    expect(
        snapshot.db.select('SELECT stars FROM ratings WHERE album_mbid = ?',
            ['existing-album']).single['stars'],
        4);
    expect(
        snapshot.db.select('SELECT * FROM ratings WHERE album_mbid = ?',
            ['new-album']).isEmpty,
        isTrue);
    snapshot.close();

    database.close();
    await directory.delete(recursive: true);
  });

  test('an mbid that fails to resolve is reported unmatched, not guessed',
      () async {
    final database = AppDatabase.memory();
    final apiHttp = ApiHttpClient(MockClient((request) async {
      return http.Response('not found', 404);
    }));
    final cache = ResponseCache(database);
    final albums = AlbumRepository(database, MusicBrainzClient(apiHttp, cache),
        CoverArtClient(apiHttp, cache));
    final ratings = RatingRepository(database);
    final backups = BackupRepository(database);
    final import = ImportRepository(ratings, albums, backups);

    final json = '''
    [{"mbid":"unknown-mbid","title":"Ghost Album","artist":"Artist","year":2020,"genres":[],"stars":5,"rated_at":"2021-06-01T00:00:00.000Z","notes":null}]
    ''';

    final preview = await import.preview(json);
    expect(preview.newCount, 0);
    expect(preview.overwriteCount, 0);
    expect(preview.unmatchedCount, 1);

    database.close();
  });

  test('CSV export round-trips through import parsing', () async {
    final database = AppDatabase.memory();
    final http = ApiHttpClient(MockClient((request) async {
      fail('cached albums should not trigger a network request');
    }));
    final cache = ResponseCache(database);
    final albums = AlbumRepository(
        database, MusicBrainzClient(http, cache), CoverArtClient(http, cache));
    final ratings = RatingRepository(database);
    final export = ExportRepository(ratings, albums);

    database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name, genres) VALUES (?, ?, ?, ?)',
      ['a1', 'A Title, With Comma', 'Some "Artist"', '["jazz","fusion"]'],
    );
    ratings.rate('a1', 5, notes: 'great record');

    final csv = await export.toCsv();
    final otherDatabase = AppDatabase.memory();
    final otherAlbums = AlbumRepository(otherDatabase,
        MusicBrainzClient(http, cache), CoverArtClient(http, cache));
    final otherRatings = RatingRepository(otherDatabase);
    otherDatabase.db.execute(
      'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
      ['a1', 'A Title, With Comma', 'Some "Artist"'],
    );
    final otherImport = ImportRepository(
        otherRatings, otherAlbums, BackupRepository(otherDatabase));

    final preview = await otherImport.preview(csv);
    expect(preview.newCount, 1);
    expect(preview.newRows.single.notes, 'great record');
    expect(preview.newRows.single.stars, 5);

    database.close();
    otherDatabase.close();
  });

  test('onProgress reports current/total, cache status, and outcome per row',
      () async {
    final database = AppDatabase.memory();
    final apiHttp = ApiHttpClient(MockClient((request) async {
      fail('cached albums should not trigger a network request');
    }));
    final cache = ResponseCache(database);
    final albums = AlbumRepository(database, MusicBrainzClient(apiHttp, cache),
        CoverArtClient(apiHttp, cache));
    final ratings = RatingRepository(database);
    final backups = BackupRepository(database);
    final import = ImportRepository(ratings, albums, backups);

    database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
      ['cached-album', 'Cached Album', 'Artist'],
    );

    final json = '''
    [
      {"mbid":"cached-album","title":"Cached Album","artist":"Artist","year":2020,"genres":[],"stars":5,"rated_at":"2021-06-01T00:00:00.000Z","notes":null},
      {"mbid":null,"title":"No Id","artist":"Artist","year":2020,"genres":[],"stars":5,"rated_at":"2021-06-01T00:00:00.000Z","notes":null}
    ]
    ''';

    final reported = <ImportProgress>[];
    await import.preview(json, onProgress: reported.add);

    expect(reported.length, 2);
    expect(reported[0].current, 1);
    expect(reported[0].total, 2);
    expect(reported[0].cached, isTrue);
    expect(reported[0].outcome, ImportRowOutcome.added);
    expect(reported[1].current, 2);
    expect(reported[1].cached, isNull);
    expect(reported[1].outcome, ImportRowOutcome.unmatched);

    database.close();
  });

  test('a pre-mbid (7-column) CSV export is reported unmatched, not misread',
      () async {
    final database = AppDatabase.memory();
    final apiHttp = ApiHttpClient(MockClient((request) async {
      fail('unmatched rows should not trigger a network request');
    }));
    final cache = ResponseCache(database);
    final albums = AlbumRepository(database, MusicBrainzClient(apiHttp, cache),
        CoverArtClient(apiHttp, cache));
    final ratings = RatingRepository(database);
    final backups = BackupRepository(database);
    final import = ImportRepository(ratings, albums, backups);

    // The export format before this session added `mbid` as the first
    // column — a real file a user could still have on disk.
    const oldCsv = 'title,artist,year,genres,stars,rated_at,notes\n'
        'Old Album,Artist,2019,rock,4,2020-01-01T00:00:00.000Z,liked it\n';

    final preview = await import.preview(oldCsv);
    expect(preview.newCount, 0);
    expect(preview.overwriteCount, 0);
    expect(preview.unmatchedCount, 1);
    expect(preview.unmatchedRows.single.title, 'Old Album');
    expect(preview.unmatchedRows.single.stars, 4);

    database.close();
  });

  test('a multi-line note survives a CSV export/import round-trip', () async {
    final database = AppDatabase.memory();
    final apiHttp = ApiHttpClient(MockClient((request) async {
      fail('cached albums should not trigger a network request');
    }));
    final cache = ResponseCache(database);
    final albums = AlbumRepository(database, MusicBrainzClient(apiHttp, cache),
        CoverArtClient(apiHttp, cache));
    final ratings = RatingRepository(database);
    final backups = BackupRepository(database);
    final export = ExportRepository(ratings, albums);
    final import = ImportRepository(ratings, albums, backups);

    database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
      ['a1', 'Album', 'Artist'],
    );
    ratings.rate('a1', 5, notes: 'Great production\nweak vocals');

    final csv = await export.toCsv();
    final preview = await import.preview(csv);
    expect(preview.overwriteCount, 1);
    expect(preview.overwriteRows.single.notes, 'Great production\nweak vocals');

    database.close();
  });

  test('apply() restores owns_cd/owns_vinyl onto the local album', () async {
    final database = AppDatabase.memory();
    final apiHttp = ApiHttpClient(MockClient((request) async {
      fail('cached albums should not trigger a network request');
    }));
    final cache = ResponseCache(database);
    final albums = AlbumRepository(database, MusicBrainzClient(apiHttp, cache),
        CoverArtClient(apiHttp, cache));
    final ratings = RatingRepository(database);
    final backups = BackupRepository(database);
    final import = ImportRepository(ratings, albums, backups);

    database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
      ['a1', 'Album', 'Artist'],
    );

    final json = '''
    [{"mbid":"a1","title":"Album","artist":"Artist","year":2020,"genres":[],"stars":5,"rated_at":"2021-06-01T00:00:00.000Z","notes":null,"owns_cd":true,"owns_vinyl":false}]
    ''';

    final preview = await import.preview(json);
    expect(preview.newRows.single.ownsCd, isTrue);
    expect(preview.newRows.single.ownsVinyl, isFalse);

    final directory =
        await Directory.systemTemp.createTemp('cairn-import-ownership-test-');
    await import.apply(preview, directory.path);
    expect(albums.isCachedLocally('a1'), isTrue);
    final row = database.db.select(
        'SELECT owns_cd, owns_vinyl FROM albums WHERE mbid = ?', ['a1']).single;
    expect(row['owns_cd'], 1);
    expect(row['owns_vinyl'], 0);

    database.close();
    await directory.delete(recursive: true);
  });

  test('CSV export/import round-trip preserves ownership', () async {
    final database = AppDatabase.memory();
    final apiHttp = ApiHttpClient(MockClient((request) async {
      fail('cached albums should not trigger a network request');
    }));
    final cache = ResponseCache(database);
    final albums = AlbumRepository(database, MusicBrainzClient(apiHttp, cache),
        CoverArtClient(apiHttp, cache));
    final ratings = RatingRepository(database);
    final backups = BackupRepository(database);
    final export = ExportRepository(ratings, albums);
    final import = ImportRepository(ratings, albums, backups);

    database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name, owns_cd, owns_vinyl) VALUES (?, ?, ?, ?, ?)',
      ['a1', 'Album', 'Artist', 0, 1],
    );
    ratings.rate('a1', 4);

    final csv = await export.toCsv();
    final preview = await import.preview(csv);
    expect(preview.overwriteRows.single.ownsCd, isFalse);
    expect(preview.overwriteRows.single.ownsVinyl, isTrue);

    database.close();
  });

  test('a CSV file predating ownership columns defaults to not-owned',
      () async {
    final database = AppDatabase.memory();
    final apiHttp = ApiHttpClient(MockClient((request) async {
      fail('cached albums should not trigger a network request');
    }));
    final cache = ResponseCache(database);
    final albums = AlbumRepository(database, MusicBrainzClient(apiHttp, cache),
        CoverArtClient(apiHttp, cache));
    final ratings = RatingRepository(database);
    final backups = BackupRepository(database);
    final import = ImportRepository(ratings, albums, backups);

    database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
      ['a1', 'Album', 'Artist'],
    );

    // The 8-column format from earlier this session — mbid added, but no
    // ownership columns yet.
    const oldCsv = 'mbid,title,artist,year,genres,stars,rated_at,notes\n'
        'a1,Album,Artist,2020,,5,2021-06-01T00:00:00.000Z,\n';

    final preview = await import.preview(oldCsv);
    expect(preview.newRows.single.ownsCd, isFalse);
    expect(preview.newRows.single.ownsVinyl, isFalse);

    database.close();
  });
}
