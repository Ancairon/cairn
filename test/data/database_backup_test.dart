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
