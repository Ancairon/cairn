import 'dart:convert';

import '../models/saved_filter.dart';
import 'album_repository.dart';
import 'backup_repository.dart';
import 'rating_repository.dart';
import 'recommendation_repository.dart';
import 'saved_filter_repository.dart';
import 'settings_repository.dart';

/// One row parsed from an exported JSON/CSV file, before it's been matched
/// against a local album. [mbid] is null for rows exported before this
/// project added the album id to the export format — those are always
/// reported as unmatched rather than guessed by title/artist.
class ImportRow {
  final String? mbid;
  final String title;
  final String artist;
  final int stars;
  final DateTime ratedAt;
  final String? notes;

  /// False for rows exported before this project added ownership to the
  /// export format — never guessed, since "unknown" and "not owned" would
  /// otherwise be indistinguishable, but treating an old file as "not
  /// owned" is the same default a never-imported album already has.
  final bool ownsCd;
  final bool ownsVinyl;

  ImportRow({
    required this.mbid,
    required this.title,
    required this.artist,
    required this.stars,
    required this.ratedAt,
    required this.notes,
    this.ownsCd = false,
    this.ownsVinyl = false,
  });
}

enum ImportRowOutcome { added, overwritten, unmatched }

/// A portable subset of `SettingsRepository` — deliberately excludes
/// device-specific fields (backup folder path, auto-backup consent,
/// last-checked timestamps) that would be actively wrong to carry onto a
/// different device or a fresh install. `null` on `defaultOpenedMenuItem`/
/// `defaultPlayerApp` is itself meaningful ("None" was selected) and is
/// applied as-is; `null` on the other three fields means "not set on the
/// source device" and is left untouched locally, since their setters have
/// no way to represent "no value" at all.
class ImportedSettings {
  final String? defaultOpenedMenuItem;
  final String? defaultPlayerApp;
  final String? ratedAlbumsSort;
  final String? ratedAlbumsView;
  final String? ratedAlbumsSize;

  ImportedSettings({
    required this.defaultOpenedMenuItem,
    required this.defaultPlayerApp,
    required this.ratedAlbumsSort,
    required this.ratedAlbumsView,
    required this.ratedAlbumsSize,
  });
}

/// Reported once per row as [ImportRepository.preview] works through a
/// file — matching an uncached album is a live, rate-limited MusicBrainz
/// call, so a large file can take a real amount of time and needs visible
/// progress rather than looking stuck.
class ImportProgress {
  final int current;
  final int total;
  final ImportRow row;

  /// Null when the row has no `mbid` to look up at all; otherwise whether
  /// the album was already cached locally (fast) or required a live
  /// MusicBrainz fetch (the slow, rate-limited path).
  final bool? cached;
  final ImportRowOutcome outcome;

  ImportProgress({
    required this.current,
    required this.total,
    required this.row,
    required this.cached,
    required this.outcome,
  });
}

/// Result of matching parsed rows against local/MusicBrainz albums, computed
/// before anything is written so Settings can show it for confirmation.
class ImportPreview {
  final List<ImportRow> newRows;
  final List<ImportRow> overwriteRows;
  final List<ImportRow> unmatchedRows;

  /// Null for every field below when the source file predates this data
  /// (CSV, or the original bare-array JSON format) — those imports only
  /// ever touch ratings, exactly as before.
  final List<String>? likedGenres;
  final List<SavedFilter>? savedFilters;
  final ImportedSettings? settings;

  ImportPreview({
    required this.newRows,
    required this.overwriteRows,
    required this.unmatchedRows,
    this.likedGenres,
    this.savedFilters,
    this.settings,
  });

  int get newCount => newRows.length;
  int get overwriteCount => overwriteRows.length;
  int get unmatchedCount => unmatchedRows.length;
}

class ImportRepository {
  final RatingRepository ratings;
  final AlbumRepository albums;
  final BackupRepository backups;
  final RecommendationRepository recommendations;
  final SavedFilterRepository savedFilters;
  final SettingsRepository settings;

  ImportRepository(this.ratings, this.albums, this.backups,
      this.recommendations, this.savedFilters, this.settings);

  /// Parses [content] and matches each row strictly by `mbid` — never by
  /// title/artist, since there's no way to disambiguate reissues/same-titled
  /// works without one. Rows with no `mbid`, or whose `mbid` can't be
  /// resolved to an album (network failure, deleted release group, etc.),
  /// land in [ImportPreview.unmatchedRows]. [onProgress], if given, is
  /// called once per row as it's processed — matching an uncached album is
  /// a live, 1-request/second-throttled MusicBrainz call, so a file whose
  /// albums are new to this device can take tens of seconds or more.
  Future<ImportPreview> preview(String content,
      {void Function(ImportProgress progress)? onProgress}) async {
    final parsed = _parse(content);
    final rows = parsed.rows;
    final total = rows.length;
    final newRows = <ImportRow>[];
    final overwriteRows = <ImportRow>[];
    final unmatchedRows = <ImportRow>[];

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final mbid = row.mbid;
      if (mbid == null || mbid.isEmpty) {
        unmatchedRows.add(row);
        onProgress?.call(ImportProgress(
          current: i + 1,
          total: total,
          row: row,
          cached: null,
          outcome: ImportRowOutcome.unmatched,
        ));
        continue;
      }
      final wasCached = albums.isCachedLocally(mbid);
      try {
        await albums.getOrFetch(mbid);
      } catch (_) {
        unmatchedRows.add(row);
        onProgress?.call(ImportProgress(
          current: i + 1,
          total: total,
          row: row,
          cached: wasCached,
          outcome: ImportRowOutcome.unmatched,
        ));
        continue;
      }
      final overwrite = ratings.ratingFor(mbid) != null;
      (overwrite ? overwriteRows : newRows).add(row);
      onProgress?.call(ImportProgress(
        current: i + 1,
        total: total,
        row: row,
        cached: wasCached,
        outcome:
            overwrite ? ImportRowOutcome.overwritten : ImportRowOutcome.added,
      ));
    }

    return ImportPreview(
      newRows: newRows,
      overwriteRows: overwriteRows,
      unmatchedRows: unmatchedRows,
      likedGenres: parsed.likedGenres,
      savedFilters: parsed.savedFilters,
      settings: parsed.settings,
    );
  }

  /// Snapshots the current database first (a safety copy, not an in-app
  /// restore feature — see BackupRepository.createPreImportSafetySnapshot),
  /// then writes every matched row with imported-always-overwrites
  /// semantics, preserving each row's original `rated_at`, and applies
  /// liked genres/saved filters/settings when the source file had them.
  /// Returns the number of ratings written (genres/filters/settings aren't
  /// counted — they're either wholly present or wholly absent per file, not
  /// a per-row outcome).
  Future<int> apply(
      ImportPreview preview, String safetySnapshotFolderPath) async {
    await backups.createPreImportSafetySnapshot(safetySnapshotFolderPath);
    for (final row in [...preview.newRows, ...preview.overwriteRows]) {
      ratings.rate(row.mbid!, row.stars,
          notes: row.notes, ratedAt: row.ratedAt);
      albums.setOwnership(row.mbid!,
          ownsCd: row.ownsCd, ownsVinyl: row.ownsVinyl);
    }
    if (preview.likedGenres != null) {
      recommendations.setLikedGenres(preview.likedGenres!);
    }
    if (preview.savedFilters != null) {
      final existing = savedFilters.all();
      for (final filter in preview.savedFilters!) {
        SavedFilter? match;
        for (final candidate in existing) {
          if (candidate.name == filter.name) {
            match = candidate;
            break;
          }
        }
        if (match != null) {
          savedFilters.update(match.id!, filter.name, filter.criteria);
        } else {
          savedFilters.create(filter.name, filter.criteria);
        }
      }
    }
    final importedSettings = preview.settings;
    if (importedSettings != null) {
      settings.setDefaultOpenedMenuItem(importedSettings.defaultOpenedMenuItem);
      settings.setDefaultPlayerApp(importedSettings.defaultPlayerApp);
      if (importedSettings.ratedAlbumsSort != null) {
        settings.setRatedAlbumsSort(importedSettings.ratedAlbumsSort!);
      }
      if (importedSettings.ratedAlbumsView != null) {
        settings.setRatedAlbumsView(importedSettings.ratedAlbumsView!);
      }
      if (importedSettings.ratedAlbumsSize != null) {
        settings.setRatedAlbumsSize(importedSettings.ratedAlbumsSize!);
      }
    }
    return preview.newCount + preview.overwriteCount;
  }

  /// `{...}` is the current export shape (ratings + liked genres + saved
  /// filters + settings, see `ExportRepository.toJson`); a bare `[...]` is
  /// the original ratings-only JSON shape from before this project added
  /// those other sections; anything else is CSV, which has never carried
  /// more than ratings. Only the object shape ever populates
  /// likedGenres/savedFilters/settings on the returned record.
  ({
    List<ImportRow> rows,
    List<String>? likedGenres,
    List<SavedFilter>? savedFilters,
    ImportedSettings? settings,
  }) _parse(String content) {
    final trimmed = content.trimLeft();
    if (trimmed.startsWith('{')) {
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      return (
        rows: _parseRatingsList(decoded['ratings'] as List? ?? const []),
        likedGenres: (decoded['liked_genres'] as List?)?.cast<String>(),
        savedFilters: _parseSavedFilters(decoded['saved_filters'] as List?),
        settings: _parseSettings(decoded['settings'] as Map<String, dynamic>?),
      );
    }
    if (trimmed.startsWith('[')) {
      return (
        rows: _parseRatingsList(jsonDecode(content) as List),
        likedGenres: null,
        savedFilters: null,
        settings: null,
      );
    }
    return (
      rows: _parseCsv(content),
      likedGenres: null,
      savedFilters: null,
      settings: null,
    );
  }

  List<ImportRow> _parseRatingsList(List decoded) {
    return decoded.map((entry) {
      final row = entry as Map<String, dynamic>;
      return ImportRow(
        mbid: row['mbid'] as String?,
        title: row['title'] as String? ?? '',
        artist: row['artist'] as String? ?? '',
        stars: row['stars'] as int,
        ratedAt: DateTime.parse(row['rated_at'] as String),
        notes: row['notes'] as String?,
        ownsCd: row['owns_cd'] as bool? ?? false,
        ownsVinyl: row['owns_vinyl'] as bool? ?? false,
      );
    }).toList();
  }

  List<SavedFilter>? _parseSavedFilters(List? decoded) {
    if (decoded == null) return null;
    return decoded.map((entry) {
      final map = entry as Map<String, dynamic>;
      return SavedFilter(
        name: map['name'] as String,
        criteria: FilterCriteria(
          ownership: map['ownership'] as String?,
          minRating: map['min_rating'] as int?,
          maxRating: map['max_rating'] as int?,
        ),
      );
    }).toList();
  }

  ImportedSettings? _parseSettings(Map<String, dynamic>? map) {
    if (map == null) return null;
    return ImportedSettings(
      defaultOpenedMenuItem: map['default_opened_menu_item'] as String?,
      defaultPlayerApp: map['default_player_app'] as String?,
      ratedAlbumsSort: map['rated_albums_sort'] as String?,
      ratedAlbumsView: map['rated_albums_view'] as String?,
      ratedAlbumsSize: map['rated_albums_size'] as String?,
    );
  }

  /// Looks columns up by name rather than a fixed position, since this
  /// format has grown twice (adding `mbid`, then `owns_cd`/`owns_vinyl`) —
  /// a column missing from an older export (checked by name, not position)
  /// falls back to its `ImportRow` default rather than crashing the file.
  List<ImportRow> _parseCsv(String content) {
    final rows = _parseCsvRows(content);
    if (rows.length <= 1) return const [];
    final header = rows.first;
    final mbidIndex = header.indexOf('mbid');
    final titleIndex = header.indexOf('title');
    final artistIndex = header.indexOf('artist');
    final starsIndex = header.indexOf('stars');
    final ratedAtIndex = header.indexOf('rated_at');
    final notesIndex = header.indexOf('notes');
    final ownsCdIndex = header.indexOf('owns_cd');
    final ownsVinylIndex = header.indexOf('owns_vinyl');
    String field(List<String> fields, int index) =>
        index == -1 || index >= fields.length ? '' : fields[index];

    return rows.skip(1).map((fields) {
      final mbidValue = field(fields, mbidIndex);
      return ImportRow(
        mbid: mbidValue.isEmpty ? null : mbidValue,
        title: field(fields, titleIndex),
        artist: field(fields, artistIndex),
        stars: int.parse(field(fields, starsIndex)),
        ratedAt: DateTime.parse(field(fields, ratedAtIndex)),
        notes: field(fields, notesIndex).isEmpty
            ? null
            : field(fields, notesIndex),
        ownsCd: field(fields, ownsCdIndex) == 'true',
        ownsVinyl: field(fields, ownsVinylIndex) == 'true',
      );
    }).toList();
  }

  /// Reverses `ExportRepository._csvField`'s escaping across the whole file
  /// at once, not line-by-line — a quoted field can contain a literal `\n`
  /// (a multi-line note), so splitting into lines before parsing quotes
  /// would tear that field across two bogus rows. `""` inside a quoted
  /// field decodes to a literal `"`. Blank lines are dropped.
  List<List<String>> _parseCsvRows(String content) {
    final normalized = content.replaceAll('\r\n', '\n');
    final rows = <List<String>>[];
    var fields = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var i = 0;
    while (i < normalized.length) {
      final char = normalized[i];
      if (inQuotes) {
        if (char == '"') {
          if (i + 1 < normalized.length && normalized[i + 1] == '"') {
            field.write('"');
            i += 2;
          } else {
            inQuotes = false;
            i++;
          }
        } else {
          field.write(char);
          i++;
        }
      } else if (char == '"') {
        inQuotes = true;
        i++;
      } else if (char == ',') {
        fields.add(field.toString());
        field.clear();
        i++;
      } else if (char == '\n') {
        fields.add(field.toString());
        field.clear();
        rows.add(fields);
        fields = <String>[];
        i++;
      } else {
        field.write(char);
        i++;
      }
    }
    if (field.isNotEmpty || fields.isNotEmpty) {
      fields.add(field.toString());
      rows.add(fields);
    }
    return rows.where((row) => !(row.length == 1 && row[0].isEmpty)).toList();
  }
}
