import 'album.dart';
import 'track.dart';

/// The small, album-focused set of facts shown by the details sheet.
class AlbumDetails {
  final Album album;
  final List<Track> tracks;
  final List<String> members;

  const AlbumDetails({
    required this.album,
    required this.tracks,
    this.members = const [],
  });
}
