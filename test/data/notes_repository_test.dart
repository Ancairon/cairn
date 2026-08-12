import 'package:test/test.dart';
import 'package:cairn/core/db/app_database.dart';
import 'package:cairn/data/repositories/notes_repository.dart';

void main() {
  test('round-trips an album note, independent of any rating', () {
    final db = AppDatabase.memory();
    final notes = NotesRepository(db);
    const albumMbid = 'album-1';

    expect(notes.albumNote(albumMbid), isNull);

    notes.setAlbumNote(albumMbid, 'A late-night favorite.');
    expect(notes.albumNote(albumMbid), 'A late-night favorite.');

    notes.setAlbumNote(albumMbid, 'Updated thoughts.');
    expect(notes.albumNote(albumMbid), 'Updated thoughts.');

    notes.deleteAlbumNote(albumMbid);
    expect(notes.albumNote(albumMbid), isNull);

    db.close();
  });

  test('writing an empty/blank album note deletes it instead of storing blank', () {
    final db = AppDatabase.memory();
    final notes = NotesRepository(db);
    const albumMbid = 'album-1';

    notes.setAlbumNote(albumMbid, 'Something');
    notes.setAlbumNote(albumMbid, '   ');
    expect(notes.albumNote(albumMbid), isNull);

    db.close();
  });

  test('round-trips per-track notes keyed independently within an album', () {
    final db = AppDatabase.memory();
    final notes = NotesRepository(db);
    const albumMbid = 'album-1';

    expect(notes.trackNotes(albumMbid), isEmpty);

    notes.setTrackNote(albumMbid, 'recording-mbid-1', 'Great opener.');
    notes.setTrackNote(albumMbid, 'pos:2', 'Weaker bridge.');

    expect(notes.trackNotes(albumMbid), {
      'recording-mbid-1': 'Great opener.',
      'pos:2': 'Weaker bridge.',
    });

    notes.deleteTrackNote(albumMbid, 'recording-mbid-1');
    expect(notes.trackNotes(albumMbid), {'pos:2': 'Weaker bridge.'});

    db.close();
  });

  test('albumMbidsWithAnyNote reports albums with an album note, a track note, or both', () {
    final db = AppDatabase.memory();
    final notes = NotesRepository(db);

    expect(notes.albumMbidsWithAnyNote(), isEmpty);

    notes.setAlbumNote('album-with-album-note', 'Great record.');
    notes.setTrackNote('album-with-track-note', 'pos:1', 'Nice riff.');
    notes.setAlbumNote('album-with-both', 'Overall thoughts.');
    notes.setTrackNote('album-with-both', 'pos:3', 'Standout track.');

    expect(
      notes.albumMbidsWithAnyNote(),
      {'album-with-album-note', 'album-with-track-note', 'album-with-both'},
    );

    db.close();
  });

  test('track notes are scoped per album, not global', () {
    final db = AppDatabase.memory();
    final notes = NotesRepository(db);

    notes.setTrackNote('album-1', 'pos:1', 'Note on album 1 track 1.');
    notes.setTrackNote('album-2', 'pos:1', 'Note on album 2 track 1.');

    expect(notes.trackNotes('album-1'), {'pos:1': 'Note on album 1 track 1.'});
    expect(notes.trackNotes('album-2'), {'pos:1': 'Note on album 2 track 1.'});

    db.close();
  });
}
