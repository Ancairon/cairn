import 'dart:convert';
import '../../core/db/app_database.dart';
import '../models/album.dart';
import '../remote/musicbrainz_client.dart';
import '../remote/listenbrainz_client.dart';
import 'album_repository.dart';
import 'rating_repository.dart';

// Fresh, not-yet-tried decade/genre buckets to pivot into when there's no
// anchor yet, or the last rating was a dislike. Deliberately small and
// hand-picked rather than derived from a genre taxonomy — good enough to
// escape a bad run; retune once real usage shows it's too narrow.
const pivotBuckets = [
  {'genre': 'jazz', 'decade': 1960},
  {'genre': 'ambient', 'decade': 1990},
  {'genre': 'hip hop', 'decade': 1990},
  {'genre': 'post-punk', 'decade': 1980},
  {'genre': 'shoegaze', 'decade': 1990},
  {'genre': 'folk', 'decade': 1970},
  {'genre': 'techno', 'decade': 2000},
  {'genre': 'soul', 'decade': 1970},
];

/// One global "anchor" album drives every recommendation — no branch trees,
/// no per-thread lineage state. See .agents/sow/specs/architecture.md.
class RecommendationRepository {
  final AppDatabase database;
  final MusicBrainzClient musicBrainz;
  final ListenBrainzClient listenBrainz;
  final AlbumRepository albums;
  final RatingRepository ratings;

  RecommendationRepository(
    this.database,
    this.musicBrainz,
    this.listenBrainz,
    this.albums,
    this.ratings,
  );

  /// Called after a rating is submitted. Updates the anchor per the rules in
  /// the spec, then returns the next album to recommend.
  Future<Album> onRated(Album ratedAlbum, int stars) async {
    if (stars >= 4) {
      _setAnchor(ratedAlbum.mbid);
      return _nextFromSeed(ratedAlbum);
    }
    if (stars == 3) {
      return _nextFromCurrentAnchorOrPivot();
    }
    return _pivot(); // 1-2 stars: pivot immediately, no streak-counting.
  }

  /// The very first recommendation, or resuming with no rating just made.
  Future<Album> next() => _nextFromCurrentAnchorOrPivot();

  /// "Start New Queue From Here" — journal action on a highly-rated album.
  Future<Album> restartFrom(Album album) async {
    _setAnchor(album.mbid);
    return _nextFromSeed(album);
  }

  Future<Album> _nextFromCurrentAnchorOrPivot() async {
    final anchorMbid = _currentAnchor();
    if (anchorMbid == null) return _pivot();
    final anchorAlbum = await albums.getOrFetch(anchorMbid);
    return _nextFromSeed(anchorAlbum);
  }

  Future<Album> _nextFromSeed(Album seed) async {
    if (seed.artistMbid == null) return _pivot();

    final similarArtistMbids = await listenBrainz.similarArtists(seed.artistMbid!);
    final candidates = <Map<String, dynamic>>[];
    for (final artistMbid in similarArtistMbids.take(5)) {
      candidates.addAll(await musicBrainz.browseReleaseGroupsByArtist(artistMbid));
    }

    final excluded = _ratedMbids();
    final best = pickBestCandidate(candidates, seedGenres: seed.genres, excludeMbids: excluded);
    if (best == null) return _pivot();

    return albums.getOrFetch(best);
  }

  Future<Album> _pivot() async {
    final tried = _recentPivotBuckets();
    final bucket = pivotBuckets.firstWhere(
      (b) => !tried.contains(_bucketKey(b)),
      orElse: () => pivotBuckets[tried.length % pivotBuckets.length],
    );
    _recordPivotBucket(_bucketKey(bucket));

    final query = await musicBrainz.searchReleaseGroup('', bucket['genre'] as String);
    final results = ((query['release-groups'] as List?) ?? []).cast<Map<String, dynamic>>();
    final excluded = _ratedMbids();
    final unrated = results.map((r) => r['id'] as String).where((mbid) => !excluded.contains(mbid));
    final pick = unrated.isNotEmpty ? unrated.first : (results.first['id'] as String);
    return albums.getOrFetch(pick);
  }

  Set<String> _ratedMbids() => ratings.allRatings().map((r) => r.albumMbid).toSet();

  String _bucketKey(Map<String, dynamic> bucket) => '${bucket['genre']}-${bucket['decade']}';

  String? _currentAnchor() {
    final rows = database.db.select('SELECT current_anchor_mbid FROM app_state WHERE id = 0');
    return rows.isEmpty ? null : rows.first['current_anchor_mbid'] as String?;
  }

  void _setAnchor(String mbid) {
    database.db.execute(
      'INSERT INTO app_state (id, current_anchor_mbid) VALUES (0, ?) '
      'ON CONFLICT(id) DO UPDATE SET current_anchor_mbid = excluded.current_anchor_mbid',
      [mbid],
    );
  }

  List<String> _recentPivotBuckets() {
    final rows = database.db.select('SELECT recent_pivot_buckets FROM app_state WHERE id = 0');
    if (rows.isEmpty || rows.first['recent_pivot_buckets'] == null) return [];
    return (jsonDecode(rows.first['recent_pivot_buckets'] as String) as List).cast<String>();
  }

  void _recordPivotBucket(String bucket) {
    final updated = [..._recentPivotBuckets(), bucket];
    final capped = updated.length > 5 ? updated.sublist(updated.length - 5) : updated;
    database.db.execute(
      'INSERT INTO app_state (id, recent_pivot_buckets) VALUES (0, ?) '
      'ON CONFLICT(id) DO UPDATE SET recent_pivot_buckets = excluded.recent_pivot_buckets',
      [jsonEncode(capped)],
    );
  }
}

/// Pure scoring function — no DB, no network. Picks the release-group mbid
/// with the highest genre overlap against [seedGenres], skipping anything in
/// [excludeMbids] (already-rated albums) and non-studio-album release types.
String? pickBestCandidate(
  List<Map<String, dynamic>> candidates, {
  required List<String> seedGenres,
  required Set<String> excludeMbids,
}) {
  final seedSet = seedGenres.map((g) => g.toLowerCase()).toSet();
  Map<String, dynamic>? best;
  var bestScore = -1;

  for (final candidate in candidates) {
    final mbid = candidate['id'] as String?;
    if (mbid == null || excludeMbids.contains(mbid)) continue;

    final primaryType = candidate['primary-type'] as String?;
    if (primaryType != null && primaryType != 'Album') continue;
    final secondaryTypes = ((candidate['secondary-types'] as List?) ?? []).cast<String>();
    if (secondaryTypes.isNotEmpty) continue; // skip Live/Compilation/Soundtrack etc.

    final genres = ((candidate['genres'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .map((g) => (g['name'] as String).toLowerCase())
        .toSet();
    final score = genres.intersection(seedSet).length;

    if (score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }

  return best?['id'] as String?;
}
