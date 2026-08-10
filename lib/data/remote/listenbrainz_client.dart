import '../../core/network/http_client.dart';
import '../../core/network/response_cache.dart';

// The Labs API's exact algorithm identifier is an internal, versioned string
// that can change between MetaBrainz deployments. If similarArtists() starts
// returning empty for artists that should have data, check
// https://labs.api.listenbrainz.org/similar-artists for the current value.
const _algorithm =
    'session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30';

/// ListenBrainz Labs — similar-artists, computed from real listening-session
/// data rather than tag overlap. Public, no auth required.
class ListenBrainzClient {
  final ApiHttpClient http;
  final ResponseCache cache;

  ListenBrainzClient(this.http, this.cache);

  /// Returns similar artist MBIDs ranked by relevance. Empty if the seed
  /// artist has no data in ListenBrainz's dataset (common for obscure
  /// artists) — callers should treat that as "no signal, pivot" rather than
  /// an error.
  Future<List<String>> similarArtists(String artistMbid) async {
    final key = 'lb:similar-artists:$artistMbid';
    final cached = cache.get(key);
    if (cached != null) return (cached['mbids'] as List).cast<String>();

    try {
      final url = Uri.parse('https://labs.api.listenbrainz.org/similar-artists/json').replace(
        queryParameters: {'artist_mbids': artistMbid, 'algorithm': _algorithm},
      );
      final raw = await http.getRaw(url);
      final mbids = _extractSimilarArtistMbids(raw, excluding: artistMbid);
      cache.put(key, {'mbids': mbids}, ttlSeconds: 60 * 60 * 24 * 30);
      return mbids;
    } on HttpException {
      cache.put(key, {'mbids': <String>[]}, ttlSeconds: 60 * 60 * 24 * 7);
      return [];
    }
  }
}

/// The Labs API is a loosely-documented experimental endpoint, so this
/// defensively accepts either a top-level list of entries or a map of them —
/// verify against a real call during Milestone 1's manual CLI session and
/// adjust here if the live shape differs.
List<String> _extractSimilarArtistMbids(dynamic raw, {required String excluding}) {
  final entries = raw is List
      ? raw
      : raw is Map
          ? raw.values.whereType<List>().expand((v) => v).toList()
          : const [];

  return entries
      .whereType<Map>()
      .map((entry) => (entry['artist_mbid'] ?? entry['similar_artist_mbid']) as String?)
      .whereType<String>()
      .where((mbid) => mbid != excluding)
      .toSet()
      .toList();
}
