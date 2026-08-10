import 'dart:convert';
import '../../core/db/app_database.dart';
import '../models/album.dart';
import '../models/rating.dart';
import '../models/saved_filter.dart';

class RatingRepository {
  final AppDatabase database;

  RatingRepository(this.database);

  void rate(String albumMbid, int stars, {String? notes}) {
    database.db.execute(
      'INSERT INTO ratings (album_mbid, stars, rated_at, notes) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(album_mbid) DO UPDATE SET '
      'stars = excluded.stars, rated_at = excluded.rated_at, notes = excluded.notes',
      [albumMbid, stars, DateTime.now().millisecondsSinceEpoch, notes],
    );
  }

  /// Deletes the current rating for an album, if any. Used by the Rated
  /// Albums screen's swipe-to-remove action.
  void deleteRating(String albumMbid) {
    database.db.execute('DELETE FROM ratings WHERE album_mbid = ?', [albumMbid]);
  }

  List<Rating> allRatings() {
    final rows = database.db.select('SELECT * FROM ratings ORDER BY rated_at DESC');
    return rows
        .map((row) => Rating(
              albumMbid: row['album_mbid'] as String,
              stars: row['stars'] as int,
              ratedAt: DateTime.fromMillisecondsSinceEpoch(row['rated_at'] as int),
              notes: row['notes'] as String?,
            ))
        .toList();
  }

  /// Rated albums (joined with their album row), newest-rated first,
  /// narrowed by [criteria] when given — used by the Rated Albums screen
  /// and its saved filters.
  List<(Album, Rating)> ratedAlbumsMatching([FilterCriteria? criteria]) {
    final (whereSql, whereParams) = (criteria ?? const FilterCriteria()).toSqlWhere();
    final rows = database.db.select(
      'SELECT albums.*, ratings.stars, ratings.rated_at, ratings.notes '
      'FROM ratings JOIN albums ON albums.mbid = ratings.album_mbid '
      'WHERE $whereSql '
      'ORDER BY ratings.rated_at DESC',
      whereParams,
    );
    return rows.map((row) {
      final genresJson = row['genres'] as String?;
      final album = Album(
        mbid: row['mbid'] as String,
        representativeReleaseMbid: row['representative_release_mbid'] as String?,
        title: row['title'] as String,
        artistName: row['artist_name'] as String,
        artistMbid: row['artist_mbid'] as String?,
        firstReleaseYear: row['first_release_year'] as int?,
        genres: genresJson != null ? (jsonDecode(genresJson) as List).cast<String>() : const [],
        coverArtUrl: row['cover_art_url'] as String?,
        ownsCd: (row['owns_cd'] as int) != 0,
        ownsVinyl: (row['owns_vinyl'] as int) != 0,
      );
      final rating = Rating(
        albumMbid: album.mbid,
        stars: row['stars'] as int,
        ratedAt: DateTime.fromMillisecondsSinceEpoch(row['rated_at'] as int),
        notes: row['notes'] as String?,
      );
      return (album, rating);
    }).toList();
  }
}
