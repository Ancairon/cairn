import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/network/artwork_cache.dart';
import '../../data/remote/coverart_client.dart';
import '../../data/models/album.dart';
import '../../data/models/rating.dart';
import '../../data/models/saved_filter.dart';
import '../../data/repositories/album_repository.dart';
import '../../data/repositories/rating_repository.dart';
import '../../data/repositories/saved_filter_repository.dart';
import '../../data/repositories/settings_repository.dart';

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
  final SettingsRepository settings;
  final Future<void> Function(String albumMbid) onAlbumTap;

  const RatedAlbumsPage({
    super.key,
    required this.ratingRepository,
    required this.albumRepository,
    required this.savedFilterRepository,
    required this.settings,
    required this.onAlbumTap,
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
  bool _gridView = false;
  bool _compactGrid = true;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String? _selectedGenre;
  List<String> _availableGenres = [];
  Map<String, int> _genreCounts = {};
  int _totalRatedCount = 0;

  @override
  void initState() {
    super.initState();
    _restorePreferences();
    _savedFilters = widget.savedFilterRepository.all();
    widget.ratingRepository.addListener(_onRatingsChanged);
    _fetchRows();
  }

  @override
  void dispose() {
    widget.ratingRepository.removeListener(_onRatingsChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onRatingsChanged() {
    if (!mounted) return;
    setState(_fetchRows);
  }

  void _restorePreferences() {
    _sortOption = switch (widget.settings.ratedAlbumsSort()) {
      'artist' => _SortOption.artistAsc,
      'album' => _SortOption.albumAsc,
      _ => _SortOption.newest,
    };
    _gridView = widget.settings.ratedAlbumsView() == 'grid';
    _compactGrid = widget.settings.ratedAlbumsSize() != 'large';
  }

  /// Re-fetches rows for the current filter, then re-applies the current
  /// sort. Called after any change that could affect either — filter
  /// selection, sort selection, or a row edit/removal.
  void _fetchRows() {
    final query = _searchQuery.trim().toLowerCase();
    final baseRows =
        widget.ratingRepository.ratedAlbumsMatching(_selectedFilter?.criteria);
    _totalRatedCount = widget.ratingRepository.ratedAlbumsMatching().length;
    _genreCounts = {};
    for (final row in baseRows) {
      for (final rawGenre in row.$1.genres) {
        final genre = rawGenre.trim();
        if (genre.isEmpty) continue;
        _genreCounts[genre] = (_genreCounts[genre] ?? 0) + 1;
      }
    }
    _availableGenres = _genreCounts.keys.toList()..sort(_compareText);
    _rows = baseRows
        .where((row) => _matchesSearch(row.$1, query) && _matchesGenre(row.$1))
        .toList();
    _sortRows();
  }

  bool _matchesGenre(Album album) {
    final genre = _selectedGenre?.toLowerCase();
    if (genre == null) return true;
    return album.genres.any((item) => item.toLowerCase() == genre);
  }

  bool _matchesSearch(Album album, String query) {
    if (query.isEmpty) return true;
    final haystack = '${album.title} ${album.artistName}'.toLowerCase();
    return query.split(RegExp(r'\s+')).every(haystack.contains);
  }

  void _setSearchQuery(String value) {
    setState(() {
      _searchQuery = value;
      _fetchRows();
    });
  }

  void _sortRows() {
    switch (_sortOption) {
      case _SortOption.newest:
        _rows.sort((a, b) {
          final byDate = b.$2.ratedAt.compareTo(a.$2.ratedAt);
          if (byDate != 0) return byDate;
          return _compareAlbums(a.$1, b.$1);
        });
      case _SortOption.artistAsc:
        _rows.sort((a, b) {
          final byArtist = _compareText(a.$1.artistName, b.$1.artistName);
          if (byArtist != 0) return byArtist;
          // Keep albums by the same artist together and alphabetize within
          // that group instead of preserving the previous fetch order.
          return _compareAlbums(a.$1, b.$1);
        });
      case _SortOption.albumAsc:
        _rows.sort((a, b) {
          final byAlbum = _compareText(a.$1.title, b.$1.title);
          if (byAlbum != 0) return byAlbum;
          return _compareAlbums(a.$1, b.$1);
        });
    }
  }

  int _compareAlbums(Album a, Album b) {
    final byTitle = _compareText(a.title, b.title);
    if (byTitle != 0) return byTitle;
    final byArtist = _compareText(a.artistName, b.artistName);
    if (byArtist != 0) return byArtist;
    return a.mbid.compareTo(b.mbid);
  }

  int _compareText(String a, String b) {
    final byFoldedText = a.toLowerCase().compareTo(b.toLowerCase());
    return byFoldedText != 0 ? byFoldedText : a.compareTo(b);
  }

  void _selectFilter(SavedFilter? filter) {
    setState(() {
      _selectedFilter = filter;
      _fetchRows();
    });
  }

  void _selectGenre(String genre) {
    setState(() {
      _selectedGenre = genre.isEmpty ? null : genre;
      _fetchRows();
    });
  }

  void _setSort(_SortOption option) {
    setState(() {
      _sortOption = option;
      _sortRows();
    });
    widget.settings.setRatedAlbumsSort(switch (option) {
      _SortOption.artistAsc => 'artist',
      _SortOption.albumAsc => 'album',
      _SortOption.newest => 'newest',
    });
  }

  void _toggleView() {
    setState(() => _gridView = !_gridView);
    widget.settings.setRatedAlbumsView(_gridView ? 'grid' : 'list');
  }

  void _toggleSize() {
    setState(() => _compactGrid = !_compactGrid);
    widget.settings.setRatedAlbumsSize(_compactGrid ? 'compact' : 'large');
  }

  void _toggleGridOwnership(int index, {required bool cd}) {
    final (album, rating) = _rows[index];
    final updated = album.copyWith(
      ownsCd: cd ? !album.ownsCd : album.ownsCd,
      ownsVinyl: cd ? album.ownsVinyl : !album.ownsVinyl,
    );
    widget.albumRepository.setOwnership(
      album.mbid,
      ownsCd: cd ? updated.ownsCd : null,
      ownsVinyl: cd ? null : updated.ownsVinyl,
    );
    setState(() => _rows[index] = (updated, rating));
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
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete')),
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
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                children: [
                  Text('Rated albums · ${_rows.length}/$_totalRatedCount',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge),
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    runSpacing: 2,
                    children: [
                      PopupMenuButton<_SortOption>(
                        tooltip: 'Sort',
                        initialValue: _sortOption,
                        onSelected: _setSort,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.sort),
                              SizedBox(width: 4),
                              Text('Sort'),
                            ],
                          ),
                        ),
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                              value: _SortOption.newest,
                              child: Text('Newest rated')),
                          PopupMenuItem(
                              value: _SortOption.artistAsc,
                              child: Text('Artist (A-Z)')),
                          PopupMenuItem(
                              value: _SortOption.albumAsc,
                              child: Text('Album (A-Z)')),
                        ],
                      ),
                      TextButton.icon(
                        icon:
                            Icon(_gridView ? Icons.view_list : Icons.grid_view),
                        label: Text(_gridView ? 'List' : 'Grid'),
                        onPressed: _toggleView,
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.photo_size_select_large),
                        label: Text(_compactGrid ? 'Compact' : 'Large'),
                        onPressed: _toggleSize,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _searchBar(context),
            _filterBar(context),
            const Divider(height: 1),
            Expanded(child: _list(context)),
          ],
        ),
      ),
    );
  }

  Widget _searchBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: TextField(
        controller: _searchController,
        onChanged: _setSearchQuery,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search rated albums',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    _setSearchQuery('');
                  },
                ),
          border: const OutlineInputBorder(),
          isDense: true,
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
          PopupMenuButton<String>(
            tooltip: 'Genre filter',
            onSelected: _selectGenre,
            itemBuilder: (context) => [
              const PopupMenuItem<String>(value: '', child: Text('All genres')),
              ..._availableGenres.map((genre) => PopupMenuItem<String>(
                    value: genre,
                    child: Text('$genre (${_genreCounts[genre]})'),
                  )),
            ],
            child: Chip(
              avatar: const Icon(Icons.local_offer_outlined, size: 18),
              label: Text(_selectedGenre ?? 'Genre'),
            ),
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
    if (_gridView) return _grid(context);
    return ListView.separated(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: _rows.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final (album, rating) = _rows[index];
        final artworkSize = _compactGrid ? 56.0 : 88.0;
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
            leading: _albumArtwork(context, album, size: artworkSize),
            onTap: () => _openAlbum(album),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(album.artistName,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                _ownershipRatingRow(context, album, rating, index),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _grid(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _compactGrid ? 150 : 240,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        // Reserve enough height for a square artwork tile plus its metadata.
        // The artwork itself stays 1:1 in both size modes.
        childAspectRatio: _compactGrid ? .64 : .70,
      ),
      itemCount: _rows.length,
      itemBuilder: (context, index) {
        final (album, rating) = _rows[index];
        return Card(
          color: colors.primaryContainer,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _openAlbum(album),
            onLongPress: () => _confirmRowAction(album, rating),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: _albumArtwork(context, album),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
                  child: Text(album.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                  child: Text(album.artistName,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
                  child: _ownershipRatingRow(context, album, rating, index),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openAlbum(Album album) async {
    Navigator.of(context).pop();
    await widget.onAlbumTap(album.mbid);
  }

  Widget _albumArtwork(BuildContext context, Album album, {double? size}) {
    final placeholder = _artworkPlaceholder(context, album, size: size);
    final image = album.coverArtUrl;
    final thumbnail = image == null
        ? CoverArtClient.releaseGroupThumbnailUrl(album.mbid, size: 250)
        : _smallArtworkUrl(image);
    final child = CachedNetworkImage(
      imageUrl: thumbnail,
      cacheManager: ArtworkCache.manager,
      fit: BoxFit.cover,
      placeholder: (context, url) => placeholder,
      errorWidget: (context, url, error) => placeholder,
    );
    return size == null
        ? AspectRatio(aspectRatio: 1, child: child)
        : SizedBox(width: size, height: size, child: child);
  }

  String _smallArtworkUrl(String url) =>
      url.replaceFirst('front-500', 'front-250');

  Widget _artworkPlaceholder(BuildContext context, Album album,
      {double? size}) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      color: colors.secondaryContainer,
      alignment: Alignment.center,
      child: Icon(Icons.album,
          size: size == null ? 48 : size * .42,
          color: colors.onSecondaryContainer),
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
        content: Text(
            'Remove your rating for "${album.title}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove')),
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
    widget.albumRepository
        .setOwnership(album.mbid, ownsCd: ownsCd, ownsVinyl: ownsVinyl);
    widget.ratingRepository.rate(album.mbid, stars);
    setState(_fetchRows);
  }

  Widget _ownershipRatingRow(
      BuildContext context, Album album, Rating rating, int index) {
    final primary = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        if (album.ownsCd)
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: 'CD',
              iconSize: 18,
              color: primary,
              icon: const Icon(Icons.album),
              onPressed: () => _toggleGridOwnership(index, cd: true),
            ),
          ),
        if (album.ownsVinyl)
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: 'Vinyl',
              iconSize: 18,
              color: primary,
              icon: const Icon(Icons.album_outlined),
              onPressed: () => _toggleGridOwnership(index, cd: false),
            ),
          ),
        const Spacer(),
        Text('${rating.stars}/5'),
      ],
    );
  }
}

/// Shows the create/edit form for a saved filter. Returns (name, criteria)
/// on save, or null if the dialog was dismissed without saving.
Future<(String, FilterCriteria)?> _showSavedFilterForm(BuildContext context,
    {SavedFilter? existing}) {
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
      FilterCriteria(
          ownership: _ownership, minRating: _minRating, maxRating: _maxRating),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
          widget.existing == null ? 'New saved filter' : 'Edit saved filter'),
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
                  .map((entry) => DropdownMenuItem(
                      value: entry.key, child: Text(entry.value)))
                  .toList(),
              onChanged: (value) => setState(() => _ownership = value),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int?>(
              initialValue: _minRating,
              decoration: const InputDecoration(labelText: 'Minimum rating'),
              items: [null, 1, 2, 3, 4, 5]
                  .map((value) => DropdownMenuItem(
                      value: value,
                      child: Text(value == null ? 'Any' : '$value/5')))
                  .toList(),
              onChanged: (value) => setState(() => _minRating = value),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int?>(
              initialValue: _maxRating,
              decoration: const InputDecoration(labelText: 'Maximum rating'),
              items: [null, 1, 2, 3, 4, 5]
                  .map((value) => DropdownMenuItem(
                      value: value,
                      child: Text(value == null ? 'Any' : '$value/5')))
                  .toList(),
              onChanged: (value) => setState(() => _maxRating = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
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
              'Rating: ${_stars.round()}/5',
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
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop((_ownsCd, _ownsVinyl, _stars.round())),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
