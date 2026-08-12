import 'package:test/test.dart';
import 'package:cairn/data/models/rating.dart';

void main() {
  test('tier values are the canonical stored ratings', () {
    expect(RatingTier.dislike.value, 2);
    expect(RatingTier.like.value, 4);
    expect(RatingTier.love.value, 5);
  });

  group('ratingTierFor', () {
    test('1 and 2 are dislike', () {
      expect(ratingTierFor(1), RatingTier.dislike);
      expect(ratingTierFor(2), RatingTier.dislike);
    });

    test('3 and 4 are like', () {
      expect(ratingTierFor(3), RatingTier.like);
      expect(ratingTierFor(4), RatingTier.like);
    });

    test('5 (and anything above) is love', () {
      expect(ratingTierFor(5), RatingTier.love);
      expect(ratingTierFor(6), RatingTier.love);
    });

    test('non-positive values degrade to dislike rather than throwing', () {
      expect(ratingTierFor(0), RatingTier.dislike);
      expect(ratingTierFor(-1), RatingTier.dislike);
    });
  });
}
