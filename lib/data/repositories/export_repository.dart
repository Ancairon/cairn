import 'dart:convert';
import 'rating_repository.dart';
import 'album_repository.dart';
import 'recommendation_repository.dart';
import 'saved_filter_repository.dart';
import 'settings_repository.dart';

class ExportRepository {
  final RatingRepository ratings;
  final AlbumRepository albums;
  final RecommendationRepository recommendations;
  final SavedFilterRepository savedFilters;
  final SettingsRepository settings;

  ExportRepository(this.ratings, this.albums, this.recommendations,
      this.savedFilters, this.settings);

  /// A single object (ratings + liked genres + saved filters + a portable
  /// subset of settings), not just a bare ratings list — see
  /// architecture.md's "Ratings export and import" section for the full
  /// shape and why device-specific settings (backup folder, auto-backup
  /// consent, last-checked timestamps) are deliberately excluded. `toCsv()`
  /// stays ratings-only — it isn't wired to any UI action, and cramming
  /// non-tabular data into a flat CSV would need awkward encoding tricks
  /// for a format nothing currently produces.
  Future<String> toJson() async {
    final rows = <Map<String, dynamic>>[];
    for (final rating in ratings.allRatings()) {
      final album = await albums.getOrFetch(rating.albumMbid);
      rows.add({
        'mbid': album.mbid,
        'title': album.title,
        'artist': album.artistName,
        'year': album.firstReleaseYear,
        'genres': album.genres,
        'stars': rating.stars,
        'rated_at': rating.ratedAt.toIso8601String(),
        'notes': rating.notes,
        'owns_cd': album.ownsCd,
        'owns_vinyl': album.ownsVinyl,
      });
    }
    return jsonEncode({
      'ratings': rows,
      'liked_genres': recommendations.likedGenres(),
      'saved_filters': savedFilters
          .all()
          .map((filter) => {
                'name': filter.name,
                'ownership': filter.criteria.ownership,
                'min_rating': filter.criteria.minRating,
                'max_rating': filter.criteria.maxRating,
              })
          .toList(),
      'settings': {
        'default_opened_menu_item': settings.defaultOpenedMenuItem(),
        'default_player_app': settings.defaultPlayerApp(),
        'rated_albums_sort': settings.ratedAlbumsSort(),
        'rated_albums_view': settings.ratedAlbumsView(),
        'rated_albums_size': settings.ratedAlbumsSize(),
      },
    });
  }

  Future<String> toCsv() async {
    final buffer = StringBuffer(
        'mbid,title,artist,year,genres,stars,rated_at,notes,owns_cd,owns_vinyl\n');
    for (final rating in ratings.allRatings()) {
      final album = await albums.getOrFetch(rating.albumMbid);
      buffer.writeln([
        _csvField(album.mbid),
        _csvField(album.title),
        _csvField(album.artistName),
        album.firstReleaseYear?.toString() ?? '',
        _csvField(album.genres.join('; ')),
        rating.stars.toString(),
        rating.ratedAt.toIso8601String(),
        _csvField(rating.notes ?? ''),
        album.ownsCd.toString(),
        album.ownsVinyl.toString(),
      ].join(','));
    }
    return buffer.toString();
  }

  String _csvField(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
