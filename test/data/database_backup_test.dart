import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:cairn/core/db/app_database.dart';
import 'package:cairn/data/repositories/backup_repository.dart';
import 'package:cairn/data/repositories/rating_repository.dart';
import 'package:cairn/data/repositories/settings_repository.dart';

void main() {
  test('opening an older schema preserves existing ratings and adds columns',
      () {
    final directory = Directory.systemTemp.createTempSync('cairn-db-test-');
    final path = '${directory.path}/cairn.db';
    final legacy = sqlite3.open(path);
    legacy.execute(
        'CREATE TABLE albums (mbid TEXT PRIMARY KEY, title TEXT NOT NULL, artist_name TEXT NOT NULL)');
    legacy.execute(
        'CREATE TABLE ratings (album_mbid TEXT PRIMARY KEY, stars INTEGER NOT NULL, rated_at INTEGER NOT NULL, notes TEXT)');
    legacy.execute(
        'CREATE TABLE app_state (id INTEGER PRIMARY KEY CHECK (id = 0), current_anchor_mbid TEXT)');
    legacy.execute(
        'INSERT INTO albums (mbid, title, artist_name) VALUES (\'a1\', \'Album\', \'Artist\')');
    legacy.execute(
        'INSERT INTO ratings (album_mbid, stars, rated_at, notes) VALUES (\'a1\', 5, 123, \'kept\')');
    legacy.close();

    final database = AppDatabase.open(path);
    final rating = RatingRepository(database).ratingFor('a1');
    expect(rating?.stars, 5);
    expect(rating?.notes, 'kept');
    final settings = SettingsRepository(database);
    settings.setAutoBackupsEnabled(true);
    expect(settings.autoBackupsEnabled(), isTrue);
    database.close();
    directory.deleteSync(recursive: true);
  });

  test(
      'opening migrates legacy 1-5 star ratings to the three-tier scale (2/4/5)',
      () {
    final directory =
        Directory.systemTemp.createTempSync('cairn-stars-migration-test-');
    final path = '${directory.path}/cairn.db';
    final db = AppDatabase.open(path);
    for (var i = 1; i <= 5; i++) {
      db.db.execute(
        'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
        ['a$i', 'Album $i', 'Artist'],
      );
      db.db.execute(
        'INSERT INTO ratings (album_mbid, stars, rated_at) VALUES (?, ?, ?)',
        ['a$i', i, 123],
      );
    }
    db.close();

    // Re-opening (the migration runs on every open, not just the first)
    // must be a no-op on already-canonical values.
    final reopened = AppDatabase.open(path);
    final rows = reopened.db
        .select('SELECT album_mbid, stars FROM ratings ORDER BY album_mbid');
    final starsByAlbum = {
      for (final row in rows) row['album_mbid'] as String: row['stars'] as int
    };
    expect(starsByAlbum, {
      'a1': 2, // was 1 (dislike)
      'a2': 2, // already canonical
      'a3': 4, // was 3 (old neutral -> like)
      'a4': 4, // already canonical
      'a5': 5, // already canonical
    });
    reopened.close();
    directory.deleteSync(recursive: true);
  });

  test('weekly backup replaces only the backup copy', () async {
    final directory =
        await Directory.systemTemp.createTemp('cairn-backup-test-');
    final database = AppDatabase.memory();
    database.db.execute(
      'INSERT INTO albums (mbid, title, artist_name) VALUES (?, ?, ?)',
      ['a1', 'First', 'Artist'],
    );
    final backup = BackupRepository(database);

    await backup.createWeeklyBackup(directory.path);
    final backupPath = '${directory.path}/${BackupRepository.fileName}';
    final firstCopy = AppDatabase.open(backupPath);
    expect(firstCopy.db.select('SELECT title FROM albums').single['title'],
        'First');
    firstCopy.close();

    database.db.execute(
        'UPDATE albums SET title = ? WHERE mbid = ?', ['Second', 'a1']);
    await backup.createWeeklyBackup(directory.path);
    final secondCopy = AppDatabase.open(backupPath);
    expect(secondCopy.db.select('SELECT title FROM albums').single['title'],
        'Second');
    secondCopy.close();

    expect(database.db.select('SELECT title FROM albums').single['title'],
        'Second');
    database.close();
    await directory.delete(recursive: true);
  });
}
