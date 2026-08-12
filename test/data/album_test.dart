import 'package:test/test.dart';
import 'package:cairn/data/models/album.dart';

void main() {
  group('Album.stripOuterBrackets', () {
    test('strips brackets wrapping the whole title', () {
      // MusicBrainz's real canonical title for the album with no printed
      // title at all — verified live against MusicBrainz during design.
      expect(Album.stripOuterBrackets('[Led Zeppelin IV]'), 'Led Zeppelin IV');
    });

    test('leaves a title with brackets only inside it alone', () {
      expect(Album.stripOuterBrackets('Album Name [Deluxe Edition]'),
          'Album Name [Deluxe Edition]');
    });

    test('leaves a plain title with no brackets alone', () {
      expect(Album.stripOuterBrackets('Abbey Road'), 'Abbey Road');
    });

    test('trims surrounding whitespace when stripping', () {
      expect(Album.stripOuterBrackets('  [Untitled]  '), 'Untitled');
    });
  });
}
