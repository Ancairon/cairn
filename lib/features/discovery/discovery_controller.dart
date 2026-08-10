import 'package:flutter/foundation.dart';
import '../../data/models/album.dart';
import '../../data/repositories/album_repository.dart';
import '../../data/repositories/rating_repository.dart';
import '../../data/repositories/recommendation_repository.dart';
import '../../data/repositories/deep_link_repository.dart';

/// Drives the single discovery screen. Plain ChangeNotifier — no extra
/// state-management package, matching the rest of this project.
class DiscoveryController extends ChangeNotifier {
  final AlbumRepository albums;
  final RatingRepository ratings;
  final RecommendationRepository recommendations;
  final DeepLinkRepository deepLinks;

  DiscoveryController(this.albums, this.ratings, this.recommendations, this.deepLinks);

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
}
