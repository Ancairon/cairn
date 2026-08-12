class Album {
  final String mbid;
  final String? representativeReleaseMbid;
  final String title;
  final String artistName;
  final String? artistMbid;
  final int? firstReleaseYear;
  final List<String> genres;
  final String? coverArtUrl;
  final bool ownsCd;
  final bool ownsVinyl;

  Album({
    required this.mbid,
    required this.title,
    required this.artistName,
    this.representativeReleaseMbid,
    this.artistMbid,
    this.firstReleaseYear,
    this.genres = const [],
    this.coverArtUrl,
    this.ownsCd = false,
    this.ownsVinyl = false,
  });

  /// MusicBrainz wraps a whole title in square brackets specifically to
  /// mark it as a descriptive placeholder, not the release's real printed
  /// title (e.g. Led Zeppelin's fourth album, which has no printed title at
  /// all, is titled `[Led Zeppelin IV]`, verified live against MusicBrainz).
  /// This is display noise for a discovery app, not useful signal — strip
  /// just the outer brackets, keep the text. Only applies when the *whole*
  /// trimmed title is bracketed, so a title that merely contains brackets
  /// somewhere inside (a real edition/suffix annotation) is left alone.
  static String stripOuterBrackets(String title) {
    final trimmed = title.trim();
    if (trimmed.length > 1 &&
        trimmed.startsWith('[') &&
        trimmed.endsWith(']')) {
      return trimmed.substring(1, trimmed.length - 1).trim();
    }
    return title;
  }

  Album copyWith({bool? ownsCd, bool? ownsVinyl}) {
    return Album(
      mbid: mbid,
      title: title,
      artistName: artistName,
      representativeReleaseMbid: representativeReleaseMbid,
      artistMbid: artistMbid,
      firstReleaseYear: firstReleaseYear,
      genres: genres,
      coverArtUrl: coverArtUrl,
      ownsCd: ownsCd ?? this.ownsCd,
      ownsVinyl: ownsVinyl ?? this.ownsVinyl,
    );
  }
}
