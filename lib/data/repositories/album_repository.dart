import 'dart:convert';
import '../../core/db/app_database.dart';
import '../models/album.dart';
import '../remote/musicbrainz_client.dart';
import '../remote/coverart_client.dart';

class AlbumRepository {
  final AppDatabase database;
  final MusicBrainzClient musicBrainz;
  final CoverArtClient coverArt;

  AlbumRepository(this.database, this.musicBrainz, this.coverArt);

  /// Loads an album from the local DB, fetching and caching it from
  /// MusicBrainz/Cover Art Archive the first time we ever see this mbid.
  Future<Album> getOrFetch(String releaseGroupMbid) async {
    final existing = _readLocal(releaseGroupMbid);
    if (existing != null) return existing;

    final data = await musicBrainz.lookupReleaseGroup(releaseGroupMbid);
    final releases = ((data['releases'] as List?) ?? []).cast<Map<String, dynamic>>();
    final representativeReleaseMbid = releases.isNotEmpty ? releases.first['id'] as String? : null;

    final genres = ((data['genres'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .map((g) => g['name'] as String)
        .toList();

    String? coverArtUrl;
    if (representativeReleaseMbid != null) {
      coverArtUrl = await coverArt.frontCoverUrl(representativeReleaseMbid);
    }

    final album = Album(
      mbid: releaseGroupMbid,
      representativeReleaseMbid: representativeReleaseMbid,
      title: data['title'] as String,
      artistName: _artistName(data),
      artistMbid: _artistMbid(data),
      firstReleaseYear: _yearFrom(data['first-release-date'] as String?),
      genres: genres,
      coverArtUrl: coverArtUrl,
    );
    _writeLocal(album);
    return album;
  }

  Album? _readLocal(String mbid) {
    final rows = database.db.select('SELECT * FROM albums WHERE mbid = ?', [mbid]);
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
      genres: genresJson != null ? (jsonDecode(genresJson) as List).cast<String>() : const [],
      coverArtUrl: row['cover_art_url'] as String?,
      ownsCd: (row['owns_cd'] as int) != 0,
      ownsVinyl: (row['owns_vinyl'] as int) != 0,
    );
  }

  /// Toggles physical-ownership flags for an album already in the local DB.
  void setOwnership(String mbid, {bool? ownsCd, bool? ownsVinyl}) {
    if (ownsCd != null) {
      database.db.execute('UPDATE albums SET owns_cd = ? WHERE mbid = ?', [ownsCd ? 1 : 0, mbid]);
    }
    if (ownsVinyl != null) {
      database.db.execute('UPDATE albums SET owns_vinyl = ? WHERE mbid = ?', [ownsVinyl ? 1 : 0, mbid]);
    }
  }

  void _writeLocal(Album album) {
    database.db.execute(
      'INSERT INTO albums (mbid, representative_release_mbid, title, artist_name, artist_mbid, '
      'first_release_year, genres, cover_art_url, metadata_fetched_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
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
    final credits = ((data['artist-credit'] as List?) ?? []).cast<Map<String, dynamic>>();
    return credits.map((c) => c['name'] as String).join(', ');
  }

  String? _artistMbid(Map<String, dynamic> data) {
    final credits = ((data['artist-credit'] as List?) ?? []).cast<Map<String, dynamic>>();
    if (credits.isEmpty) return null;
    return (credits.first['artist'] as Map<String, dynamic>?)?['id'] as String?;
  }

  int? _yearFrom(String? date) {
    if (date == null || date.length < 4) return null;
    return int.tryParse(date.substring(0, 4));
  }
}
