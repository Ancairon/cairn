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
