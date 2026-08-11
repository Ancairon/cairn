import 'package:test/test.dart';
import 'package:cairn/data/repositories/recommendation_repository.dart';

void main() {
  group('pickBestCandidate', () {
    test('picks the candidate with the most genre overlap', () {
      final candidates = [
        _candidate('a1', genres: ['jazz', 'fusion']),
        _candidate('a2', genres: ['jazz', 'bebop', 'hard bop']),
        _candidate('a3', genres: ['ambient']),
      ];
      final best = pickBestCandidate(candidates, seedGenres: ['jazz', 'bebop'], excludeMbids: {});
      expect(best, 'a2');
    });

    test('excludes already-rated albums even if they score highest', () {
      final candidates = [
        _candidate('a1', genres: ['jazz', 'bebop']),
        _candidate('a2', genres: ['jazz']),
      ];
      final best = pickBestCandidate(candidates, seedGenres: ['jazz', 'bebop'], excludeMbids: {'a1'});
      expect(best, 'a2');
    });

    test('skips non-Album primary types', () {
      final candidates = [
        _candidate('a1', genres: ['jazz'], primaryType: 'EP'),
        _candidate('a2', genres: ['jazz']),
      ];
      final best = pickBestCandidate(candidates, seedGenres: ['jazz'], excludeMbids: {});
      expect(best, 'a2');
    });

    test('skips secondary types like Live and Compilation', () {
      final candidates = [
        _candidate('a1', genres: ['jazz'], secondaryTypes: ['Live']),
        _candidate('a2', genres: ['jazz']),
      ];
      final best = pickBestCandidate(candidates, seedGenres: ['jazz'], excludeMbids: {});
      expect(best, 'a2');
    });

    test('returns null when every candidate is excluded or filtered out', () {
      final candidates = [_candidate('a1', genres: ['jazz'])];
      final best = pickBestCandidate(candidates, seedGenres: ['jazz'], excludeMbids: {'a1'});
      expect(best, isNull);
    });
  });

  group('pickRandomExcludingRecent', () {
    test('returns null for an empty candidate list', () {
      final pick = pickRandomExcludingRecent(
        [],
        recentlyUsed: {},
        nextInt: (max) => 0,
      );
      expect(pick, isNull);
    });

    test('falls back to the full pool when every candidate was recently used', () {
      final candidates = ['a1', 'a2', 'a3'];
      final pick = pickRandomExcludingRecent(
        candidates,
        recentlyUsed: {'a1', 'a2', 'a3'},
        nextInt: (max) => 0,
      );
      expect(pick, isNotNull);
      expect(candidates, contains(pick));
    });

    test('only picks from the non-recently-used subset when some are excluded', () {
      // Full list index 0 ('a1') is recently-used; the eligible subset after
      // filtering is ['a2', 'a3'], whose own index 0 ('a2') is NOT
      // recently-used. nextInt always returns 0 — if filtering didn't
      // actually happen, index 0 of the full list ('a1', excluded) could
      // never be returned anyway, so instead assert the eligible-only
      // property directly: the result must never be the recently-used mbid.
      final candidates = ['a1', 'a2', 'a3'];
      final pick = pickRandomExcludingRecent(
        candidates,
        recentlyUsed: {'a1'},
        nextInt: (max) => 0,
      );
      expect(pick, isNot('a1'));
      expect(pick, 'a2');
    });

    test('uses the injected nextInt rather than any hidden randomness', () {
      final candidates = ['a1', 'a2', 'a3'];
      final pick = pickRandomExcludingRecent(
        candidates,
        recentlyUsed: {},
        nextInt: (max) => max - 1,
      );
      expect(pick, 'a3');
    });
  });
}

Map<String, dynamic> _candidate(
  String id, {
  required List<String> genres,
  String primaryType = 'Album',
  List<String> secondaryTypes = const [],
}) {
  return {
    'id': id,
    'primary-type': primaryType,
    'secondary-types': secondaryTypes,
    'genres': genres.map((g) => {'name': g}).toList(),
  };
}
