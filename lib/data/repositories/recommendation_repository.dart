import 'dart:async';
import 'dart:convert';
import 'dart:math';
import '../../core/db/app_database.dart';
import '../../core/network/artwork_cache.dart';
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

  // Session-only display history. Unlike ratings and skips, this is not
  // persisted: reopening the app starts a fresh recommendation session.
  final Set<String> _sessionShown = {};

  // Session-only preference. It deliberately is not persisted: a vibe lock
  // constrains this discovery run, not the user's long-term taste profile.
  String? _sessionVibeGenre;

  final Map<String, Future<Album?>> _prefetchedBranches = {};

  final _random = Random();

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
      return await _takePrefetched('high') ?? _nextFromSeed(ratedAlbum);
    }
    if (stars == 3) {
      return await _takePrefetched('neutral') ??
          _nextFromCurrentAnchorOrPivot();
    }
    return await _takePrefetched('low') ??
        _pivotForSessionVibeOrPivot(); // 1-2 stars: pivot immediately, no streak-counting.
  }

  /// The very first recommendation, or resuming with no rating just made.
  Future<Album> next() => _nextFromCurrentAnchorOrPivot();

  /// Returns the album shown when the previous app session ended, if it is
  /// still available in the local album cache.
  Future<Album?> restoreLastShown() async {
    final rows = database.db.select(
      'SELECT last_shown_album_mbid FROM app_state WHERE id = 0',
    );
    if (rows.isEmpty) return null;
    final mbid = rows.first['last_shown_album_mbid'] as String?;
    if (mbid == null) return null;
    return albums.getOrFetch(mbid);
  }

  void saveLastShown(String mbid) {
    database.db.execute(
      'INSERT INTO app_state (id, last_shown_album_mbid) VALUES (0, ?) '
      'ON CONFLICT(id) DO UPDATE SET last_shown_album_mbid = excluded.last_shown_album_mbid',
      [mbid],
    );
  }

  /// "Skip" — not a rating. Keeps the current anchor untouched and never
  /// pivots; just marks [mbid] excluded for the rest of this session so the
  /// same album doesn't loop straight back. When at least one 4-5★ rating
  /// exists, reseeds from a random one of those instead of using the skipped
  /// album as a recommendation seed (a one-off seed, not persisted as the
  /// new anchor); falls back to the existing pivot behavior if there are
  /// zero 4-5★ ratings.
  Future<Album> skip(String mbid) async {
    _sessionSkipped.add(mbid);
    final prefetched = await _takePrefetched('skip');
    if (prefetched != null) return prefetched;
    final fallbackSeedMbid = _pickFallbackSeed();
    if (fallbackSeedMbid != null) {
      final seedAlbum = await albums.getOrFetch(fallbackSeedMbid);
      return _nextFromSeed(seedAlbum);
    }
    return _pivotForSessionVibeOrPivot();
  }

  /// Explicit button skip: persist the skip count before advancing. Artwork
  /// swipes call [skip] directly and never reach this method.
  Future<Album> skipButton(String mbid) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    database.db.execute(
      'INSERT INTO album_skip_penalties (album_mbid, skip_count, last_skipped_at) '
      'VALUES (?, 1, ?) ON CONFLICT(album_mbid) DO UPDATE SET '
      'skip_count = album_skip_penalties.skip_count + 1, '
      'last_skipped_at = excluded.last_skipped_at',
      [mbid, now],
    );
    return skip(mbid);
  }

  void resetSkipPenalties() {
    database.db.execute('DELETE FROM album_skip_penalties');
  }

  /// Advances from a rated album using that album as the recommendation seed.
  /// This is distinct from a generic skip, which intentionally reseeds from
  /// a random highly-rated album to avoid turning a skip into a rating signal.
  Future<Album> nextRelated(Album album) async {
    return await _takePrefetched('high') ?? _nextFromSeed(album);
  }

  /// Starts four independent recommendation branches in the background so a
  /// later rating/skip can consume an already-fetched album and its artwork.
  void prefetchBranches(Album current) {
    _prefetchedBranches['high'] = _prefetchSafe(
        () => _nextFromSeed(current, recordPivot: false));
    _prefetchedBranches['neutral'] = _prefetchSafe(
        () => _nextFromCurrentAnchorOrPivot(recordPivot: false));
    _prefetchedBranches['low'] = _prefetchSafe(
        () => _pivotForSessionVibeOrPivot(recordPivot: false));
    _prefetchedBranches['skip'] = _prefetchSafe(_prefetchSkipBranch);
  }

  Future<Album?> _takePrefetched(String branch) async {
    final pending = _prefetchedBranches.remove(branch);
    if (pending == null) return null;
    final album = await pending;
    if (album == null || _excludedMbids().contains(album.mbid)) return null;
    return album;
  }

  Future<Album?> _prefetchSafe(Future<Album> Function() load) async {
    try {
      final album = await load();
      final large = album.coverArtUrl;
      if (large != null) {
        await ArtworkCache.prefetch(large);
        await ArtworkCache.prefetch(
            large.replaceFirst('front-500', 'front-250'));
      }
      unawaited(ArtworkCache.collect());
      return album;
    } catch (_) {
      return null;
    }
  }

  Future<Album> _prefetchSkipBranch() async {
    final rated = ratings.allRatings()
        .where((rating) => rating.stars >= 4)
        .toList();
    if (rated.isNotEmpty) {
      final seed = await albums.getOrFetch(rated.first.albumMbid);
      return _nextFromSeed(seed, recordPivot: false);
    }
    return _pivotForSessionVibeOrPivot(recordPivot: false);
  }

  /// "Start New Queue From Here" — journal action on a highly-rated album,
  /// or picking a specific album via search to jump straight into the loop.
  /// Displays [album] itself next (so search results and journal picks show
  /// exactly what was picked, not a derived recommendation), while setting
  /// it as the new anchor so subsequent recommendations build off of it.
  Future<Album> restartFrom(Album album) async {
    _setAnchor(album.mbid);
    return album;
  }

  List<String> likedGenres() {
    final rows =
        database.db.select('SELECT liked_genres FROM app_state WHERE id = 0');
    if (rows.isEmpty || rows.first['liked_genres'] == null) return [];
    return (jsonDecode(rows.first['liked_genres'] as String) as List)
        .cast<String>();
  }

  /// A fresh install has no taste input or resumable discovery state. Keep
  /// this check local and synchronous so the UI can choose onboarding before
  /// starting a network recommendation request.
  bool needsOnboarding() {
    final state = database.db.select(
      'SELECT current_anchor_mbid, last_shown_album_mbid, liked_genres '
      'FROM app_state WHERE id = 0',
    );
    if (state.isNotEmpty) {
      final row = state.first;
      if (row['current_anchor_mbid'] != null ||
          row['last_shown_album_mbid'] != null ||
          row['liked_genres'] != null) {
        return false;
      }
    }
    final ratingsRows = database.db.select('SELECT 1 FROM ratings LIMIT 1');
    return ratingsRows.isEmpty;
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

  String? get sessionVibeGenre => _sessionVibeGenre;

  void setSessionVibeGenre(String genre) {
    final normalized = genre.trim().toLowerCase();
    _sessionVibeGenre = normalized.isEmpty ? null : normalized;
  }

  void clearSessionVibeGenre() => _sessionVibeGenre = null;

  /// Records an album that has actually been displayed in this app session.
  /// Keeping this separate from ratings/skips preserves their existing
  /// semantics while preventing a recommendation loop within one session.
  void markShown(String mbid) {
    final normalized = mbid.trim();
    if (normalized.isNotEmpty) _sessionShown.add(normalized);
  }

  Future<Album> _nextFromCurrentAnchorOrPivot({bool recordPivot = true}) async {
    final anchorMbid = _currentAnchor();
    if (anchorMbid == null) {
      return _pivotForSessionVibeOrPivot(recordPivot: recordPivot);
    }
    final anchorAlbum = await albums.getOrFetch(anchorMbid);
    return _nextFromSeed(anchorAlbum, recordPivot: recordPivot);
  }

  Future<Album> _nextFromSeed(Album seed, {bool recordPivot = true}) async {
    if (seed.artistMbid == null) {
      return _pivotForSessionVibeOrPivot(recordPivot: recordPivot);
    }

    final similarArtistMbids =
        await listenBrainz.similarArtists(seed.artistMbid!);
    final candidates = <Map<String, dynamic>>[];
    for (final artistMbid in similarArtistMbids.take(1)) {
      candidates
          .addAll(await musicBrainz.browseReleaseGroupsByArtist(artistMbid));
    }

    final vibe = _sessionVibeGenre;
    if (vibe != null) {
      candidates
          .removeWhere((candidate) => !_candidateHasGenre(candidate, vibe));
    }
    final excluded = _excludedMbids();
    final best = pickBestCandidate(candidates,
        seedGenres: seed.genres,
        excludeMbids: excluded,
        skipPenalties: _effectiveSkipPenalties());
    if (best == null) {
      return _pivotForSessionVibeOrPivot(recordPivot: recordPivot);
    }

    return albums.getOrFetch(best);
  }

  Future<Album> _pivot({bool recordPivot = true}) async {
    final pool =
        likedGenres().isNotEmpty ? likedGenres() : _fallbackPivotGenres;

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
      if (recordPivot) _recordPivotBucket(genre);

      final results = await musicBrainz.searchReleaseGroupsByTag(genre);
      if (results.isEmpty) continue;

      final excluded = _excludedMbids();
      final unrated = results
          .map((r) => r['id'] as String)
          .where((mbid) => !excluded.contains(mbid));
      final unratedList = unrated.toList();
      if (unratedList.isEmpty) continue;
      final preferred = unratedList
          .where((mbid) => !_isPenalized(mbid))
          .toList();
      return albums.getOrFetch(
          (preferred.isNotEmpty ? preferred : unratedList).first);
    }

    throw StateError('No results for any genre in the pivot pool: $pool');
  }

  Future<Album> _pivotForSessionVibeOrPivot({bool recordPivot = true}) {
    final vibe = _sessionVibeGenre;
    return vibe == null
        ? _pivot(recordPivot: recordPivot)
        : _pivotForGenre(vibe, recordPivot: recordPivot);
  }

  Future<Album> _pivotForGenre(String genre, {bool recordPivot = true}) async {
    final results = await musicBrainz.searchReleaseGroupsByTag(genre);
    final excluded = _excludedMbids();
    final unrated = results
        .map((result) => result['id'] as String?)
        .whereType<String>()
        .where((mbid) => !excluded.contains(mbid));
    final unratedList = unrated.toList();
    final preferred = unratedList.where((mbid) => !_isPenalized(mbid)).toList();
    final pick = (preferred.isNotEmpty ? preferred : unratedList).firstOrNull;
    if (pick == null) {
      throw StateError('No available recommendations for vibe: $genre');
    }
    return albums.getOrFetch(pick);
  }

  bool _candidateHasGenre(Map<String, dynamic> candidate, String genre) {
    final genres = ((candidate['genres'] as List?) ?? [])
        .whereType<Map<String, dynamic>>()
        .map((entry) => (entry['name'] as String?)?.toLowerCase())
        .whereType<String>();
    return genres.any((candidateGenre) => candidateGenre == genre);
  }

  Map<String, int> _effectiveSkipPenalties() {
    final rows = database.db.select(
        'SELECT album_mbid, skip_count, last_skipped_at FROM album_skip_penalties');
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      for (final row in rows)
        row['album_mbid'] as String: _decayedSkipCount(
            row['skip_count'] as int, now - (row['last_skipped_at'] as int))
    };
  }

  bool _isPenalized(String mbid) =>
      (_effectiveSkipPenalties()[mbid] ?? 0) >= 5;

  int _decayedSkipCount(int count, int ageMs) {
    final periods = ageMs ~/ const Duration(days: 7).inMilliseconds;
    return (count - periods).clamp(0, count);
  }

  // Rated albums, this session's skips, and already-displayed albums are all
  // excluded from candidates. Only ratings are persisted; the other two sets
  // live for the current process only.
  Set<String> _excludedMbids() =>
      ratings.allRatings().map((r) => r.albumMbid).toSet()
        ..addAll(_sessionSkipped)
        ..addAll(_sessionShown);

  String? _currentAnchor() {
    final rows = database.db
        .select('SELECT current_anchor_mbid FROM app_state WHERE id = 0');
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
    final rows = database.db
        .select('SELECT recent_pivot_buckets FROM app_state WHERE id = 0');
    if (rows.isEmpty || rows.first['recent_pivot_buckets'] == null) return [];
    return (jsonDecode(rows.first['recent_pivot_buckets'] as String) as List)
        .cast<String>();
  }

  void _recordPivotBucket(String bucket) {
    final updated = [..._recentPivotBuckets(), bucket];
    final capped =
        updated.length > 5 ? updated.sublist(updated.length - 5) : updated;
    database.db.execute(
      'INSERT INTO app_state (id, recent_pivot_buckets) VALUES (0, ?) '
      'ON CONFLICT(id) DO UPDATE SET recent_pivot_buckets = excluded.recent_pivot_buckets',
      [jsonEncode(capped)],
    );
  }

  List<String> _recentFallbackSeeds() {
    final rows = database.db.select(
        'SELECT recent_fallback_seed_mbids FROM app_state WHERE id = 0');
    if (rows.isEmpty || rows.first['recent_fallback_seed_mbids'] == null) {
      return [];
    }
    return (jsonDecode(rows.first['recent_fallback_seed_mbids'] as String)
            as List)
        .cast<String>();
  }

  void _recordFallbackSeed(String mbid) {
    final updated = [..._recentFallbackSeeds(), mbid];
    final capped =
        updated.length > 5 ? updated.sublist(updated.length - 5) : updated;
    database.db.execute(
      'INSERT INTO app_state (id, recent_fallback_seed_mbids) VALUES (0, ?) '
      'ON CONFLICT(id) DO UPDATE SET recent_fallback_seed_mbids = excluded.recent_fallback_seed_mbids',
      [jsonEncode(capped)],
    );
  }

  // Skip's no-anchor reseed source: a uniformly-random 4-5★ rated album,
  // excluding this session's recently-used fallback seeds so consecutive
  // skips don't immediately repeat. Never sets the anchor — see skip()'s
  // doc comment.
  String? _pickFallbackSeed() {
    final rated = ratings
        .allRatings()
        .where((r) => r.stars >= 4)
        .map((r) => r.albumMbid)
        .toList();
    final pick = pickRandomExcludingRecent(
      rated,
      recentlyUsed: _recentFallbackSeeds().toSet(),
      nextInt: _random.nextInt,
    );
    if (pick != null) _recordFallbackSeed(pick);
    return pick;
  }
}

/// Pure scoring function — no DB, no network. Picks the release-group mbid
/// with the highest genre overlap against [seedGenres], skipping anything in
/// [excludeMbids] (already-rated albums) and non-studio-album release types.
String? pickBestCandidate(
  List<Map<String, dynamic>> candidates, {
  required List<String> seedGenres,
  required Set<String> excludeMbids,
  Map<String, int> skipPenalties = const {},
}) {
  final seedSet = seedGenres.map((g) => g.toLowerCase()).toSet();
  Map<String, dynamic>? best;
  var bestScore = -1;

  for (final candidate in candidates) {
    final mbid = candidate['id'] as String?;
    if (mbid == null || excludeMbids.contains(mbid)) continue;

    final primaryType = candidate['primary-type'] as String?;
    if (primaryType != null && primaryType != 'Album') continue;
    final secondaryTypes =
        ((candidate['secondary-types'] as List?) ?? []).cast<String>();
    if (secondaryTypes.isNotEmpty) {
      continue; // skip Live/Compilation/Soundtrack etc.
    }

    final genres = ((candidate['genres'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .map((g) => (g['name'] as String).toLowerCase())
        .toSet();
    final overlap = genres.intersection(seedSet).length;
    final score = overlap -
        ((skipPenalties[mbid] ?? 0) >= 5 ? 2 : 0);

    if (score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }

  return best?['id'] as String?;
}

/// Pure selection helper — no DB, no network. Picks a uniformly-random value
/// from [candidates], preferring ones not in [recentlyUsed] so consecutive
/// picks don't immediately repeat; falls back to the full candidate list if
/// every candidate has been recently used. [nextInt] is injected for
/// testability (pass a fixed function in tests instead of Random.nextInt).
String? pickRandomExcludingRecent(
  List<String> candidates, {
  required Set<String> recentlyUsed,
  required int Function(int max) nextInt,
}) {
  if (candidates.isEmpty) return null;
  final eligible = candidates.where((c) => !recentlyUsed.contains(c)).toList();
  final pool = eligible.isNotEmpty ? eligible : candidates;
  return pool[nextInt(pool.length)];
}
