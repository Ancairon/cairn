import '../../core/network/http_client.dart';
import '../../core/network/rate_limiter.dart';
import '../../core/network/response_cache.dart';

const _baseUrl = 'https://musicbrainz.org/ws/2';

/// MusicBrainz API — identity, genres, and external streaming links.
/// Public, no auth. Must stay at or under 1 request/second.
class MusicBrainzClient {
  final ApiHttpClient http;
  final ResponseCache cache;
  final RateLimiter _rateLimiter = RateLimiter(const Duration(seconds: 1));

  MusicBrainzClient(this.http, this.cache);

  /// Release-groups community-tagged with [genre] — used to seed cold-start
  /// and pivot recommendations from a genre rather than a specific artist.
  Future<List<Map<String, dynamic>>> searchReleaseGroupsByTag(String genre,
      {int limit = 25}) async {
    final key = 'mb:search-tag:$genre';
    final cached = cache.get(key);
    if (cached != null) {
      return (cached['release-groups'] as List).cast<Map<String, dynamic>>();
    }

    await _rateLimiter.wait();
    final url = Uri.parse('$_baseUrl/release-group').replace(
      queryParameters: {
        'query': 'tag:"$genre"',
        'fmt': 'json',
        'limit': '$limit'
      },
    );
    final result = await http.getJson(url);
    cache.put(key, result, ttlSeconds: 60 * 60 * 24 * 30);
    return (result['release-groups'] as List).cast<Map<String, dynamic>>();
  }

  /// Searches album titles and artists using tokenized fuzzy terms. The
  /// unqualified terms are intentional: MusicBrainz's release-group index
  /// can distribute words between the artist and title fields, while an
  /// `AND` of fielded alternatives can be rejected when one word belongs to
  /// each side (for example, "jimi hendrix cornerstones"). The type
  /// restriction keeps songs, singles, and EPs out.
  Future<List<Map<String, dynamic>>> searchReleaseGroupsByText(String text,
      {int limit = 10}) async {
    final key = 'mb:search-text:$text';
    final cached = cache.get(key);
    if (cached != null) {
      return (cached['release-groups'] as List).cast<Map<String, dynamic>>();
    }

    await _rateLimiter.wait();
    final tokens = text
        .trim()
        .split(RegExp(r'\s+'))
        .map((token) =>
            token.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ''))
        .where((token) => token.isNotEmpty)
        .toList();
    final query = tokens.isEmpty
        ? 'type:album'
        : '${tokens.map((token) => '$token~').join(' AND ')} AND type:album';
    final url = Uri.parse('$_baseUrl/release-group').replace(
      queryParameters: {'query': query, 'fmt': 'json', 'limit': '$limit'},
    );
    final result = await http.getJson(url);
    cache.put(key, result, ttlSeconds: 60 * 60 * 24 * 30);
    return (result['release-groups'] as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> lookupReleaseGroup(String mbid) async {
    final key = 'mb:release-group:$mbid';
    final cached = cache.get(key);
    if (cached != null) return cached;

    await _rateLimiter.wait();
    final url = Uri.parse('$_baseUrl/release-group/$mbid').replace(
      queryParameters: {'inc': 'genres+artist-credits+releases', 'fmt': 'json'},
    );
    final result = await http.getJson(url);
    cache.put(key, result, ttlSeconds: 60 * 60 * 24 * 90);
    return result;
  }

  Future<Map<String, dynamic>> lookupReleaseUrlRelations(
      String releaseMbid) async {
    final key = 'mb:release-urls:$releaseMbid';
    final cached = cache.get(key);
    if (cached != null) return cached;

    await _rateLimiter.wait();
    final url = Uri.parse('$_baseUrl/release/$releaseMbid').replace(
      queryParameters: {'inc': 'url-rels', 'fmt': 'json'},
    );
    final result = await http.getJson(url);
    cache.put(key, result, ttlSeconds: 60 * 60 * 24 * 90);
    return result;
  }

  /// Looks up one representative release's recording list for the details
  /// sheet. The response is cached like the other MusicBrainz lookups.
  Future<Map<String, dynamic>> lookupReleaseRecordings(
      String releaseMbid) async {
    final key = 'mb:release-recordings:$releaseMbid';
    final cached = cache.get(key);
    if (cached != null) return cached;

    await _rateLimiter.wait();
    final url = Uri.parse('$_baseUrl/release/$releaseMbid').replace(
      queryParameters: {
        'inc': 'recordings+artist-credits+media',
        'fmt': 'json',
      },
    );
    final result = await http.getJson(url);
    cache.put(key, result, ttlSeconds: 60 * 60 * 24 * 90);
    return result;
  }

  Future<List<Map<String, dynamic>>> browseReleaseGroupsByArtist(
      String artistMbid) async {
    final key = 'mb:browse-release-groups:$artistMbid';
    final cached = cache.get(key);
    if (cached != null) {
      return (cached['release-groups'] as List).cast<Map<String, dynamic>>();
    }

    await _rateLimiter.wait();
    final url = Uri.parse('$_baseUrl/release-group').replace(
      queryParameters: {
        'artist': artistMbid,
        'inc': 'genres',
        'fmt': 'json',
        'limit': '100'
      },
    );
    final result = await http.getJson(url);
    cache.put(key, result, ttlSeconds: 60 * 60 * 24 * 30);
    return (result['release-groups'] as List).cast<Map<String, dynamic>>();
  }
}
