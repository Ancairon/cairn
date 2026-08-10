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
  Future<List<Map<String, dynamic>>> searchReleaseGroupsByTag(String genre, {int limit = 25}) async {
    final key = 'mb:search-tag:$genre';
    final cached = cache.get(key);
    if (cached != null) return (cached['release-groups'] as List).cast<Map<String, dynamic>>();

    await _rateLimiter.wait();
    final url = Uri.parse('$_baseUrl/release-group').replace(
      queryParameters: {'query': 'tag:"$genre"', 'fmt': 'json', 'limit': '$limit'},
    );
    final result = await http.getJson(url);
    cache.put(key, result, ttlSeconds: 60 * 60 * 24 * 30);
    return (result['release-groups'] as List).cast<Map<String, dynamic>>();
  }

  /// Free-text release-group search — the user's own words (artist, title,
  /// or both together), not a structured query. Used by the CLI's `search`
  /// command to let the user jump straight to a known album.
  Future<List<Map<String, dynamic>>> searchReleaseGroupsByText(String text, {int limit = 10}) async {
    final key = 'mb:search-text:$text';
    final cached = cache.get(key);
    if (cached != null) return (cached['release-groups'] as List).cast<Map<String, dynamic>>();

    await _rateLimiter.wait();
    final url = Uri.parse('$_baseUrl/release-group').replace(
      queryParameters: {'query': text, 'fmt': 'json', 'limit': '$limit'},
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

  Future<Map<String, dynamic>> lookupReleaseUrlRelations(String releaseMbid) async {
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

  Future<List<Map<String, dynamic>>> browseReleaseGroupsByArtist(String artistMbid) async {
    final key = 'mb:browse-release-groups:$artistMbid';
    final cached = cache.get(key);
    if (cached != null) return (cached['release-groups'] as List).cast<Map<String, dynamic>>();

    await _rateLimiter.wait();
    final url = Uri.parse('$_baseUrl/release-group').replace(
      queryParameters: {'artist': artistMbid, 'inc': 'genres', 'fmt': 'json', 'limit': '100'},
    );
    final result = await http.getJson(url);
    cache.put(key, result, ttlSeconds: 60 * 60 * 24 * 30);
    return (result['release-groups'] as List).cast<Map<String, dynamic>>();
  }
}
