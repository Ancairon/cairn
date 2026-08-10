import 'package:flutter/foundation.dart';
import '../../data/models/album.dart';
import '../../data/remote/musicbrainz_client.dart';
import '../../data/repositories/album_repository.dart';
import '../../data/repositories/rating_repository.dart';
import '../../data/repositories/recommendation_repository.dart';
import '../../data/repositories/deep_link_repository.dart';
import '../../data/repositories/saved_filter_repository.dart';
import '../../data/repositories/settings_repository.dart';

/// Drives the single discovery screen. Plain ChangeNotifier — no extra
/// state-management package, matching the rest of this project.
class DiscoveryController extends ChangeNotifier {
  final AlbumRepository albums;
  final RatingRepository ratings;
  final RecommendationRepository recommendations;
  final DeepLinkRepository deepLinks;
  final MusicBrainzClient musicBrainz;
  final SettingsRepository settings;
  final SavedFilterRepository savedFilters;

  DiscoveryController(
    this.albums,
    this.ratings,
    this.recommendations,
    this.deepLinks,
    this.musicBrainz,
    this.settings,
    this.savedFilters,
  );

  Album? currentAlbum;
  Map<String, String> playLinks = {};
  bool isLoading = false;
  String? errorMessage;

  Future<void> loadNext() => _run(() => recommendations.next());

  Future<void> rate(int stars) => _run(() async {
        final album = currentAlbum;
        if (album == null) return recommendations.next();
        ratings.rate(album.mbid, stars);
        return recommendations.onRated(album, stars);
      });

  Future<void> _run(Future<Album> Function() action) async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();

    try {
      final album = await action();
      currentAlbum = album;
      playLinks = await deepLinks.playLinksFor(album);
    } catch (e) {
      errorMessage = e.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  String fallbackSearchUrl() {
    final album = currentAlbum;
    return album == null ? '' : deepLinks.searchFallbackUrl(album);
  }

  void toggleOwnsCd() {
    final album = currentAlbum;
    if (album == null) return;
    final updated = !album.ownsCd;
    albums.setOwnership(album.mbid, ownsCd: updated);
    currentAlbum = album.copyWith(ownsCd: updated);
    notifyListeners();
  }

  void toggleOwnsVinyl() {
    final album = currentAlbum;
    if (album == null) return;
    final updated = !album.ownsVinyl;
    albums.setOwnership(album.mbid, ownsVinyl: updated);
    currentAlbum = album.copyWith(ownsVinyl: updated);
    notifyListeners();
  }

  List<String> likedGenres() => recommendations.likedGenres();

  void setLikedGenres(List<String> genres) => recommendations.setLikedGenres(genres);

  /// Free-text search to seed a session from a specific album (search
  /// overlay). Returns raw MusicBrainz release-group maps — title/artist
  /// display fields, no local caching, since these are just picked from,
  /// not necessarily kept.
  Future<List<Map<String, dynamic>>> searchAlbums(String query) =>
      musicBrainz.searchReleaseGroupsByText(query);

  Future<void> startFromSearchResult(String releaseGroupMbid) => _run(() async {
        final album = await albums.getOrFetch(releaseGroupMbid);
        return recommendations.restartFrom(album);
      });
}
