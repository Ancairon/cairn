class Rating {
  final String albumMbid;
  final int stars;
  final DateTime ratedAt;
  final String? notes;

  Rating({
    required this.albumMbid,
    required this.stars,
    required this.ratedAt,
    this.notes,
  });
}
