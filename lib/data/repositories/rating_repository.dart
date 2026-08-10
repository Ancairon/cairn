import '../../core/db/app_database.dart';
import '../models/rating.dart';

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
}
