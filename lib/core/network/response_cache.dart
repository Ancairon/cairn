import 'dart:convert';
import '../db/app_database.dart';

/// Generic response cache over the api_cache table, keyed by an arbitrary
/// string each remote client controls. Keeps repeated lookups off the
/// network and off MusicBrainz's rate limit.
class ResponseCache {
  final AppDatabase database;

  ResponseCache(this.database);

  Map<String, dynamic>? get(String key) {
    final rows = database.db.select(
      'SELECT response_json, fetched_at, ttl_seconds FROM api_cache WHERE cache_key = ?',
      [key],
    );
    if (rows.isEmpty) return null;

    final row = rows.first;
    final fetchedAt = row['fetched_at'] as int;
    final ttlSeconds = row['ttl_seconds'] as int;
    final ageSeconds = (DateTime.now().millisecondsSinceEpoch - fetchedAt) ~/ 1000;
    if (ageSeconds > ttlSeconds) return null;

    return jsonDecode(row['response_json'] as String) as Map<String, dynamic>;
  }

  void put(String key, Map<String, dynamic> value, {required int ttlSeconds}) {
    database.db.execute(
      'INSERT INTO api_cache (cache_key, response_json, fetched_at, ttl_seconds) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(cache_key) DO UPDATE SET '
      'response_json = excluded.response_json, '
      'fetched_at = excluded.fetched_at, '
      'ttl_seconds = excluded.ttl_seconds',
      [key, jsonEncode(value), DateTime.now().millisecondsSinceEpoch, ttlSeconds],
    );
  }
}
