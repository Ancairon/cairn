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

  Future<Map<String, dynamic>> searchReleaseGroup(String artist, String title) async {
    final key = 'mb:search-release-group:$artist:$title';
    final cached = cache.get(key);
    if (cached != null) return cached;

    await _rateLimiter.wait();
    final query = artist.isEmpty ? 'release:"$title"' : 'artist:"$artist" AND release:"$title"';
    final url = Uri.parse('$_baseUrl/release-group').replace(
      queryParameters: {'query': query, 'fmt': 'json'},
    );
    final result = await http.getJson(url);
    cache.put(key, result, ttlSeconds: 60 * 60 * 24 * 30);
    return result;
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
