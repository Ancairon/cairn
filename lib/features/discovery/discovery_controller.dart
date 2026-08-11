import 'package:flutter/foundation.dart';
import '../../data/models/album.dart';
import '../../data/remote/musicbrainz_client.dart';
import '../../data/repositories/album_repository.dart';
import '../../data/repositories/rating_repository.dart';
import '../../data/repositories/recommendation_repository.dart';
import '../../data/repositories/deep_link_repository.dart';
import '../../data/repositories/saved_filter_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/backup_repository.dart';

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
  final BackupRepository backups;

  DiscoveryController(
    this.albums,
    this.ratings,
    this.recommendations,
    this.deepLinks,
    this.musicBrainz,
    this.settings,
    this.savedFilters,
    this.backups,
  );

  Album? currentAlbum;
  Map<String, String> playLinks = {};
  bool isLoading = false;
  String? errorMessage;

  Future<void> loadNext() => _run(() async {
        final lastShown = await recommendations.restoreLastShown();
        return lastShown ?? recommendations.next();
      });

  Future<void> rate(int stars) => _run(() async {
        final album = currentAlbum;
        if (album == null) return recommendations.next();
        ratings.rate(album.mbid, stars);
        return recommendations.onRated(album, stars);
      });

  /// "Not right now" — deliberately not a rating: no row written to
  /// `ratings`, no anchor change, no pivot. Just moves on to the next album.
  Future<void> skip() => _run(() {
        final album = currentAlbum;
        if (album == null) return recommendations.next();
        if (ratings.ratingFor(album.mbid) != null) {
          return recommendations.nextRelated(album);
        }
        return recommendations.skip(album.mbid);
      });

  Future<void> skipButton() => _run(() {
        final album = currentAlbum;
        if (album == null) return recommendations.next();
        return recommendations.skipButton(album.mbid);
      });

  void resetSkipPenalties() => recommendations.resetSkipPenalties();

  Future<void> _run(Future<Album> Function() action) async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();

    try {
      final album = await action();
      currentAlbum = album;
      recommendations.markShown(album.mbid);
      recommendations.saveLastShown(album.mbid);
      recommendations.prefetchBranches(album);
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

  /// Maps a `settings.defaultPlayerApp()` value to its key in the Odesli
  /// `playLinks` map (confirmed against a live Odesli response: `spotify`
  /// and `youtubeMusic`, camelCase — distinct from the plain `youtube` key).
  static const _playerAppOdesliKeys = {
    playerAppSpotify: 'spotify',
    playerAppYoutubeMusic: 'youtubeMusic',
  };

  /// Direct link for [playerApp] if [playLinks] has one for the current
  /// album; null if the app value is unrecognized or nothing was found.
  String? directLinkFor(String playerApp) {
    final key = _playerAppOdesliKeys[playerApp];
    return key == null ? null : playLinks[key];
  }

  /// Search deep link scoped to [playerApp], built from the current album —
  /// the fallback when [directLinkFor] finds nothing for this album.
  String? searchUrlFor(String playerApp) {
    final album = currentAlbum;
    if (album == null) return null;
    switch (playerApp) {
      case playerAppSpotify:
        return deepLinks.spotifySearchUrl(album);
      case playerAppYoutubeMusic:
        return deepLinks.youtubeMusicSearchUrl(album);
      default:
        return null;
    }
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

  bool needsOnboarding() => recommendations.needsOnboarding();

  void setLikedGenres(List<String> genres) =>
      recommendations.setLikedGenres(genres);

  String? get sessionVibeGenre => recommendations.sessionVibeGenre;

  void setSessionVibeGenre(String genre) {
    recommendations.setSessionVibeGenre(genre);
    notifyListeners();
  }

  void clearSessionVibeGenre() {
    recommendations.clearSessionVibeGenre();
    notifyListeners();
  }

  /// Free-text search to seed a session from a specific album (search
  /// overlay). Returns raw MusicBrainz release-group maps — title/artist
  /// display fields, no local caching, since these are just picked from,
  /// not necessarily kept.
  Future<List<Map<String, dynamic>>> searchAlbums(String query) =>
      musicBrainz.searchReleaseGroupsByText(query);

  List<Map<String, dynamic>> searchCachedAlbums(String query) =>
      albums.searchCached(query);

  Future<void> startFromSearchResult(String releaseGroupMbid) => _run(() async {
        final album = await albums.getOrFetch(releaseGroupMbid);
        return recommendations.restartFrom(album);
      });
}
