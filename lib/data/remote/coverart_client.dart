import '../../core/network/http_client.dart';
import '../../core/network/response_cache.dart';

/// Cover Art Archive — high-res artwork keyed by MusicBrainz release id.
/// Public, no auth.
class CoverArtClient {
  final ApiHttpClient http;
  final ResponseCache cache;

  CoverArtClient(this.http, this.cache);

  /// A release-group search result already gives us the group MBID.  CAA's
  /// image endpoint can resolve that MBID directly, so search rows can start
  /// loading a small image without waiting for a full release-group lookup.
  /// Missing artwork is handled by the image widget's error placeholder.
  static String releaseGroupThumbnailUrl(String releaseGroupMbid,
      {int size = 250}) {
    final boundedSize = size <= 250 ? 250 : 500;
    return 'https://coverartarchive.org/release-group/'
        '$releaseGroupMbid/front-$boundedSize';
  }

  /// Returns the front cover image URL, or null if this release has no
  /// artwork archived (common for obscure releases).
  Future<String?> frontCoverUrl(String releaseMbid,
      {bool forceRefresh = false}) async {
    final key = 'coverart:$releaseMbid';
    final cached = cache.get(key);
    if (!forceRefresh && cached != null) return cached['url'] as String?;

    try {
      final result = await http.getJson(
          Uri.parse('https://coverartarchive.org/release/$releaseMbid'));
      final images =
          ((result['images'] as List?) ?? []).cast<Map<String, dynamic>>();
      final front = images.firstWhere(
        (img) => img['front'] == true,
        orElse: () => images.isNotEmpty ? images.first : <String, dynamic>{},
      );
      // Keep the roughly 500px thumbnail for the focused main card. Rated
      // tiles derive the 250px variant and persist it through the image cache.
      final thumbnails = (front['thumbnails'] as Map?)?.cast<String, dynamic>();
      final url = (thumbnails?['large'] as String?) ??
          (thumbnails?['small'] as String?) ??
          (front['image'] as String?);
      cache.put(key, {'url': url}, ttlSeconds: 60 * 60 * 24 * 90);
      return url;
    } on HttpException {
      cache.put(key, {'url': null}, ttlSeconds: 60 * 60 * 24 * 7);
      return null;
    }
  }
}
