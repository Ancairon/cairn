import 'package:flutter/material.dart';
import '../../data/models/album.dart';
import '../../data/models/rating.dart';
import '../../data/models/saved_filter.dart';
import '../../data/repositories/album_repository.dart';
import '../../data/repositories/rating_repository.dart';
import '../../data/repositories/saved_filter_repository.dart';

/// Client-side sort applied to the already-fetched rows — no need to push
/// this into SQL, `ratedAlbumsMatching()` already returns everything a sort
/// needs (`Rating.ratedAt`, `Album.artistName`, `Album.title`).
enum _SortOption { newest, artistAsc, albumAsc }

/// Journal/history page — every rated album, newest first, narrowed by an
/// optional saved filter. Pushed onto the discovery screen's background
/// menu Navigator, same page style as `_GenrePickerPage` there: a Material
/// surface, SafeArea, and a back-button + title header.
class RatedAlbumsPage extends StatefulWidget {
  final RatingRepository ratingRepository;
  final AlbumRepository albumRepository;
  final SavedFilterRepository savedFilterRepository;

  const RatedAlbumsPage({
    super.key,
    required this.ratingRepository,
    required this.albumRepository,
    required this.savedFilterRepository,
  });

  @override
  State<RatedAlbumsPage> createState() => _RatedAlbumsPageState();
}

class _RatedAlbumsPageState extends State<RatedAlbumsPage> {
  List<SavedFilter> _savedFilters = [];
  // null selection means "All" — no criteria, every rated album.
  SavedFilter? _selectedFilter;
  List<(Album, Rating)> _rows = [];
  _SortOption _sortOption = _SortOption.newest;

  @override
  void initState() {
    super.initState();
    _savedFilters = widget.savedFilterRepository.all();
    _fetchRows();
  }

  /// Re-fetches rows for the current filter, then re-applies the current
  /// sort. Called after any change that could affect either — filter
  /// selection, sort selection, or a row edit/removal.
  void _fetchRows() {
    _rows = widget.ratingRepository.ratedAlbumsMatching(_selectedFilter?.criteria);
    _sortRows();
  }

  void _sortRows() {
    switch (_sortOption) {
      case _SortOption.newest:
        _rows.sort((a, b) => b.$2.ratedAt.compareTo(a.$2.ratedAt));
      case _SortOption.artistAsc:
        _rows.sort((a, b) => a.$1.artistName.compareTo(b.$1.artistName));
      case _SortOption.albumAsc:
        _rows.sort((a, b) => a.$1.title.compareTo(b.$1.title));
    }
  }

  void _selectFilter(SavedFilter? filter) {
    setState(() {
      _selectedFilter = filter;
      _fetchRows();
    });
  }

  void _setSort(_SortOption option) {
    setState(() {
      _sortOption = option;
      _sortRows();
    });
  }

  Future<void> _addFilter() async {
    final result = await _showSavedFilterForm(context);
    if (result == null) return;
    widget.savedFilterRepository.create(result.$1, result.$2);
    setState(() => _savedFilters = widget.savedFilterRepository.all());
  }

  Future<void> _editFilter(SavedFilter filter) async {
    final result = await _showSavedFilterForm(context, existing: filter);
    if (result == null) return;
    widget.savedFilterRepository.update(filter.id!, result.$1, result.$2);
    setState(() => _savedFilters = widget.savedFilterRepository.all());
    if (_selectedFilter?.id == filter.id) {
      _selectFilter(_savedFilters.firstWhere((f) => f.id == filter.id));
    }
  }

  Future<void> _deleteFilter(SavedFilter filter) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete filter?'),
        content: Text('Delete "${filter.name}"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    widget.savedFilterRepository.delete(filter.id!);
    setState(() => _savedFilters = widget.savedFilterRepository.all());
    if (_selectedFilter?.id == filter.id) {
      _selectFilter(null);
    }
  }

  Future<void> _showFilterActions(SavedFilter filter) async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(filter.name),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('edit'),
            child: const Text('Edit'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('delete'),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (action == 'edit') {
      await _editFilter(filter);
    } else if (action == 'delete') {
      await _deleteFilter(filter);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Text('Rated albums', style: Theme.of(context).textTheme.titleLarge),
                  ),
                  PopupMenuButton<_SortOption>(
                    icon: const Icon(Icons.sort),
                    tooltip: 'Sort',
                    initialValue: _sortOption,
                    onSelected: _setSort,
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: _SortOption.newest, child: Text('Newest rated')),
                      PopupMenuItem(value: _SortOption.artistAsc, child: Text('Artist (A-Z)')),
                      PopupMenuItem(value: _SortOption.albumAsc, child: Text('Album (A-Z)')),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _filterBar(context),
            const Divider(height: 1),
            Expanded(child: _list(context)),
          ],
        ),
      ),
    );
  }

  Widget _filterBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: const Text('All'),
                      selected: _selectedFilter == null,
                      onSelected: (_) => _selectFilter(null),
                    ),
                  ),
                  for (final filter in _savedFilters)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onLongPress: () => _showFilterActions(filter),
                        child: ChoiceChip(
                          label: Text(filter.name),
                          selected: _selectedFilter?.id == filter.id,
                          onSelected: (_) => _selectFilter(filter),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'New saved filter',
            onPressed: _addFilter,
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    if (_rows.isEmpty) {
      return Center(
        child: Text(
          'No rated albums yet.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: _rows.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final (album, rating) = _rows[index];
        // `confirmDismiss` always returns false below — the swipe itself
        // never removes the row from the list. It's only used as the
        // trigger gesture for a small "which action?" prompt; the actual
        // remove/edit is handled explicitly and refreshes `_rows` itself.
        return Dismissible(
          key: ValueKey(album.mbid),
          direction: DismissDirection.endToStart,
          background: _swipeActionsPreview(context),
          confirmDismiss: (_) => _confirmRowAction(album, rating),
          child: ListTile(
            title: Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${album.artistName} · ${album.firstReleaseYear ?? 'unknown year'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _ratingTrailing(context, album, rating),
          ),
        );
      },
    );
  }

  Widget _swipeActionsPreview(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      color: colors.errorContainer,
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit, color: colors.onErrorContainer),
          const SizedBox(width: 24),
          Icon(Icons.delete, color: colors.onErrorContainer),
        ],
      ),
    );
  }

  /// Shown once a left-swipe passes Dismissible's own threshold. Same
  /// SimpleDialog pattern as `_showFilterActions` above, just with
  /// different labels/actions for a rated-album row.
  Future<bool> _confirmRowAction(Album album, Rating rating) async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(album.title),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('edit'),
            child: const Text('Edit'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('remove'),
            child: const Text('Remove rating'),
          ),
        ],
      ),
    );
    if (action == 'edit') {
      await _editRow(album, rating);
    } else if (action == 'remove') {
      await _removeRow(album);
    }
    return false;
  }

  Future<void> _removeRow(Album album) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove rating?'),
        content: Text('Remove your rating for "${album.title}"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    widget.ratingRepository.deleteRating(album.mbid);
    setState(_fetchRows);
  }

  Future<void> _editRow(Album album, Rating rating) async {
    final result = await showDialog<(bool, bool, int)>(
      context: context,
      builder: (context) => _EditRatingDialog(album: album, rating: rating),
    );
    if (result == null) return;
    final (ownsCd, ownsVinyl, stars) = result;
    widget.albumRepository.setOwnership(album.mbid, ownsCd: ownsCd, ownsVinyl: ownsVinyl);
    widget.ratingRepository.rate(album.mbid, stars);
    setState(_fetchRows);
  }

  Widget _ratingTrailing(BuildContext context, Album album, Rating rating) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (album.ownsCd) Icon(Icons.album, size: 16, color: colors.onSurfaceVariant),
        if (album.ownsVinyl)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Icon(Icons.album_outlined, size: 16, color: colors.onSurfaceVariant),
          ),
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Text(_starsText(rating.stars)),
        ),
      ],
    );
  }

  String _starsText(int stars) => '★' * stars + '☆' * (5 - stars);
}

/// Shows the create/edit form for a saved filter. Returns (name, criteria)
/// on save, or null if the dialog was dismissed without saving.
Future<(String, FilterCriteria)?> _showSavedFilterForm(BuildContext context, {SavedFilter? existing}) {
  return showDialog<(String, FilterCriteria)>(
    context: context,
    builder: (context) => _SavedFilterFormDialog(existing: existing),
  );
}

class _SavedFilterFormDialog extends StatefulWidget {
  final SavedFilter? existing;

  const _SavedFilterFormDialog({this.existing});

  @override
  State<_SavedFilterFormDialog> createState() => _SavedFilterFormDialogState();
}

class _SavedFilterFormDialogState extends State<_SavedFilterFormDialog> {
  late final TextEditingController _nameController =
      TextEditingController(text: widget.existing?.name ?? '');
  String? _ownership;
  int? _minRating;
  int? _maxRating;

  static const _ownershipLabels = {
    null: 'Any',
    'cd': 'Owns CD',
    'vinyl': 'Owns vinyl',
    'either': 'Owns either',
    'both': 'Owns both',
  };

  @override
  void initState() {
    super.initState();
    final criteria = widget.existing?.criteria;
    _ownership = criteria?.ownership;
    _minRating = criteria?.minRating;
    _maxRating = criteria?.maxRating;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop((
      name,
      FilterCriteria(ownership: _ownership, minRating: _minRating, maxRating: _maxRating),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New saved filter' : 'Edit saved filter'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Name'),
              autofocus: true,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String?>(
              initialValue: _ownership,
              decoration: const InputDecoration(labelText: 'Ownership'),
              items: _ownershipLabels.entries
                  .map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.value)))
                  .toList(),
              onChanged: (value) => setState(() => _ownership = value),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int?>(
              initialValue: _minRating,
              decoration: const InputDecoration(labelText: 'Minimum rating'),
              items: [null, 1, 2, 3, 4, 5]
                  .map((value) => DropdownMenuItem(value: value, child: Text(value == null ? 'Any' : '$value stars')))
                  .toList(),
              onChanged: (value) => setState(() => _minRating = value),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int?>(
              initialValue: _maxRating,
              decoration: const InputDecoration(labelText: 'Maximum rating'),
              items: [null, 1, 2, 3, 4, 5]
                  .map((value) => DropdownMenuItem(value: value, child: Text(value == null ? 'Any' : '$value stars')))
                  .toList(),
              onChanged: (value) => setState(() => _maxRating = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// Compact edit form for a single rated-album row — ownership chips plus a
/// 1-5 rating slider, same visual convention as the discovery screen's own
/// ownership chips/rating slider. Returns (ownsCd, ownsVinyl, stars) on
/// save, or null if dismissed without saving.
class _EditRatingDialog extends StatefulWidget {
  final Album album;
  final Rating rating;

  const _EditRatingDialog({required this.album, required this.rating});

  @override
  State<_EditRatingDialog> createState() => _EditRatingDialogState();
}

class _EditRatingDialogState extends State<_EditRatingDialog> {
  late bool _ownsCd = widget.album.ownsCd;
  late bool _ownsVinyl = widget.album.ownsVinyl;
  late double _stars = widget.rating.stars.toDouble();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.album.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 8,
              children: [
                FilterChip(
                  label: const Text('CD'),
                  avatar: const Icon(Icons.album, size: 18),
                  selected: _ownsCd,
                  onSelected: (value) => setState(() => _ownsCd = value),
                ),
                FilterChip(
                  label: const Text('Vinyl'),
                  avatar: const Icon(Icons.album_outlined, size: 18),
                  selected: _ownsVinyl,
                  onSelected: (value) => setState(() => _ownsVinyl = value),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Rating: ${_stars.round()} star${_stars.round() == 1 ? '' : 's'}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: _stars,
                min: 1,
                max: 5,
                divisions: 4,
                label: '${_stars.round()}',
                onChanged: (value) => setState(() => _stars = value),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((_ownsCd, _ownsVinyl, _stars.round())),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
