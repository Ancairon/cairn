import 'dart:convert';
import '../../core/db/app_database.dart';
import '../models/album.dart';
import '../remote/musicbrainz_client.dart';
import '../remote/listenbrainz_client.dart';
import 'album_repository.dart';
import 'rating_repository.dart';

// Fallback pivot genres, used only until the user has picked liked genres
// via onboarding — once lib/data/genre_pool.dart selections are saved, those
// take over entirely. Deliberately small; good enough to escape a bad run
// before onboarding exists.
const _fallbackPivotGenres = [
  'jazz',
  'ambient',
  'hip hop',
  'post-punk',
  'shoegaze',
  'folk',
  'techno',
  'soul',
];

/// One global "anchor" album drives every recommendation — no branch trees,
/// no per-thread lineage state. See .agents/sow/specs/architecture.md.
class RecommendationRepository {
  final AppDatabase database;
  final MusicBrainzClient musicBrainz;
  final ListenBrainzClient listenBrainz;
  final AlbumRepository albums;
  final RatingRepository ratings;

  // Session-only escape valve: "not right now" rather than a dislike. Never
  // persisted (no schema change) — resets on every app restart — and never
  // touches the anchor or pivot logic below, unlike a real 1-2/4-5 rating.
  final Set<String> _sessionSkipped = {};

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

  /// "Skip" — not a rating. Keeps the current anchor untouched and never
  /// pivots; just marks [mbid] excluded for the rest of this session so the
  /// same album doesn't loop straight back, then continues from wherever
  /// `next()` would have gone anyway.
  Future<Album> skip(String mbid) {
    _sessionSkipped.add(mbid);
    return _nextFromCurrentAnchorOrPivot();
  }

  /// "Start New Queue From Here" — journal action on a highly-rated album,
  /// or picking a specific album via search to jump straight into the loop.
  Future<Album> restartFrom(Album album) async {
    _setAnchor(album.mbid);
    return _nextFromSeed(album);
  }

  List<String> likedGenres() {
    final rows = database.db.select('SELECT liked_genres FROM app_state WHERE id = 0');
    if (rows.isEmpty || rows.first['liked_genres'] == null) return [];
    return (jsonDecode(rows.first['liked_genres'] as String) as List).cast<String>();
  }

  /// Onboarding action — replaces the cold-start/pivot genre pool with the
  /// user's own picks. Does not affect anchor-based branching (see
  /// specs/architecture.md: genres influence cold-start/pivots only).
  void setLikedGenres(List<String> genres) {
    database.db.execute(
      'INSERT INTO app_state (id, liked_genres) VALUES (0, ?) '
      'ON CONFLICT(id) DO UPDATE SET liked_genres = excluded.liked_genres',
      [jsonEncode(genres)],
    );
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

    final excluded = _excludedMbids();
    final best = pickBestCandidate(candidates, seedGenres: seed.genres, excludeMbids: excluded);
    if (best == null) return _pivot();

    return albums.getOrFetch(best);
  }

  Future<Album> _pivot() async {
    final pool = likedGenres().isNotEmpty ? likedGenres() : _fallbackPivotGenres;

    // Bounded by pool.length: if every genre in the pool comes back with
    // nothing tagged (unlikely, but possible for an unusual hand-typed
    // onboarding pick), give up on pivoting and fall through rather than
    // recursing forever.
    for (var attempt = 0; attempt < pool.length; attempt++) {
      final tried = _recentPivotBuckets();
      final genre = pool.firstWhere(
        (g) => !tried.contains(g),
        orElse: () => pool[tried.length % pool.length],
      );
      _recordPivotBucket(genre);

      final results = await musicBrainz.searchReleaseGroupsByTag(genre);
      if (results.isEmpty) continue;

      final excluded = _excludedMbids();
      final unrated = results.map((r) => r['id'] as String).where((mbid) => !excluded.contains(mbid));
      final pick = unrated.isNotEmpty ? unrated.first : (results.first['id'] as String);
      return albums.getOrFetch(pick);
    }

    throw StateError('No results for any genre in the pivot pool: $pool');
  }

  // Rated albums plus this session's skips — both excluded from candidates,
  // but only ratings are persisted; skips live only in [_sessionSkipped].
  Set<String> _excludedMbids() =>
      ratings.allRatings().map((r) => r.albumMbid).toSet()..addAll(_sessionSkipped);

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
