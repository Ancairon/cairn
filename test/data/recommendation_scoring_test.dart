import 'package:test/test.dart';
import 'package:record_reccomend/data/repositories/recommendation_repository.dart';

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
