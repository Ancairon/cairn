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
import '../../data/repositories/notes_repository.dart';

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
  final NotesRepository notes;
  final Future<void> Function(String albumMbid) onAlbumTap;

  const RatedAlbumsPage({
    super.key,
    required this.ratingRepository,
    required this.albumRepository,
    required this.savedFilterRepository,
    required this.settings,
    required this.notes,
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
  Set<String> _albumsWithNotes = {};

  @override
  void initState() {
    super.initState();
    _restorePreferences();
    _savedFilters = widget.savedFilterRepository.all();
    widget.ratingRepository.addListener(_onRatingsChanged);
    _albumsWithNotes = widget.notes.albumMbidsWithAnyNote();
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
          // Within the same artist, chronological (oldest first) rather
          // than alphabetical by title — matches how a discography is
          // actually browsed, not a dictionary ordering of album names.
          final byYear = _compareReleaseYear(a.$1, b.$1);
          if (byYear != 0) return byYear;
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

  // Unknown release years sort last — safer than guessing they're either
  // the oldest or newest in the group.
  int _compareReleaseYear(Album a, Album b) {
    final ay = a.firstReleaseYear;
    final by = b.firstReleaseYear;
    if (ay == null && by == null) return 0;
    if (ay == null) return 1;
    if (by == null) return -1;
    return ay.compareTo(by);
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
        // never removes the row from the list. It's only the trigger
        // gesture for the remove-rating confirmation; tapping the row is
        // "edit" (loads the album onto the main card), so swipe unambiguously
        // means remove. The actual removal is handled explicitly by
        // `_removeRow` and refreshes `_rows` itself.
        return Dismissible(
          key: ValueKey(album.mbid),
          direction: DismissDirection.endToStart,
          background: _swipeActionsPreview(context),
          confirmDismiss: (_) async {
            await _removeRow(album);
            return false;
          },
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
            onLongPress: () => _removeRow(album),
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

  // Deliberately does not pop this page off the menu's nested Navigator —
  // editing an album should return to exactly this journal list if the menu
  // is swiped open again, not bump the user back to the menu root.
  // onAlbumTap (_openRatedAlbum in discovery_screen.dart) already closes the
  // card-over-menu overlay on its own; that's all that's needed here.
  Future<void> _openAlbum(Album album) async {
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

  // Tapping a row/card is "edit" — loads the album onto the main discovery
  // card (_openAlbum), pre-filled with its existing rating/ownership (see
  // discovery_screen.dart `_body`, which seeds the rating slider from the
  // album's current rating whenever a new album arrives). Swipe (list) or
  // long-press (grid) is unambiguously "remove" — no intermediate chooser.
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

  // Each badge slot is always reserved at a fixed width, whether or not
  // that album actually has it — otherwise rows with different combinations
  // of CD/vinyl/comment badges shift the trailing rating text to different
  // horizontal positions, visibly misaligned when rows sit side by side in
  // grid view.
  Widget _ownershipRatingRow(
      BuildContext context, Album album, Rating rating, int index) {
    final primary = Theme.of(context).colorScheme.primary;
    // Only the badges this album actually has, packed together with no
    // gaps — a missing badge no longer leaves an empty slot before the
    // ones that follow it.
    final badges = <Widget>[
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
      if (_albumsWithNotes.contains(album.mbid))
        SizedBox(
          width: 28,
          height: 28,
          child: Icon(Icons.sticky_note_2, size: 18, color: primary),
        ),
    ];
    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        // Fixed total width regardless of how many badges this album has —
        // this (not the per-badge packing above) is what keeps the trailing
        // rating icon aligned at the same horizontal position across rows.
        SizedBox(
          width: 28 * 3,
          height: 28,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(mainAxisSize: MainAxisSize.min, children: badges),
          ),
        ),
        const Spacer(),
        Icon(_ratingTierIcon(ratingTierFor(rating.stars)), size: 18, color: primary),
      ],
    );
  }
}

/// Icon for a rating tier — see `RatingTier`/`ratingTierFor` in
/// rating.dart. Shared by this row and the saved-filter form below.
IconData _ratingTierIcon(RatingTier tier) => switch (tier) {
      RatingTier.dislike => Icons.thumb_down,
      RatingTier.like => Icons.thumb_up,
      RatingTier.love => Icons.bolt,
    };

String _ratingTierLabel(RatingTier tier) => switch (tier) {
      RatingTier.dislike => 'Dislike',
      RatingTier.like => 'Like',
      RatingTier.love => 'Love',
    };

/// 'Any' plus one entry per tier, using the tier's own stored value as the
/// dropdown's underlying int — a min/max bound of e.g. `RatingTier.like.value`
/// (4) filters `ratings.stars >= 4`, which correctly includes love (5) too.
List<DropdownMenuItem<int?>> _ratingTierDropdownItems() {
  return [
    const DropdownMenuItem(value: null, child: Text('Any')),
    ...RatingTier.values.map((tier) => DropdownMenuItem(
          value: tier.value,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_ratingTierIcon(tier), size: 18),
              const SizedBox(width: 8),
              Text(_ratingTierLabel(tier)),
            ],
          ),
        )),
  ];
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
              items: _ratingTierDropdownItems(),
              onChanged: (value) => setState(() => _minRating = value),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int?>(
              initialValue: _maxRating,
              decoration: const InputDecoration(labelText: 'Maximum rating'),
              items: _ratingTierDropdownItems(),
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

