import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:cairn/core/db/app_database.dart';
import 'package:cairn/core/network/http_client.dart';
import 'package:cairn/core/network/response_cache.dart';
import 'package:cairn/data/models/saved_filter.dart';
import 'package:cairn/data/remote/musicbrainz_client.dart';
import 'package:cairn/data/remote/coverart_client.dart';
import 'package:cairn/data/remote/listenbrainz_client.dart';
import 'package:cairn/data/repositories/album_repository.dart';
import 'package:cairn/data/repositories/backup_repository.dart';
import 'package:cairn/data/repositories/export_repository.dart';
import 'package:cairn/data/repositories/import_repository.dart';
import 'package:cairn/data/repositories/rating_repository.dart';
import 'package:cairn/data/repositories/recommendation_repository.dart';
import 'package:cairn/data/repositories/saved_filter_repository.dart';
import 'package:cairn/data/repositories/settings_repository.dart';

/// Bundles every repository export/import depend on, built from one
/// in-memory database — avoids repeating the same six-repository wiring in
/// every test.
class _Harness {
  final AppDatabase database;
  final AlbumRepository albums;
  final RatingRepository ratings;
  final RecommendationRepository recommendations;
  final SavedFilterRepository savedFilters;
  final SettingsRepository settings;
  final BackupRepository backups;
  final ExportRepository export;
  final ImportRepository import;

  _Harness._(this.database, this.albums, this.ratings, this.recommendations,
      this.savedFilters, this.settings, this.backups, this.export, this.import);

  factory _Harness(AppDatabase database, ApiHttpClient apiHttp) {
    final cache = ResponseCache(database);
    final albums = AlbumRepository(database, MusicBrainzClient(apiHttp, cache),
        CoverArtClient(apiHttp, cache));
    final ratings = RatingRepository(database);
    final recommendations = RecommendationRepository(
        database,
        MusicBrainzClient(apiHttp, cache),
        ListenBrainzClient(apiHttp, cache),
        albums,
        ratings);
    final savedFilters = SavedFilterRepository(database);
    final settings = SettingsRepository(database);
    final backups = BackupRepository(database);
    final export = ExportRepository(
        ratings, albums, recommendations, savedFilters, settings);
    final import = ImportRepository(
        ratings, albums, backups, recommendations, savedFilters, settings);
    return _Harness._(database, albums, ratings, recommendations, savedFilters,
        settings, backups, export, import);
  }

  void close() => database.close();
}

ApiHttpClient _failingHttp() => ApiHttpClient(MockClient((request) async {
      fail('cached/unmatched rows should not trigger a network request');
    }));

void main() {
  test(
      'previews new/overwrite/unmatched, then apply writes with imported-always-overwrites semantics and preserved rated_at',
      () async {
    // Both mbids are pre-populated in the local `albums` cache, so
    // getOrFetch() never reaches the network — matching export_repository_test's
    // no-live-API-calls convention.
    final h = _Harness(AppDatabase.memory(), _failingHttp());

    h.database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
      ['new-album', 'New Album', 'Artist'],
    );
    h.database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
      ['existing-album', 'Existing Album', 'Artist'],
    );
    h.ratings.rate('existing-album', 4,
        notes: 'old note', ratedAt: DateTime.utc(2020, 1, 1));

    final json = '''
    [
      {"mbid":"new-album","title":"New Album","artist":"Artist","year":2020,"genres":[],"stars":5,"rated_at":"2021-06-01T00:00:00.000Z","notes":"fresh"},
      {"mbid":"existing-album","title":"Existing Album","artist":"Artist","year":2020,"genres":[],"stars":2,"rated_at":"2022-06-01T00:00:00.000Z","notes":"replaced"},
      {"mbid":null,"title":"No Id Album","artist":"Artist","year":2020,"genres":[],"stars":5,"rated_at":"2021-06-01T00:00:00.000Z","notes":null}
    ]
    ''';

    final preview = await h.import.preview(json);
    expect(preview.newCount, 1);
    expect(preview.overwriteCount, 1);
    expect(preview.unmatchedCount, 1);
    expect(preview.newRows.single.mbid, 'new-album');
    expect(preview.overwriteRows.single.mbid, 'existing-album');
    expect(preview.unmatchedRows.single.title, 'No Id Album');

    final directory =
        await Directory.systemTemp.createTemp('cairn-import-test-');
    final written = await h.import.apply(preview, directory.path);
    expect(written, 2);

    final newRating = h.ratings.ratingFor('new-album');
    expect(newRating?.stars, 5);
    expect(newRating?.notes, 'fresh');
    expect(newRating?.ratedAt, DateTime.parse('2021-06-01T00:00:00.000Z'));

    final overwritten = h.ratings.ratingFor('existing-album');
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

    h.close();
    await directory.delete(recursive: true);
  });

  test('an mbid that fails to resolve is reported unmatched, not guessed',
      () async {
    final apiHttp = ApiHttpClient(MockClient((request) async {
      return http.Response('not found', 404);
    }));
    final h = _Harness(AppDatabase.memory(), apiHttp);

    final json = '''
    [{"mbid":"unknown-mbid","title":"Ghost Album","artist":"Artist","year":2020,"genres":[],"stars":5,"rated_at":"2021-06-01T00:00:00.000Z","notes":null}]
    ''';

    final preview = await h.import.preview(json);
    expect(preview.newCount, 0);
    expect(preview.overwriteCount, 0);
    expect(preview.unmatchedCount, 1);

    h.close();
  });

  test('CSV export round-trips through import parsing', () async {
    final h = _Harness(AppDatabase.memory(), _failingHttp());

    h.database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name, genres) VALUES (?, ?, ?, ?)',
      ['a1', 'A Title, With Comma', 'Some "Artist"', '["jazz","fusion"]'],
    );
    h.ratings.rate('a1', 5, notes: 'great record');

    final csv = await h.export.toCsv();
    final other = _Harness(AppDatabase.memory(), _failingHttp());
    other.database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
      ['a1', 'A Title, With Comma', 'Some "Artist"'],
    );

    final preview = await other.import.preview(csv);
    expect(preview.newCount, 1);
    expect(preview.newRows.single.notes, 'great record');
    expect(preview.newRows.single.stars, 5);

    h.close();
    other.close();
  });

  test('onProgress reports current/total, cache status, and outcome per row',
      () async {
    final h = _Harness(AppDatabase.memory(), _failingHttp());

    h.database.db.execute(
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
    await h.import.preview(json, onProgress: reported.add);

    expect(reported.length, 2);
    expect(reported[0].current, 1);
    expect(reported[0].total, 2);
    expect(reported[0].cached, isTrue);
    expect(reported[0].outcome, ImportRowOutcome.added);
    expect(reported[1].current, 2);
    expect(reported[1].cached, isNull);
    expect(reported[1].outcome, ImportRowOutcome.unmatched);

    h.close();
  });

  test('a pre-mbid (7-column) CSV export is reported unmatched, not misread',
      () async {
    final h = _Harness(AppDatabase.memory(), _failingHttp());

    // The export format before this session added `mbid` as the first
    // column — a real file a user could still have on disk.
    const oldCsv = 'title,artist,year,genres,stars,rated_at,notes\n'
        'Old Album,Artist,2019,rock,4,2020-01-01T00:00:00.000Z,liked it\n';

    final preview = await h.import.preview(oldCsv);
    expect(preview.newCount, 0);
    expect(preview.overwriteCount, 0);
    expect(preview.unmatchedCount, 1);
    expect(preview.unmatchedRows.single.title, 'Old Album');
    expect(preview.unmatchedRows.single.stars, 4);

    h.close();
  });

  test('a multi-line note survives a CSV export/import round-trip', () async {
    final h = _Harness(AppDatabase.memory(), _failingHttp());

    h.database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
      ['a1', 'Album', 'Artist'],
    );
    h.ratings.rate('a1', 5, notes: 'Great production\nweak vocals');

    final csv = await h.export.toCsv();
    final preview = await h.import.preview(csv);
    expect(preview.overwriteCount, 1);
    expect(preview.overwriteRows.single.notes, 'Great production\nweak vocals');

    h.close();
  });

  test('apply() restores owns_cd/owns_vinyl onto the local album', () async {
    final h = _Harness(AppDatabase.memory(), _failingHttp());

    h.database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
      ['a1', 'Album', 'Artist'],
    );

    final json = '''
    [{"mbid":"a1","title":"Album","artist":"Artist","year":2020,"genres":[],"stars":5,"rated_at":"2021-06-01T00:00:00.000Z","notes":null,"owns_cd":true,"owns_vinyl":false}]
    ''';

    final preview = await h.import.preview(json);
    expect(preview.newRows.single.ownsCd, isTrue);
    expect(preview.newRows.single.ownsVinyl, isFalse);

    final directory =
        await Directory.systemTemp.createTemp('cairn-import-ownership-test-');
    await h.import.apply(preview, directory.path);
    expect(h.albums.isCachedLocally('a1'), isTrue);
    final row = h.database.db.select(
        'SELECT owns_cd, owns_vinyl FROM albums WHERE mbid = ?', ['a1']).single;
    expect(row['owns_cd'], 1);
    expect(row['owns_vinyl'], 0);

    h.close();
    await directory.delete(recursive: true);
  });

  test('CSV export/import round-trip preserves ownership', () async {
    final h = _Harness(AppDatabase.memory(), _failingHttp());

    h.database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name, owns_cd, owns_vinyl) VALUES (?, ?, ?, ?, ?)',
      ['a1', 'Album', 'Artist', 0, 1],
    );
    h.ratings.rate('a1', 4);

    final csv = await h.export.toCsv();
    final preview = await h.import.preview(csv);
    expect(preview.overwriteRows.single.ownsCd, isFalse);
    expect(preview.overwriteRows.single.ownsVinyl, isTrue);

    h.close();
  });

  test('a CSV file predating ownership columns defaults to not-owned',
      () async {
    final h = _Harness(AppDatabase.memory(), _failingHttp());

    h.database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
      ['a1', 'Album', 'Artist'],
    );

    // The 8-column format from earlier this session — mbid added, but no
    // ownership columns yet.
    const oldCsv = 'mbid,title,artist,year,genres,stars,rated_at,notes\n'
        'a1,Album,Artist,2020,,5,2021-06-01T00:00:00.000Z,\n';

    final preview = await h.import.preview(oldCsv);
    expect(preview.newRows.single.ownsCd, isFalse);
    expect(preview.newRows.single.ownsVinyl, isFalse);

    h.close();
  });

  test(
      'JSON export includes liked genres/saved filters/settings, and import applies them',
      () async {
    final source = _Harness(AppDatabase.memory(), _failingHttp());
    source.recommendations.setLikedGenres(['jazz', 'ambient']);
    source.savedFilters
        .create('CD only', const FilterCriteria(ownership: 'cd', minRating: 4));
    source.settings.setDefaultPlayerApp('spotify');
    source.settings.setRatedAlbumsSort('title');

    final json = await source.export.toJson();

    final dest = _Harness(AppDatabase.memory(), _failingHttp());
    final preview = await dest.import.preview(json);
    expect(preview.likedGenres, ['jazz', 'ambient']);
    expect(preview.savedFilters!.single.name, 'CD only');
    expect(preview.savedFilters!.single.criteria.ownership, 'cd');
    expect(preview.settings!.defaultPlayerApp, 'spotify');
    expect(preview.settings!.ratedAlbumsSort, 'title');

    final directory =
        await Directory.systemTemp.createTemp('cairn-import-extras-test-');
    await dest.import.apply(preview, directory.path);

    expect(dest.recommendations.likedGenres(), ['jazz', 'ambient']);
    expect(dest.savedFilters.all().single.name, 'CD only');
    expect(dest.settings.defaultPlayerApp(), 'spotify');
    expect(dest.settings.ratedAlbumsSort(), 'title');
    // Device-specific settings must never travel via import.
    expect(dest.settings.backupFolderPath(), isNull);
    expect(dest.settings.autoBackupsEnabled(), isFalse);

    source.close();
    dest.close();
    await directory.delete(recursive: true);
  });

  test(
      'apply() overwrites a saved filter with the same name instead of duplicating it',
      () async {
    final h = _Harness(AppDatabase.memory(), _failingHttp());
    h.savedFilters.create('My filter', const FilterCriteria(ownership: 'cd'));

    final json = jsonWithSavedFilter(name: 'My filter', ownership: 'vinyl');
    final preview = await h.import.preview(json);
    final directory =
        await Directory.systemTemp.createTemp('cairn-import-filter-test-');
    await h.import.apply(preview, directory.path);

    final all = h.savedFilters.all();
    expect(all.length, 1);
    expect(all.single.criteria.ownership, 'vinyl');

    h.close();
    await directory.delete(recursive: true);
  });

  test('a legacy bare-array JSON export never touches genres/filters/settings',
      () async {
    final h = _Harness(AppDatabase.memory(), _failingHttp());
    h.recommendations.setLikedGenres(['keep-me']);

    const legacyJson = '[]';
    final preview = await h.import.preview(legacyJson);
    expect(preview.likedGenres, isNull);
    expect(preview.savedFilters, isNull);
    expect(preview.settings, isNull);

    final directory =
        await Directory.systemTemp.createTemp('cairn-import-legacy-test-');
    await h.import.apply(preview, directory.path);
    expect(h.recommendations.likedGenres(), ['keep-me']);

    h.close();
    await directory.delete(recursive: true);
  });
}

String jsonWithSavedFilter({required String name, required String ownership}) {
  return '''
  {
    "ratings": [],
    "liked_genres": [],
    "saved_filters": [{"name": "$name", "ownership": "$ownership", "min_rating": null, "max_rating": null}],
    "settings": {"default_opened_menu_item": null, "default_player_app": null, "rated_albums_sort": null, "rated_albums_view": null, "rated_albums_size": null}
  }
  ''';
}
