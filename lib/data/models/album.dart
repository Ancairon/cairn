class Album {
  final String mbid;
  final String? representativeReleaseMbid;
  final String title;
  final String artistName;
  final String? artistMbid;
  final int? firstReleaseYear;
  final List<String> genres;
  final String? coverArtUrl;

  Album({
    required this.mbid,
    required this.title,
    required this.artistName,
    this.representativeReleaseMbid,
    this.artistMbid,
    this.firstReleaseYear,
    this.genres = const [],
    this.coverArtUrl,
  });
}
