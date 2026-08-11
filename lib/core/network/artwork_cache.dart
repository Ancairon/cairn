import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Persistent artwork cache shared by the focused card, rated tiles, and
/// background recommendation prefetches.
class ArtworkCache {
  static const cacheKey = 'cairn_artwork';
  static const maxBytes = 1024 * 1024 * 1024;
  static const targetBytes = 900 * 1024 * 1024;

  static final manager = CacheManager(
    Config(
      cacheKey,
      stalePeriod: const Duration(days: 1),
      maxNrOfCacheObjects: 5000,
    ),
  );

  static Future<void> prefetch(String url) async {
    try {
      await manager.downloadFile(url);
    } catch (_) {
      // Prefetching is opportunistic; a failed request must not affect the UI.
    }
  }

  /// Removes oldest cache files after the cache directory exceeds 1GB. The
  /// cache manager separately removes files unused for more than one day.
  static Future<void> collect() async {
    try {
      final temporary = await getTemporaryDirectory();
      final directory = Directory(path.join(temporary.path, cacheKey));
      if (!await directory.exists()) return;
      final files = <File>[];
      await for (final entity in directory.list()) {
        if (entity is File &&
            !entity.path.endsWith('.sqlite') &&
            !entity.path.endsWith('.sqlite-shm') &&
            !entity.path.endsWith('.sqlite-wal')) {
          files.add(entity);
        }
      }
      var total = 0;
      final sizes = <File, int>{};
      final modified = <File, DateTime>{};
      for (final file in files) {
        final stat = await file.stat();
        sizes[file] = stat.size;
        modified[file] = stat.modified;
        total += stat.size;
      }
      if (total <= maxBytes) return;
      files.sort((a, b) => modified[a]!.compareTo(modified[b]!));
      for (final file in files) {
        if (total <= targetBytes) break;
        total -= sizes[file]!;
        await file.delete();
      }
    } catch (_) {
      // Cache collection is best effort and must never block startup.
    }
  }
}
