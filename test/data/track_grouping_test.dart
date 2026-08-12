import 'package:test/test.dart';
import 'package:cairn/data/models/track.dart';

Track _track(
    {String? number, int mediumPosition = 1, int? position, String title = 't'}) {
  return Track(
    albumMbid: 'album-1',
    title: title,
    number: number,
    mediumPosition: mediumPosition,
    position: position,
  );
}

void main() {
  test('a single medium with no letter prefixes groups as one unlabeled list',
      () {
    final tracks = [
      _track(number: '1', position: 1),
      _track(number: '2', position: 2),
    ];
    final groups = groupTracksBySide(tracks);
    expect(groups, hasLength(1));
    expect(groups.first.$1, isNull);
    expect(groups.first.$2, tracks);
  });

  test('groups standard vinyl A/B sides by their letter prefix', () {
    final tracks = [
      _track(number: 'A1', position: 1),
      _track(number: 'A2', position: 2),
      _track(number: 'B1', position: 3),
      _track(number: 'B2', position: 4),
    ];
    final groups = groupTracksBySide(tracks);
    expect(groups.map((g) => g.$1), ['Side A', 'Side B']);
    expect(groups[0].$2.map((t) => t.number), ['A1', 'A2']);
    expect(groups[1].$2.map((t) => t.number), ['B1', 'B2']);
  });

  test('groups non-standard side letters as-is, e.g. G/R', () {
    final tracks = [
      _track(number: 'G1', position: 1),
      _track(number: 'G2', position: 2),
      _track(number: 'R1', position: 3),
    ];
    final groups = groupTracksBySide(tracks);
    expect(groups.map((g) => g.$1), ['Side G', 'Side R']);
  });

  test('a genuine multi-disc release with no letters groups by disc number',
      () {
    final tracks = [
      _track(number: '1', mediumPosition: 1, position: 1),
      _track(number: '2', mediumPosition: 1, position: 2),
      _track(number: '1', mediumPosition: 2, position: 1),
    ];
    final groups = groupTracksBySide(tracks);
    expect(groups.map((g) => g.$1), ['Disc 1', 'Disc 2']);
  });

  test('a track with no number at all is treated as unlettered', () {
    final tracks = [_track(number: null, position: 1)];
    final groups = groupTracksBySide(tracks);
    expect(groups.single.$1, isNull);
  });
}
