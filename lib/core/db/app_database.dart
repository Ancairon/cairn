import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

const _schema = [
  '''
  CREATE TABLE IF NOT EXISTS albums (
    mbid TEXT PRIMARY KEY,
    representative_release_mbid TEXT,
    title TEXT NOT NULL,
    artist_name TEXT NOT NULL,
    artist_mbid TEXT,
    first_release_year INTEGER,
    genres TEXT,
    cover_art_url TEXT,
    metadata_fetched_at INTEGER,
    owns_cd INTEGER NOT NULL DEFAULT 0,
    owns_vinyl INTEGER NOT NULL DEFAULT 0
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS tracks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    album_mbid TEXT NOT NULL REFERENCES albums(mbid),
    recording_mbid TEXT,
    position INTEGER,
    title TEXT NOT NULL,
    duration_ms INTEGER
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS ratings (
    album_mbid TEXT PRIMARY KEY REFERENCES albums(mbid),
    stars INTEGER NOT NULL CHECK(stars BETWEEN 1 AND 5),
    rated_at INTEGER NOT NULL,
    notes TEXT
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS album_skip_penalties (
    album_mbid TEXT PRIMARY KEY,
    skip_count INTEGER NOT NULL,
    last_skipped_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS track_favorites (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id INTEGER NOT NULL REFERENCES tracks(id),
    album_mbid TEXT NOT NULL,
    favorited_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS app_state (
    id INTEGER PRIMARY KEY CHECK (id = 0),
    current_anchor_mbid TEXT,
    recent_pivot_buckets TEXT,
    liked_genres TEXT,
    default_expanded_menu_item TEXT,
    recent_fallback_seed_mbids TEXT,
    default_player_app TEXT,
    rated_albums_sort TEXT,
    rated_albums_view TEXT,
    rated_albums_size TEXT
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS saved_filters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    criteria_json TEXT NOT NULL,
    created_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS external_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    album_mbid TEXT NOT NULL,
    service TEXT NOT NULL,
    url TEXT NOT NULL,
    fetched_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS resolved_platform_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    album_mbid TEXT NOT NULL,
    service TEXT NOT NULL,
    url TEXT NOT NULL,
    fetched_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS api_cache (
    cache_key TEXT PRIMARY KEY,
    response_json TEXT NOT NULL,
    fetched_at INTEGER NOT NULL,
    ttl_seconds INTEGER NOT NULL
  )
  ''',
];

// CREATE TABLE IF NOT EXISTS is a no-op on a table that already exists, so a
// plain schema addition never reaches an install that updates on top of an
// existing app (adb install -r preserves the on-device DB). This is a
// deliberately minimal, additive-only migration — it only ever adds a
// missing column with its declared default, never renames/drops/alters
// existing data. See .agents/skills/project-android-toolchain/SKILL.md.
const _additiveColumns = {
  'app_state': [
    'current_anchor_mbid TEXT',
    'recent_pivot_buckets TEXT',
    'liked_genres TEXT',
    'default_expanded_menu_item TEXT',
    'recent_fallback_seed_mbids TEXT',
    'default_player_app TEXT',
    'last_shown_album_mbid TEXT',
    'rated_albums_sort TEXT',
    'rated_albums_view TEXT',
    'rated_albums_size TEXT',
    'auto_backups_enabled INTEGER NOT NULL DEFAULT 0',
    'backup_consent TEXT',
    'backup_folder_path TEXT',
    'last_backup_at INTEGER',
  ],
};

/// Opens the local SQLite database and ensures the schema exists.
/// See .agents/sow/specs/architecture.md for the full schema rationale.
class AppDatabase {
  final Database db;

  AppDatabase(this.db) {
    for (final statement in _schema) {
      db.execute(statement);
    }
    _ensureAdditiveColumns();
  }

  void _ensureAdditiveColumns() {
    for (final entry in _additiveColumns.entries) {
      final existingColumns = db
          .select('PRAGMA table_info(${entry.key})')
          .map((row) => row['name'] as String)
          .toSet();
      for (final columnDef in entry.value) {
        final columnName = columnDef.split(' ').first;
        if (!existingColumns.contains(columnName)) {
          db.execute('ALTER TABLE ${entry.key} ADD COLUMN $columnDef');
        }
      }
    }
  }

  factory AppDatabase.open(String path) => AppDatabase(sqlite3.open(path));

  factory AppDatabase.memory() => AppDatabase(sqlite3.openInMemory());

  void close() => db.close();

  /// One-time migration for the record_reccomend -> Cairn rename: copies an
  /// existing legacy database file forward so local ratings aren't lost.
  static void migrateLegacyFile(String legacyPath, String newPath) {
    final legacy = File(legacyPath);
    if (legacy.existsSync() && !File(newPath).existsSync()) {
      legacy.copySync(newPath);
    }
  }
}
