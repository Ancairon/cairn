import 'package:flutter/foundation.dart';
import '../../core/app_version.dart';
import '../../data/models/album.dart';
import '../../data/remote/musicbrainz_client.dart';
import '../../data/repositories/album_repository.dart';
import '../../data/repositories/rating_repository.dart';
import '../../data/repositories/recommendation_repository.dart';
import '../../data/repositories/deep_link_repository.dart';
import '../../data/repositories/saved_filter_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/backup_repository.dart';
import '../../data/repositories/notes_repository.dart';
import '../../data/repositories/update_check_repository.dart';

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
  final NotesRepository notes;
  final UpdateCheckRepository updateCheck;

  DiscoveryController(
    this.albums,
    this.ratings,
    this.recommendations,
    this.deepLinks,
    this.musicBrainz,
    this.settings,
    this.savedFilters,
    this.backups,
    this.notes,
    this.updateCheck,
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

  /// Re-fetches metadata for every rated album, overwriting each local row
  /// (`AlbumRepository.refreshMetadata`, unlike `getOrFetch`'s "trust any
  /// existing row" default). Lets albums fetched before an improvement to
  /// the repository's own logic — the side-labelled-release preference
  /// (SOW-0010) or bracket-title cleanup — pick it up without a full data
  /// wipe. Sequential and can take a while: MusicBrainz is rate-limited to
  /// ~1 request/second, so a large rated-albums journal means a real wait;
  /// the Settings action calling this warns the user before starting.
  /// One album's fetch failing must not abort the rest of the run.
  Future<int> refreshRatedAlbumsMetadata() async {
    var refreshed = 0;
    for (final rating in ratings.allRatings()) {
      try {
        await albums.refreshMetadata(rating.albumMbid);
        refreshed++;
      } catch (_) {
        // Skip and continue.
      }
    }
    return refreshed;
  }

  /// Checks GitHub Releases for a newer version. Always a no-op in debug
  /// builds, regardless of [force] — see the in-method comment. Without
  /// [force], this is a no-op (returns `(true, null)` without touching the network) unless at
  /// least 7 days have passed since the last check — the same
  /// "opportunistic, on launch/resume, gated by a stored timestamp" pattern
  /// already used for weekly database backups, rather than adding this
  /// app's first-ever true background-scheduling mechanism just for this.
  /// [force] (the Settings button, and tapping the version number) always
  /// hits the network regardless of timing. Returns `(succeeded, newerVersion)`
  /// — `newerVersion` is null both when the check didn't run and when it ran
  /// but found nothing newer, so callers distinguish those via `succeeded`.
  Future<(bool succeeded, String? newerVersion)> checkForUpdate(
      {bool force = false}) async {
    // Debug builds aren't the audience for "go download the public
    // release from GitHub" — skip entirely, rather than compare a
    // fast-moving internal alpha version against the public release track
    // and risk a nonsensical result (they're two different numbering
    // schemes since SOW-0014's release-versioning split).
    if (kDebugMode) return (true, null);
    if (!force) {
      final last = settings.lastUpdateCheckAt();
      if (last != null && DateTime.now().difference(last).inDays < 7) {
        return (true, null);
      }
    }
    final latest = await updateCheck.latestVersion();
    settings.setLastUpdateCheckAt(DateTime.now());
    if (latest == null) return (false, null);
    return (true, isNewerVersion(latest, appVersion) ? latest : null);
  }

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
