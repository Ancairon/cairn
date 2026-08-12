import '../../core/db/app_database.dart';

/// Free-text comments the user writes locally on an album, or on one of its
/// tracks. Tracks have no persisted local row (see architecture.md — the
/// `tracks` table exists but nothing writes to it), so track notes key off
/// `Track.stableKey` instead of a database-assigned id.
class NotesRepository {
  final AppDatabase database;

  NotesRepository(this.database);

  String? albumNote(String albumMbid) {
    final rows = database.db.select(
      'SELECT note FROM album_notes WHERE album_mbid = ?',
      [albumMbid],
    );
    return rows.isEmpty ? null : rows.first['note'] as String;
  }

  void setAlbumNote(String albumMbid, String note) {
    if (note.trim().isEmpty) {
      deleteAlbumNote(albumMbid);
      return;
    }
    database.db.execute(
      'INSERT INTO album_notes (album_mbid, note, updated_at) VALUES (?, ?, ?) '
      'ON CONFLICT(album_mbid) DO UPDATE SET '
      'note = excluded.note, updated_at = excluded.updated_at',
      [albumMbid, note, DateTime.now().millisecondsSinceEpoch],
    );
  }

  void deleteAlbumNote(String albumMbid) {
    database.db
        .execute('DELETE FROM album_notes WHERE album_mbid = ?', [albumMbid]);
  }

  Map<String, String> trackNotes(String albumMbid) {
    final rows = database.db.select(
      'SELECT track_key, note FROM track_notes WHERE album_mbid = ?',
      [albumMbid],
    );
    return {
      for (final row in rows) row['track_key'] as String: row['note'] as String,
    };
  }

  void setTrackNote(String albumMbid, String trackKey, String note) {
    if (note.trim().isEmpty) {
      deleteTrackNote(albumMbid, trackKey);
      return;
    }
    database.db.execute(
      'INSERT INTO track_notes (album_mbid, track_key, note, updated_at) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(album_mbid, track_key) DO UPDATE SET '
      'note = excluded.note, updated_at = excluded.updated_at',
      [albumMbid, trackKey, note, DateTime.now().millisecondsSinceEpoch],
    );
  }

  void deleteTrackNote(String albumMbid, String trackKey) {
    database.db.execute(
      'DELETE FROM track_notes WHERE album_mbid = ? AND track_key = ?',
      [albumMbid, trackKey],
    );
  }

  /// Every album with an album-level comment, a track-level comment, or
  /// both — one query, used by the Rated Albums screen to show a comment
  /// indicator without a per-row lookup.
  Set<String> albumMbidsWithAnyNote() {
    final rows = database.db.select(
      'SELECT album_mbid FROM album_notes '
      'UNION SELECT album_mbid FROM track_notes',
    );
    return rows.map((row) => row['album_mbid'] as String).toSet();
  }
}
