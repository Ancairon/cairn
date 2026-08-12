class Track {
  final int? id;
  final String albumMbid;
  final String? recordingMbid;
  final int? position;
  final String title;
  final int? durationMs;
  // MusicBrainz's free-text label for this track as actually printed on the
  // release (e.g. 'A1', or a non-standard 'G1') — distinct from [position],
  // which is always a plain sequential integer restarting at 1 per medium.
  final String? number;
  // Which physical disc this track is on, 1-based. Always populated by the
  // parser (defaults to 1 for a single-medium release) — not nullable, since
  // grouping/sorting logic needs a real value to compare.
  final int mediumPosition;

  Track({
    this.id,
    required this.albumMbid,
    this.recordingMbid,
    this.position,
    required this.title,
    this.durationMs,
    this.number,
    this.mediumPosition = 1,
  });

  /// Stable key for associating local data (e.g. a per-track comment) with
  /// this track. Tracks have no persisted local row — the `tracks` table
  /// exists but nothing writes to it, see architecture.md — so this can't
  /// key off a database id. Prefers MusicBrainz's own recording id; falls
  /// back to position, then title, for releases where MusicBrainz has no
  /// recording id at all.
  String get stableKey =>
      recordingMbid ?? (position != null ? 'pos:$position' : 'title:$title');
}

/// One labeled group of tracks for display — a disc side ('Side G'), a
/// disc ('Disc 2'), or unlabeled (`label == null`) for the common case of a
/// single medium with no letter-prefixed track numbers.
typedef TrackGroup = (String? label, List<Track> tracks);

/// Groups [tracks] by disc/side. Tracks must already be sorted by
/// (mediumPosition, position) — see AlbumRepository.getDetails.
///
/// Label rule: the leading letter run of a track's [Track.number] (e.g.
/// 'G1' -> 'Side G') when present; otherwise `'Disc \$mediumPosition'` when
/// more than one medium exists; otherwise no label at all, so an ordinary
/// single-CD album renders as one flat list, same as before this existed.
List<TrackGroup> groupTracksBySide(List<Track> tracks) {
  final mediumCount = tracks.map((t) => t.mediumPosition).toSet().length;
  final groups = <TrackGroup>[];
  String? currentLabel;
  List<Track>? currentTracks;
  for (final track in tracks) {
    final label = _sideLabel(track, mediumCount);
    if (currentTracks == null || label != currentLabel) {
      currentTracks = <Track>[];
      groups.add((label, currentTracks));
      currentLabel = label;
    }
    currentTracks.add(track);
  }
  return groups;
}

String? _sideLabel(Track track, int mediumCount) {
  final letters =
      RegExp(r'^[A-Za-z]+').firstMatch(track.number ?? '')?.group(0);
  if (letters != null && letters.isNotEmpty) return 'Side $letters';
  if (mediumCount > 1) return 'Disc ${track.mediumPosition}';
  return null;
}
