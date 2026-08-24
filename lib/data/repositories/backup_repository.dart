import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../core/db/app_database.dart';

/// Creates a consistent copy of the live database without touching it.
class BackupRepository {
  final AppDatabase database;

  BackupRepository(this.database);

  static const fileName = 'cairn_weekly.db';

  /// Single rolling safety net written just before an import overwrites
  /// ratings — always the same filename, so it never accumulates unbounded
  /// snapshots in the app's own documents directory.
  static const preImportFileName = 'cairn_pre_import.db';

  bool isDue(DateTime now, DateTime? lastBackup) =>
      lastBackup == null ||
      now.toUtc().difference(lastBackup.toUtc()) >= const Duration(days: 7);

  Future<void> createWeeklyBackup(String folderPath) =>
      _snapshotTo(folderPath, fileName);

  Future<void> createPreImportSafetySnapshot(String folderPath) =>
      _snapshotTo(folderPath, preImportFileName);

  Future<void> _snapshotTo(String folderPath, String targetFileName) async {
    final folder = Directory(folderPath);
    if (!await folder.exists()) {
      throw StateError('The selected backup folder no longer exists.');
    }

    final destination = File(p.join(folder.path, targetFileName));
    final temporary = File(p.join(folder.path,
        '.$targetFileName.${DateTime.now().microsecondsSinceEpoch}.tmp'));
    final backupDb = sqlite3.open(temporary.path);
    var closed = false;
    try {
      await database.db.backup(backupDb, nPage: -1).drain();
      backupDb.close();
      closed = true;
      await _replace(destination, temporary);
    } catch (_) {
      if (!closed) backupDb.close();
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> _replace(File destination, File temporary) async {
    final previous = File('${destination.path}.previous');
    if (await previous.exists()) await previous.delete();
    if (await destination.exists()) await destination.rename(previous.path);
    try {
      await temporary.rename(destination.path);
      if (await previous.exists()) await previous.delete();
    } catch (_) {
      if (await destination.exists()) await destination.delete();
      if (await previous.exists()) await previous.rename(destination.path);
      rethrow;
    }
  }
}
