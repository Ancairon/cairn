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

/// The three input buttons the rating UI presents — replaces the old 1-5
/// slider (see architecture.md). [value] is what actually gets written to
/// `ratings.stars`; both [like] and [love] are `>= 4`, so they're
/// behaviorally identical to `RecommendationRepository` (both set the
/// anchor) — the distinction is for display/history only.
enum RatingTier {
  dislike(2),
  like(4),
  love(5);

  final int value;
  const RatingTier(this.value);
}

/// Buckets a raw stored `stars` value into one of the three tiers, for
/// display/highlighting. Defensive beyond just {2,4,5}: `<=2` -> dislike,
/// `3` or `4` -> like, `>=5` -> love — a legacy or otherwise-unexpected
/// value still degrades sensibly rather than crashing.
RatingTier ratingTierFor(int stars) {
  if (stars <= 2) return RatingTier.dislike;
  if (stars <= 4) return RatingTier.like;
  return RatingTier.love;
}
