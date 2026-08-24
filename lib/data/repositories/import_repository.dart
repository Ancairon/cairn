import 'dart:convert';

import 'album_repository.dart';
import 'backup_repository.dart';
import 'rating_repository.dart';

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

  ImportRow({
    required this.mbid,
    required this.title,
    required this.artist,
    required this.stars,
    required this.ratedAt,
    required this.notes,
  });
}

enum ImportRowOutcome { added, overwritten, unmatched }

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

  ImportPreview({
    required this.newRows,
    required this.overwriteRows,
    required this.unmatchedRows,
  });

  int get newCount => newRows.length;
  int get overwriteCount => overwriteRows.length;
  int get unmatchedCount => unmatchedRows.length;
}

class ImportRepository {
  final RatingRepository ratings;
  final AlbumRepository albums;
  final BackupRepository backups;

  ImportRepository(this.ratings, this.albums, this.backups);

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
    final rows = _parse(content);
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
    );
  }

  /// Snapshots the current database first (a safety copy, not an in-app
  /// restore feature — see BackupRepository.createPreImportSafetySnapshot),
  /// then writes every matched row with imported-always-overwrites
  /// semantics, preserving each row's original `rated_at`. Returns the
  /// number of ratings written.
  Future<int> apply(
      ImportPreview preview, String safetySnapshotFolderPath) async {
    await backups.createPreImportSafetySnapshot(safetySnapshotFolderPath);
    for (final row in [...preview.newRows, ...preview.overwriteRows]) {
      ratings.rate(row.mbid!, row.stars,
          notes: row.notes, ratedAt: row.ratedAt);
    }
    return preview.newCount + preview.overwriteCount;
  }

  List<ImportRow> _parse(String content) {
    final trimmed = content.trimLeft();
    return trimmed.startsWith('[') ? _parseJson(content) : _parseCsv(content);
  }

  List<ImportRow> _parseJson(String content) {
    final decoded = jsonDecode(content) as List;
    return decoded.map((entry) {
      final row = entry as Map<String, dynamic>;
      return ImportRow(
        mbid: row['mbid'] as String?,
        title: row['title'] as String? ?? '',
        artist: row['artist'] as String? ?? '',
        stars: row['stars'] as int,
        ratedAt: DateTime.parse(row['rated_at'] as String),
        notes: row['notes'] as String?,
      );
    }).toList();
  }

  /// Supports both the current export header (`mbid,title,artist,year,
  /// genres,stars,rated_at,notes`) and the format exported before this
  /// project added `mbid` (`title,artist,year,genres,stars,rated_at,
  /// notes`) — an old export has no `mbid` at all, so its rows land in
  /// [ImportPreview.unmatchedRows] rather than crashing the whole file.
  List<ImportRow> _parseCsv(String content) {
    final rows = _parseCsvRows(content);
    if (rows.length <= 1) return const [];
    final header = rows.first;
    final hasMbid = header.isNotEmpty && header.first == 'mbid';
    final offset = hasMbid ? 1 : 0;
    return rows.skip(1).map((fields) {
      return ImportRow(
        mbid: hasMbid && fields[0].isNotEmpty ? fields[0] : null,
        title: fields[offset],
        artist: fields[offset + 1],
        stars: int.parse(fields[offset + 4]),
        ratedAt: DateTime.parse(fields[offset + 5]),
        notes: fields[offset + 6].isEmpty ? null : fields[offset + 6],
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
