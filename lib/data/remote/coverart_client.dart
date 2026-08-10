import '../../core/network/http_client.dart';
import '../../core/network/response_cache.dart';

/// Cover Art Archive — high-res artwork keyed by MusicBrainz release id.
/// Public, no auth.
class CoverArtClient {
  final ApiHttpClient http;
  final ResponseCache cache;

  CoverArtClient(this.http, this.cache);

  /// Returns the front cover image URL, or null if this release has no
  /// artwork archived (common for obscure releases).
  Future<String?> frontCoverUrl(String releaseMbid) async {
    final key = 'coverart:$releaseMbid';
    final cached = cache.get(key);
    if (cached != null) return cached['url'] as String?;

    try {
      final result = await http.getJson(Uri.parse('https://coverartarchive.org/release/$releaseMbid'));
      final images = ((result['images'] as List?) ?? []).cast<Map<String, dynamic>>();
      final front = images.firstWhere(
        (img) => img['front'] == true,
        orElse: () => images.isNotEmpty ? images.first : <String, dynamic>{},
      );
      final url = front['image'] as String?;
      cache.put(key, {'url': url}, ttlSeconds: 60 * 60 * 24 * 90);
      return url;
    } on HttpException {
      cache.put(key, {'url': null}, ttlSeconds: 60 * 60 * 24 * 7);
      return null;
    }
  }
}
