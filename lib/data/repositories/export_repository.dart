import 'dart:convert';
import 'rating_repository.dart';
import 'album_repository.dart';

class ExportRepository {
  final RatingRepository ratings;
  final AlbumRepository albums;

  ExportRepository(this.ratings, this.albums);

  Future<String> toJson() async {
    final rows = <Map<String, dynamic>>[];
    for (final rating in ratings.allRatings()) {
      final album = await albums.getOrFetch(rating.albumMbid);
      rows.add({
        'title': album.title,
        'artist': album.artistName,
        'year': album.firstReleaseYear,
        'genres': album.genres,
        'stars': rating.stars,
        'rated_at': rating.ratedAt.toIso8601String(),
        'notes': rating.notes,
      });
    }
    return jsonEncode(rows);
  }

  Future<String> toCsv() async {
    final buffer = StringBuffer('title,artist,year,genres,stars,rated_at,notes\n');
    for (final rating in ratings.allRatings()) {
      final album = await albums.getOrFetch(rating.albumMbid);
      buffer.writeln([
        _csvField(album.title),
        _csvField(album.artistName),
        album.firstReleaseYear?.toString() ?? '',
        _csvField(album.genres.join('; ')),
        rating.stars.toString(),
        rating.ratedAt.toIso8601String(),
        _csvField(rating.notes ?? ''),
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
