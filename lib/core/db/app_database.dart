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
    liked_genres TEXT
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

/// Opens the local SQLite database and ensures the schema exists.
/// See .agents/sow/specs/architecture.md for the full schema rationale.
class AppDatabase {
  final Database db;

  AppDatabase(this.db) {
    for (final statement in _schema) {
      db.execute(statement);
    }
  }

  factory AppDatabase.open(String path) => AppDatabase(sqlite3.open(path));

  factory AppDatabase.memory() => AppDatabase(sqlite3.openInMemory());

  void close() => db.close();
}
