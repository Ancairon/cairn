import 'package:test/test.dart';
import 'package:cairn/core/db/app_database.dart';
import 'package:cairn/data/repositories/rating_repository.dart';

void main() {
  test('rate() without notes preserves an existing note instead of wiping it',
      () {
    final database = AppDatabase.memory();
    final ratings = RatingRepository(database);

    ratings.rate('a1', 5, notes: 'loved the b-side');
    // The ordinary tier-rating flow re-rates without ever passing notes.
    ratings.rate('a1', 4);

    expect(ratings.ratingFor('a1')?.stars, 4);
    expect(ratings.ratingFor('a1')?.notes, 'loved the b-side');

    database.close();
  });

  test('rate() with an explicit new note still overwrites the old one', () {
    final database = AppDatabase.memory();
    final ratings = RatingRepository(database);

    ratings.rate('a1', 5, notes: 'old note');
    ratings.rate('a1', 5, notes: 'new note');

    expect(ratings.ratingFor('a1')?.notes, 'new note');

    database.close();
  });
}
