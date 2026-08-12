import 'dart:convert';
import '../../core/db/app_database.dart';
import '../models/album.dart';
import '../models/album_details.dart';
import '../models/track.dart';
import '../remote/musicbrainz_client.dart';
import '../remote/coverart_client.dart';

class AlbumRepository {
  final AppDatabase database;
  final MusicBrainzClient musicBrainz;
  final CoverArtClient coverArt;

  AlbumRepository(this.database, this.musicBrainz, this.coverArt);

  /// Removes un-rated cached album metadata while preserving every row needed
  /// by the Rated Albums journal and the current discovery state.
  void clearUnratedCache() {
    database.db.execute('''
      DELETE FROM albums
      WHERE mbid NOT IN (SELECT album_mbid FROM ratings)
        AND mbid NOT IN (
          SELECT current_anchor_mbid FROM app_state WHERE current_anchor_mbid IS NOT NULL
          UNION SELECT last_shown_album_mbid FROM app_state WHERE last_shown_album_mbid IS NOT NULL
        )
    ''');
  }

  /// Searches albums already stored locally, used for instant live-search
  /// feedback before the debounced MusicBrainz request completes.
  List<Map<String, dynamic>> searchCached(String text, {int limit = 10}) {
    final tokens = text
        .trim()
        .split(RegExp(r'\s+'))
        .map((token) => token
            .toLowerCase()
            .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), ''))
        .where((token) => token.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return const [];
    final clauses = <String>[];
    final params = <Object>[];
    for (final token in tokens) {
      clauses.add('(LOWER(title) LIKE ? OR LOWER(artist_name) LIKE ?)');
      final pattern = '%$token%';
      params
        ..add(pattern)
        ..add(pattern);
    }
    params.add(limit);
    final rows = database.db.select(
      'SELECT mbid, title, artist_name, first_release_year FROM albums '
      'WHERE ${clauses.join(' AND ')} ORDER BY title COLLATE NOCASE LIMIT ?',
      params,
    );
    return rows
        .map((row) => <String, dynamic>{
              'id': row['mbid'] as String,
              'title': row['title'] as String,
              'artist-credit': [
                {'name': row['artist_name'] as String}
              ],
              'first-release-date': row['first_release_year']?.toString(),
            })
        .toList();
  }

  /// Returns cached release metadata plus a lightweight track listing.
  /// MusicBrainz's release-group endpoint identifies the album; the release
  /// endpoint supplies the recordings and durations used here.
  Future<AlbumDetails> getDetails(Album album) async {
    final releaseMbid = album.representativeReleaseMbid;
    if (releaseMbid == null) {
      return AlbumDetails(album: album, tracks: const []);
    }
    final data = await musicBrainz.lookupReleaseRecordings(releaseMbid);
    final tracks = <Track>[];
    final members = <String>{};
    _addArtistCredits(members, data['artist-credit']);
    for (final medium in ((data['media'] as List?) ?? const [])) {
      final mediumMap = (medium as Map).cast<String, dynamic>();
      final mediumPosition = mediumMap['position'] as int? ?? 1;
      for (final rawTrack in ((mediumMap['tracks'] as List?) ?? const [])) {
        final track = (rawTrack as Map).cast<String, dynamic>();
        final recording = (track['recording'] as Map?)?.cast<String, dynamic>();
        _addArtistCredits(members, track['artist-credit']);
        _addArtistCredits(members, recording?['artist-credit']);
        final length = track['length'] as int? ?? recording?['length'] as int?;
        tracks.add(Track(
          albumMbid: album.mbid,
          recordingMbid: recording?['id'] as String?,
          position: track['position'] as int?,
          title: track['title'] as String? ??
              recording?['title'] as String? ??
              'Untitled track',
          durationMs: length,
          number: track['number'] as String?,
          mediumPosition: mediumPosition,
        ));
      }
    }
    // position restarts at 1 per medium, so a genuinely multi-disc release
    // needs mediumPosition compared first — sorting on position alone would
    // interleave medium 2's tracks with medium 1's wherever they share a
    // position number.
    tracks.sort((a, b) {
      final mediumCompare = a.mediumPosition.compareTo(b.mediumPosition);
      if (mediumCompare != 0) return mediumCompare;
      return (a.position ?? 0).compareTo(b.position ?? 0);
    });
    final primaryArtist = album.artistName.trim().toLowerCase();
    members.removeWhere((member) => member.toLowerCase() == primaryArtist);
    return AlbumDetails(
      album: album,
      tracks: tracks,
      members: members.toList()..sort(),
    );
  }

  void _addArtistCredits(Set<String> names, dynamic rawCredits) {
    if (rawCredits is! List) return;
    for (final rawCredit in rawCredits) {
      if (rawCredit is! Map) continue;
      final credit = rawCredit.cast<String, dynamic>();
      final artist = (credit['artist'] as Map?)?.cast<String, dynamic>();
      final name = credit['name'] as String? ?? artist?['name'] as String?;
      if (name != null && name.trim().isNotEmpty) names.add(name.trim());
    }
  }

  /// Loads an album from the local DB, fetching and caching it from
  /// MusicBrainz/Cover Art Archive the first time we ever see this mbid.
  Future<Album> getOrFetch(String releaseGroupMbid) async {
    final existing = _readLocal(releaseGroupMbid);
    if (existing != null) return existing;
    return _fetchAndStoreAlbum(releaseGroupMbid);
  }

  /// Re-fetches [releaseGroupMbid]'s metadata from MusicBrainz/Cover Art
  /// Archive and overwrites the local row, even if one already exists —
  /// unlike [getOrFetch], which trusts any existing row and never re-fetches
  /// it. Backs the Settings "Refresh rated albums' metadata" action, so
  /// albums fetched before an improvement to this repository's own logic
  /// (e.g. the side-labelled-release preference, or bracket-title cleanup)
  /// can pick it up without a full data wipe.
  Future<Album> refreshMetadata(String releaseGroupMbid) =>
      _fetchAndStoreAlbum(releaseGroupMbid);

  Future<Album> _fetchAndStoreAlbum(String releaseGroupMbid) async {
    final data = await musicBrainz.lookupReleaseGroup(releaseGroupMbid);
    final chronologicalReleases = _chronologicalReleases(data);
    // Prefer the earliest release that actually has a side-labelled format
    // (Vinyl/Cassette conventionally use A/B-style sides; CD/digital don't)
    // — a proxy for "likely has meaningful disc-side track data", not a
    // guarantee (a release tagged Vinyl can still lack lettered track
    // numbers if whoever entered it didn't fill those in). Falls back to
    // the plain earliest release when no side-labelled one exists, which is
    // the only behavior this app had before this preference existed.
    final sideLabelledRelease = chronologicalReleases.firstWhere(
      _looksSideLabelled,
      orElse: () => const <String, dynamic>{},
    );
    final representativeReleaseMbid = (sideLabelledRelease['id'] as String?) ??
        (chronologicalReleases.isNotEmpty
            ? chronologicalReleases.first['id'] as String?
            : null);

    final genres = ((data['genres'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .map((g) => g['name'] as String)
        .toList();

    // Prioritize the earliest pressing, then inspect five chronological
    // releases before expanding to later pressings only when needed.
    final coverArtUrl = await _findCoverArt(chronologicalReleases);

    final album = Album(
      mbid: releaseGroupMbid,
      representativeReleaseMbid: representativeReleaseMbid,
      title: Album.stripOuterBrackets(data['title'] as String),
      artistName: _artistName(data),
      artistMbid: _artistMbid(data),
      firstReleaseYear: _yearFrom(data['first-release-date'] as String?),
      genres: genres,
      coverArtUrl: coverArtUrl,
    );
    _writeLocal(album);
    // Re-read rather than return `album` directly — `album` doesn't carry
    // this row's existing owns_cd/owns_vinyl (they're not part of what
    // MusicBrainz returns), so the accurate values come from the row
    // _writeLocal's upsert just left in place.
    return _readLocal(releaseGroupMbid)!;
  }

  bool _looksSideLabelled(Map<String, dynamic> release) {
    final media = ((release['media'] as List?) ?? const [])
        .cast<Map>()
        .map((m) => m.cast<String, dynamic>());
    return media.any((medium) {
      final format = (medium['format'] as String?)?.toLowerCase() ?? '';
      return format.contains('vinyl') || format.contains('cassette');
    });
  }

  List<Map<String, dynamic>> _chronologicalReleases(Map<String, dynamic> data) {
    final releases =
        ((data['releases'] as List?) ?? []).cast<Map<String, dynamic>>();
    return [...releases]..sort((a, b) {
        final aDate = DateTime.tryParse(a['date'] as String? ?? '');
        final bDate = DateTime.tryParse(b['date'] as String? ?? '');
        if (aDate == null && bDate == null) return 0;
        if (aDate == null) return 1;
        if (bDate == null) return -1;
        return aDate.compareTo(bDate);
      });
  }

  Future<String?> _findCoverArt(List<Map<String, dynamic>> releases,
      {bool forceRefresh = false}) async {
    for (final release in releases) {
      final releaseMbid = release['id'] as String?;
      if (releaseMbid == null) continue;
      final url =
          await coverArt.frontCoverUrl(releaseMbid, forceRefresh: forceRefresh);
      if (url != null) return url;
    }
    return null;
  }

  Album? _readLocal(String mbid) {
    final rows =
        database.db.select('SELECT * FROM albums WHERE mbid = ?', [mbid]);
    if (rows.isEmpty) return null;

    final row = rows.first;
    final genresJson = row['genres'] as String?;
    return Album(
      mbid: row['mbid'] as String,
      representativeReleaseMbid: row['representative_release_mbid'] as String?,
      title: row['title'] as String,
      artistName: row['artist_name'] as String,
      artistMbid: row['artist_mbid'] as String?,
      firstReleaseYear: row['first_release_year'] as int?,
      genres: genresJson != null
          ? (jsonDecode(genresJson) as List).cast<String>()
          : const [],
      coverArtUrl: _largeArtworkUrl(row['cover_art_url'] as String?),
      ownsCd: (row['owns_cd'] as int) != 0,
      ownsVinyl: (row['owns_vinyl'] as int) != 0,
    );
  }

  String? _largeArtworkUrl(String? url) =>
      url?.replaceFirst('front-250', 'front-500');

  /// Toggles physical-ownership flags for an album already in the local DB.
  void setOwnership(String mbid, {bool? ownsCd, bool? ownsVinyl}) {
    if (ownsCd != null) {
      database.db.execute('UPDATE albums SET owns_cd = ? WHERE mbid = ?',
          [ownsCd ? 1 : 0, mbid]);
    }
    if (ownsVinyl != null) {
      database.db.execute('UPDATE albums SET owns_vinyl = ? WHERE mbid = ?',
          [ownsVinyl ? 1 : 0, mbid]);
    }
  }

  // An upsert (not a plain INSERT) so refreshMetadata can overwrite an
  // existing row's metadata — owns_cd/owns_vinyl are deliberately excluded
  // from the UPDATE clause, since MusicBrainz has no opinion on physical
  // ownership and a refresh must never touch it.
  void _writeLocal(Album album) {
    database.db.execute(
      'INSERT INTO albums (mbid, representative_release_mbid, title, artist_name, artist_mbid, '
      'first_release_year, genres, cover_art_url, metadata_fetched_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(mbid) DO UPDATE SET '
      'representative_release_mbid = excluded.representative_release_mbid, '
      'title = excluded.title, '
      'artist_name = excluded.artist_name, '
      'artist_mbid = excluded.artist_mbid, '
      'first_release_year = excluded.first_release_year, '
      'genres = excluded.genres, '
      'cover_art_url = excluded.cover_art_url, '
      'metadata_fetched_at = excluded.metadata_fetched_at',
      [
        album.mbid,
        album.representativeReleaseMbid,
        album.title,
        album.artistName,
        album.artistMbid,
        album.firstReleaseYear,
        jsonEncode(album.genres),
        album.coverArtUrl,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  String _artistName(Map<String, dynamic> data) {
    final credits =
        ((data['artist-credit'] as List?) ?? []).cast<Map<String, dynamic>>();
    return credits.map((c) => c['name'] as String).join(', ');
  }

  String? _artistMbid(Map<String, dynamic> data) {
    final credits =
        ((data['artist-credit'] as List?) ?? []).cast<Map<String, dynamic>>();
    if (credits.isEmpty) return null;
    return (credits.first['artist'] as Map<String, dynamic>?)?['id'] as String?;
  }

  int? _yearFrom(String? date) {
    if (date == null || date.length < 4) return null;
    return int.tryParse(date.substring(0, 4));
  }
}
