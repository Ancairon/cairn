import '../../core/db/app_database.dart';
import '../models/album.dart';
import '../remote/musicbrainz_client.dart';
import '../remote/odesli_client.dart';

// Preference order for picking a seed link to feed into Odesli — Bandcamp
// first since it tends to be the most reliable source for obscure releases.
const _seedPreferenceOrder = ['bandcamp', 'spotify', 'apple music', 'tidal', 'deezer'];

class DeepLinkRepository {
  final AppDatabase database;
  final MusicBrainzClient musicBrainz;
  final OdesliClient odesli;

  DeepLinkRepository(this.database, this.musicBrainz, this.odesli);

  /// Returns platform -> URL. An empty map means genuinely nothing was
  /// found — callers should fall back to [searchFallbackUrl] instead.
  Future<Map<String, String>> playLinksFor(Album album) async {
    if (album.representativeReleaseMbid == null) return {};

    final links = await _externalLinks(album.mbid, album.representativeReleaseMbid!);
    if (links.isEmpty) return {};

    final seed = _pickSeed(links);
    if (seed == null) return {};

    return odesli.resolve(seed);
  }

  /// Fallback when MusicBrainz has no links at all for this release — a
  /// generic search URL, no API/key involved.
  String searchFallbackUrl(Album album) {
    final query = Uri.encodeQueryComponent('${album.artistName} ${album.title}');
    return 'https://music.youtube.com/search?q=$query';
  }

  Future<Map<String, String>> _externalLinks(String albumMbid, String releaseMbid) async {
    final cached = database.db.select(
      'SELECT service, url FROM external_links WHERE album_mbid = ?',
      [albumMbid],
    );
    if (cached.isNotEmpty) {
      return {for (final row in cached) row['service'] as String: row['url'] as String};
    }

    final data = await musicBrainz.lookupReleaseUrlRelations(releaseMbid);
    final relations = ((data['relations'] as List?) ?? []).cast<Map<String, dynamic>>();
    final links = <String, String>{};
    for (final relation in relations) {
      final url = (relation['url'] as Map<String, dynamic>?)?['resource'] as String?;
      if (url == null) continue;
      final service = _classifyService(url);
      if (service != null) links[service] = url;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in links.entries) {
      database.db.execute(
        'INSERT INTO external_links (album_mbid, service, url, fetched_at) VALUES (?, ?, ?, ?)',
        [albumMbid, entry.key, entry.value, now],
      );
    }
    return links;
  }

  String? _pickSeed(Map<String, String> links) {
    for (final service in _seedPreferenceOrder) {
      if (links.containsKey(service)) return links[service];
    }
    return links.values.isEmpty ? null : links.values.first;
  }

  String? _classifyService(String url) {
    if (url.contains('bandcamp.com')) return 'bandcamp';
    if (url.contains('open.spotify.com') || url.startsWith('spotify:')) return 'spotify';
    if (url.contains('music.apple.com')) return 'apple music';
    if (url.contains('tidal.com')) return 'tidal';
    if (url.contains('deezer.com')) return 'deezer';
    if (url.contains('music.youtube.com') || url.contains('youtube.com')) return 'youtube music';
    return null;
  }
}
