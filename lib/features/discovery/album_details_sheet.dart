import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/models/album.dart';
import '../../data/models/album_details.dart';
import '../../data/models/track.dart';
import '../../data/repositories/notes_repository.dart';

/// The album details bottom sheet: metadata, a collapsible album-wide
/// comment, and a track list where tapping a track reveals an inline
/// comment box for that track. A `StatefulWidget` (rather than the plain
/// builder this used to be) because per-track expansion and text editing
/// need real local state.
class AlbumDetailsSheet extends StatefulWidget {
  final Album album;
  final Future<AlbumDetails> detailsFuture;
  final NotesRepository notes;

  const AlbumDetailsSheet({
    super.key,
    required this.album,
    required this.detailsFuture,
    required this.notes,
  });

  @override
  State<AlbumDetailsSheet> createState() => _AlbumDetailsSheetState();
}

class _AlbumDetailsSheetState extends State<AlbumDetailsSheet> {
  late final TextEditingController _albumNoteController;
  // Whether the note section is expanded is a tap toggle ORed with "has
  // text" — a note with text is always shown open (can't be tapped shut
  // while it still has content); tapping only matters to open an empty one
  // to start writing, or to close one after its text has been cleared.
  bool _albumNoteManuallyOpened = false;
  late Map<String, String> _trackNotes;
  final Set<String> _manuallyOpenedTrackKeys = {};
  final Map<String, TextEditingController> _trackNoteControllers = {};

  // Long-press-to-delete on a comment box uses a Listener (below), not
  // GestureDetector.onLongPress — a TextField already has its own internal
  // long-press recognizer for text selection, and stacking a second
  // long-press GestureDetector on top of it competes for the same pointer
  // in Flutter's gesture arena (the same class of bug this project already
  // hit and fixed for drag gestures — see project-gesture-arena skill).
  // Listener never enters that arena, so text selection keeps working.
  Timer? _longPressTimer;

  @override
  void initState() {
    super.initState();
    final albumMbid = widget.album.mbid;
    _albumNoteController =
        TextEditingController(text: widget.notes.albumNote(albumMbid) ?? '');
    _trackNotes = widget.notes.trackNotes(albumMbid);
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _albumNoteController.dispose();
    for (final controller in _trackNoteControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _trackControllerFor(String key) {
    return _trackNoteControllers.putIfAbsent(
        key, () => TextEditingController(text: _trackNotes[key] ?? ''));
  }

  void _saveAlbumNote(String text) {
    widget.notes.setAlbumNote(widget.album.mbid, text);
  }

  void _saveTrackNote(String key, String text) {
    setState(() {
      if (text.trim().isEmpty) {
        _trackNotes.remove(key);
      } else {
        _trackNotes[key] = text;
      }
    });
    widget.notes.setTrackNote(widget.album.mbid, key, text);
  }

  void _armLongPress(VoidCallback onLongPress) {
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 500), onLongPress);
  }

  void _cancelLongPress() => _longPressTimer?.cancel();

  Future<void> _confirmDeleteAlbumNote() async {
    final confirmed = await _confirmDelete();
    if (confirmed == true) {
      setState(() => _albumNoteController.clear());
      widget.notes.deleteAlbumNote(widget.album.mbid);
    }
  }

  Future<void> _confirmDeleteTrackNote(String key) async {
    final confirmed = await _confirmDelete();
    if (confirmed == true) {
      setState(() {
        _trackControllerFor(key).clear();
        _trackNotes.remove(key);
      });
      widget.notes.deleteTrackNote(widget.album.mbid, key);
    }
  }

  Future<bool?> _confirmDelete() {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete comment?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        builder: (context, scrollController) {
          return FutureBuilder<AlbumDetails>(
            future: widget.detailsFuture,
            builder: (context, snapshot) {
              final details = snapshot.data;
              return ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                children: [
                  Text(widget.album.title,
                      style: Theme.of(context).textTheme.headlineSmall),
                  Text(widget.album.artistName,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text([
                    if (widget.album.firstReleaseYear != null)
                      '${widget.album.firstReleaseYear}',
                    if (widget.album.genres.isNotEmpty)
                      widget.album.genres.join(' · '),
                  ].join('  ·  ')),
                  if (details != null && details.members.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('Members',
                        style: Theme.of(context).textTheme.titleMedium),
                    Text(details.members.join(' · ')),
                  ],
                  const Divider(height: 28),
                  _buildAlbumNoteSection(context),
                  const SizedBox(height: 16),
                  if (snapshot.connectionState == ConnectionState.waiting)
                    const Center(child: CircularProgressIndicator())
                  else if (snapshot.hasError)
                    Text('Track listing unavailable: ${snapshot.error}')
                  else if (details == null || details.tracks.isEmpty)
                    const Text('No track listing available.')
                  else ...[
                    Text('Tracks',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    for (final (label, groupTracks)
                        in groupTracksBySide(details.tracks)) ...[
                      if (label != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 2),
                          child: Text(label,
                              style: Theme.of(context).textTheme.titleSmall),
                        ),
                      ...groupTracks.map((track) => _buildTrackRow(context, track)),
                    ],
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildAlbumNoteSection(BuildContext context) {
    final hasNote = _albumNoteController.text.isNotEmpty;
    final expanded = _albumNoteManuallyOpened || hasNote;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(
              () => _albumNoteManuallyOpened = !_albumNoteManuallyOpened),
          child: Row(
            children: [
              Icon(
                hasNote ? Icons.sticky_note_2 : Icons.sticky_note_2_outlined,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text('Notes', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
        if (expanded) ...[
          const SizedBox(height: 8),
          Listener(
            onPointerDown: (_) =>
                _armLongPress(_confirmDeleteAlbumNote),
            onPointerMove: (event) {
              if (event.delta.distance > 4) _cancelLongPress();
            },
            onPointerUp: (_) => _cancelLongPress(),
            onPointerCancel: (_) => _cancelLongPress(),
            child: TextField(
              controller: _albumNoteController,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(
                hintText: 'Write a note about this album…',
                border: InputBorder.none,
              ),
              onChanged: (text) {
                setState(() {});
                _saveAlbumNote(text);
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTrackRow(BuildContext context, Track track) {
    final key = track.stableKey;
    final hasNote = (_trackNotes[key] ?? '').isNotEmpty;
    final expanded = _manuallyOpenedTrackKeys.contains(key) || hasNote;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (_manuallyOpenedTrackKeys.contains(key)) {
              _manuallyOpenedTrackKeys.remove(key);
            } else {
              _manuallyOpenedTrackKeys.add(key);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text('${track.position ?? ''}',
                      textAlign: TextAlign.center),
                ),
                Expanded(child: Text(track.title)),
                if (hasNote)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(Icons.sticky_note_2,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary),
                  ),
                if (track.durationMs != null)
                  Text(_formatDuration(track.durationMs!)),
              ],
            ),
          ),
        ),
        if (expanded) ...[
          Padding(
            padding: const EdgeInsets.only(left: 28, bottom: 8),
            child: Listener(
              onPointerDown: (_) =>
                  _armLongPress(() => _confirmDeleteTrackNote(key)),
              onPointerMove: (event) {
                if (event.delta.distance > 4) _cancelLongPress();
              },
              onPointerUp: (_) => _cancelLongPress(),
              onPointerCancel: (_) => _cancelLongPress(),
              child: TextField(
                controller: _trackControllerFor(key),
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Add a comment…',
                  border: InputBorder.none,
                  isDense: true,
                ),
                onChanged: (text) => _saveTrackNote(key, text),
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _formatDuration(int durationMs) {
    final totalSeconds = (durationMs / 1000).round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
