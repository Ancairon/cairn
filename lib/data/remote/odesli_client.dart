import '../../core/network/http_client.dart';
import '../../core/network/response_cache.dart';

/// Odesli — resolves one platform link into a universal set of platform
/// links. Public; 10 req/min unauthenticated, which this app's usage stays
/// well under.
class OdesliClient {
  final ApiHttpClient http;
  final ResponseCache cache;

  OdesliClient(this.http, this.cache);

  /// Returns service name -> URL. Empty map if Odesli has nothing indexed
  /// for this link.
  Future<Map<String, String>> resolve(String seedUrl) async {
    final key = 'odesli:$seedUrl';
    final cached = cache.get(key);
    if (cached != null) return (cached['links'] as Map).cast<String, String>();

    try {
      final url = Uri.parse('https://api.song.link/v1-alpha.1/links').replace(
        queryParameters: {'url': seedUrl},
      );
      final result = await http.getJson(url);
      final linksByPlatform = ((result['linksByPlatform'] as Map?) ?? {}).cast<String, dynamic>();
      final links = linksByPlatform.map(
        (platform, data) => MapEntry(platform, (data as Map)['url'] as String),
      );
      cache.put(key, {'links': links}, ttlSeconds: 60 * 60 * 24 * 30);
      return links;
    } on HttpException {
      cache.put(key, {'links': <String, String>{}}, ttlSeconds: 60 * 60 * 24 * 7);
      return {};
    }
  }
}
