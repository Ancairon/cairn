import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../data/genre_pool.dart';
import '../../data/models/album.dart';
import '../rated_albums/rated_albums_screen.dart';
import '../settings/settings_screen.dart';
import 'discovery_controller.dart';

class DiscoveryScreen extends StatefulWidget {
  final DiscoveryController controller;

  const DiscoveryScreen({super.key, required this.controller});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

// The main card (art + labels + buttons) sits on top of a hidden background
// menu, full-screen at rest. A vertical swipe past a small threshold is a
// trigger, not a scrub — the card doesn't move with the finger at all; on
// release it plays one fixed open/close animation to whichever end state
// the swipe direction indicated. Tapping the card while open, or swiping
// down on the exposed background, closes it the same way.
class _DiscoveryScreenState extends State<DiscoveryScreen>
    with TickerProviderStateMixin {
  double _pendingRating = 3;
  String? _lastSeenAlbumMbid;
  double _dragAccum = 0;
  late AnimationController _liftController;
  late AnimationController _searchController;
  bool _searchOpen = false;
  bool _searching = false;
  List<Map<String, dynamic>> _searchResults = [];
  final _searchFieldController = TextEditingController();

  static const _snapDuration = Duration(milliseconds: 600);
  static const _snapCurve = Curves.easeInOutCubicEmphasized;
  static const _dragTriggerDistance = 40.0;
  static const _searchFadeDuration = Duration(milliseconds: 320);

  @override
  void initState() {
    super.initState();
    widget.controller.loadNext();
    _liftController = AnimationController(vsync: this, duration: _snapDuration);
    _searchController =
        AnimationController(vsync: this, duration: _searchFadeDuration);
  }

  @override
  void dispose() {
    _liftController.dispose();
    _searchController.dispose();
    _searchFieldController.dispose();
    super.dispose();
  }

  // Listener (not GestureDetector) so this tracks raw pointer movement
  // regardless of what any descendant Scrollable/GestureDetector does with
  // the same pointer — a vertical drag that starts over an inner scrollable
  // (e.g. RatedAlbumsPage's list, the genre picker's Wrap) still gets
  // tracked here in parallel instead of losing the gesture-arena fight to
  // the scroll, which is what a GestureDetector would do.
  void _onDragStart(PointerDownEvent event) {
    _dragAccum = 0;
  }

  void _onDragUpdate(PointerMoveEvent event) {
    _dragAccum += event.delta.dy;
  }

  // Background: swipe up has nothing further to open, so only the
  // downward/close direction actually does anything here.
  void _onDragEnd(PointerUpEvent event) {
    if (_dragAccum <= -_dragTriggerDistance) {
      _liftController.animateTo(1, duration: _snapDuration, curve: _snapCurve);
    } else if (_dragAccum >= _dragTriggerDistance) {
      _liftController.animateTo(0, duration: _snapDuration, curve: _snapCurve);
    }
    // Otherwise: too small to count as a real swipe — the card never moved
    // during the drag, so there's nothing to snap back from.
  }

  // Card: swiping down means something different depending on state —
  // closed already means there's nowhere further down to go, so that's
  // repurposed to open search instead.
  void _onCardDragEnd(PointerUpEvent event) {
    final isOpen = _liftController.value > 0.5;
    if (_dragAccum <= -_dragTriggerDistance && !isOpen) {
      _liftController.animateTo(1, duration: _snapDuration, curve: _snapCurve);
    } else if (_dragAccum >= _dragTriggerDistance) {
      if (isOpen) {
        _close();
      } else if (!_searchOpen) {
        _openSearch();
      }
    }
  }

  // Always safe to call regardless of current state.
  void _close() {
    if (_liftController.value > 0.01) {
      _liftController.animateTo(0, duration: _snapDuration, curve: _snapCurve);
    }
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    _searchController.animateTo(1,
        duration: _searchFadeDuration, curve: Curves.easeOutCubic);
  }

  void _closeSearch() {
    _searchController
        .animateTo(0, duration: _searchFadeDuration, curve: Curves.easeOutCubic)
        .whenComplete(() {
      if (!mounted) return;
      setState(() {
        _searchOpen = false;
        _searchResults = [];
        _searchFieldController.clear();
      });
    });
  }

  Future<void> _runSearch(DiscoveryController controller, String query) async {
    if (query.trim().isEmpty) return;
    setState(() => _searching = true);
    final results = await controller.searchAlbums(query);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _searchResults = results;
    });
  }

  Future<void> _pickSearchResult(
      DiscoveryController controller, String mbid) async {
    _closeSearch();
    await controller.startFromSearchResult(mbid);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) => _body(context, widget.controller),
      ),
    );
  }

  Widget _body(BuildContext context, DiscoveryController controller) {
    final album = controller.currentAlbum;

    // A new album arrived — reset the rating slider back to neutral rather
    // than carrying over whatever was left from the previous album.
    if (album != null && _lastSeenAlbumMbid != album.mbid) {
      _lastSeenAlbumMbid = album.mbid;
      _pendingRating = 3;
    }

    final colors = Theme.of(context).colorScheme;
    final screenHeight = MediaQuery.of(context).size.height;
    // The card is shorter than the screen even at rest, so a sliver of the
    // background color is always visible at the bottom. Fully open leaves a
    // deliberate "lip" of the card visible at the top instead of
    // disappearing entirely — that lip is what a tap or downward swipe acts
    // on to bring it back.
    const restPeek = 48.0;
    const topRemnant = 96.0;
    final cardHeight = screenHeight - restPeek;
    final liftAmount = cardHeight - topRemnant;

    return Stack(
      children: [
        // Background — the menu, hidden behind the card until lifted. Its
        // own Navigator, so tapping an entry pushes results in as a
        // horizontal slide via Cupertino's page transition; popping back is
        // handled by `_SwipeBackPop` wrapping each pushed page (Cupertino's
        // own edge-swipe-back gesture is too narrow to rely on — see that
        // class's doc comment).
        Positioned.fill(
          child: Listener(
            onPointerDown: _onDragStart,
            onPointerMove: _onDragUpdate,
            onPointerUp: _onDragEnd,
            child: Container(
              color: colors.surface,
              child: Navigator(
                onGenerateRoute: (settings) => CupertinoPageRoute(
                  builder: (context) => _MenuHomePage(controller: controller),
                ),
              ),
            ),
          ),
        ),

        // Foreground — the card. Full height at rest (top: 0), so it covers
        // the menu entirely until lifted. Built once and reused via
        // AnimatedBuilder's `child` — only the Positioned wrapper rebuilds
        // every animation tick, not the whole card.
        AnimatedBuilder(
          animation: _liftController,
          child: Listener(
            onPointerDown: _onDragStart,
            onPointerMove: _onDragUpdate,
            onPointerUp: _onCardDragEnd,
            child: GestureDetector(
              onTap: _close,
              child: Container(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius:
                      const BorderRadius.vertical(bottom: Radius.circular(28)),
                  boxShadow: [
                    BoxShadow(
                        color: colors.shadow.withValues(alpha: 0.25),
                        blurRadius: 16)
                  ],
                ),
                child: SafeArea(
                  child: AnimatedBuilder(
                    animation: _searchController,
                    builder: (context, _) {
                      final t = _searchController.value;
                      return Stack(
                        children: [
                          Opacity(
                            opacity: 1 - t,
                            child: IgnorePointer(
                              ignoring: t > 0.01,
                              child: Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(20, 8, 20, 12),
                                child: controller.isLoading
                                    ? _LoadingContent(
                                        color: colors.onSurfaceVariant)
                                    : controller.errorMessage != null
                                        ? _errorContent(controller)
                                        : album == null
                                            ? const Center(
                                                child: Text(
                                                    'No recommendation yet.'))
                                            : _albumContent(
                                                context, controller, album),
                              ),
                            ),
                          ),
                          if (_searchOpen || t > 0.01)
                            Opacity(
                              opacity: t,
                              child: IgnorePointer(
                                ignoring: t < 0.99,
                                child: _searchOverlay(context, controller),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          builder: (context, child) {
            return Positioned(
              top: -(_liftController.value * liftAmount),
              left: 0,
              right: 0,
              height: cardHeight,
              child: child!,
            );
          },
        ),
      ],
    );
  }

  Widget _errorContent(DiscoveryController controller) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Something went wrong:\n${controller.errorMessage}',
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: controller.loadNext, child: const Text('Try again')),
        ],
      ),
    );
  }

  Widget _searchOverlay(BuildContext context, DiscoveryController controller) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchFieldController,
                  decoration: const InputDecoration(
                      hintText: 'Search albums…', border: InputBorder.none),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (query) => _runSearch(controller, query),
                ),
              ),
              IconButton(
                  icon: const Icon(Icons.close), onPressed: _closeSearch),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: _searching
                ? _LoadingContent(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)
                : ListView(
                    children: _searchResults.map((r) {
                      final artist = ((r['artist-credit'] as List?) ?? [])
                          .cast<Map<String, dynamic>>()
                          .map((c) => c['name'] as String)
                          .join(', ');
                      final year = (r['first-release-date'] as String?)
                              ?.split('-')
                              .first ??
                          'unknown year';
                      return ListTile(
                        title: Text(r['title'] as String),
                        subtitle: Text('$artist · $year'),
                        onTap: () =>
                            _pickSearchResult(controller, r['id'] as String),
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _albumContent(
      BuildContext context, DiscoveryController controller, Album album) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A fixed 1:1 square regardless of the source image's own
        // proportions — the artwork is always cropped to fit it.
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: 1,
            child: album.coverArtUrl != null
                ? Image.network(
                    album.coverArtUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        _artworkPlaceholder(context),
                  )
                : _artworkPlaceholder(context),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          album.title,
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          '${album.artistName} · ${album.firstReleaseYear ?? 'unknown year'}',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        if (album.genres.isNotEmpty)
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: album.genres
                  .map<Widget>((g) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Chip(
                            label: Text(g),
                            visualDensity: VisualDensity.compact),
                      ))
                  .toList(),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 8,
          children: [
            FilterChip(
              label: const Text('CD'),
              avatar: const Icon(Icons.album, size: 18),
              selected: album.ownsCd,
              onSelected: (_) => controller.toggleOwnsCd(),
            ),
            FilterChip(
              label: const Text('Vinyl'),
              avatar: const Icon(Icons.album_outlined, size: 18),
              selected: album.ownsVinyl,
              onSelected: (_) => controller.toggleOwnsVinyl(),
            ),
          ],
        ),
        Text(
          'Rating: ${_pendingRating.round()} star${_pendingRating.round() == 1 ? '' : 's'}',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            overlayShape: SliderComponentShape.noOverlay,
          ),
          child: Slider(
            value: _pendingRating,
            min: 1,
            max: 5,
            divisions: 4,
            label: '${_pendingRating.round()}',
            onChanged: (value) => setState(() => _pendingRating = value),
          ),
        ),
        FilledButton(
          onPressed: () => controller.rate(_pendingRating.round()),
          child: const Text('Rate'),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () => _showPlayOptions(context, controller),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Play'),
        ),
      ],
    );
  }

  Widget _artworkPlaceholder(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      color: colors.surfaceContainerHigh,
      child: Icon(Icons.album, size: 64, color: colors.onSurfaceVariant),
    );
  }

  void _showPlayOptions(BuildContext context, DiscoveryController controller) {
    final links = controller.playLinks;
    final entries = links.isEmpty
        ? {'Search (no direct link found)': controller.fallbackSearchUrl()}
            .entries
        : links.entries;

    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: entries
              .map((entry) => ListTile(
                    title: Text(entry.key),
                    onTap: () {
                      Navigator.pop(context);
                      launchUrl(Uri.parse(entry.value),
                          mode: LaunchMode.externalApplication);
                    },
                  ))
              .toList(),
        ),
      ),
    );
  }
}

/// The background menu's home page — just the entry list, anchored to the
/// bottom (the edge revealed first as the card lifts).
class _MenuHomePage extends StatelessWidget {
  final DiscoveryController controller;

  const _MenuHomePage({required this.controller});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MenuAction(
                icon: Icons.tune,
                label: 'Liked genres',
                onTap: () => Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (context) => _SwipeBackPop(
                        child: _GenrePickerPage(controller: controller)),
                  ),
                ),
              ),
              _MenuAction(
                icon: Icons.history,
                label: 'Rated albums',
                onTap: () => Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (context) => _SwipeBackPop(
                      child: RatedAlbumsPage(
                        ratingRepository: controller.ratings,
                        albumRepository: controller.albums,
                        savedFilterRepository: controller.savedFilters,
                      ),
                    ),
                  ),
                ),
              ),
              _MenuAction(
                icon: Icons.settings,
                label: 'Settings',
                onTap: () => Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (context) => _SwipeBackPop(
                        child: SettingsPage(settings: controller.settings)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wraps a pushed sub-page with a full-screen swipe-right-to-pop gesture.
/// Cupertino's own back gesture only answers to drags starting within the
/// leftmost 20 logical pixels — too narrow to feel reliable, and the user
/// wants this to work from anywhere on the page. A `Listener` (not
/// `GestureDetector`) tracks raw pointer movement regardless of what any
/// descendant Scrollable does with the same pointer — e.g. RatedAlbumsPage's
/// horizontally-scrolling filter-chip row keeps scrolling normally, this
/// still tracks the horizontal drag in parallel instead of losing the
/// gesture-arena fight to it.
class _SwipeBackPop extends StatefulWidget {
  final Widget child;

  const _SwipeBackPop({required this.child});

  @override
  State<_SwipeBackPop> createState() => _SwipeBackPopState();
}

class _SwipeBackPopState extends State<_SwipeBackPop> {
  double _dragAccum = 0;

  static const _triggerDistance = 60.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _dragAccum = 0,
      onPointerMove: (event) => _dragAccum += event.delta.dx,
      onPointerUp: (_) {
        if (_dragAccum > _triggerDistance) Navigator.of(context).maybePop();
      },
      child: widget.child,
    );
  }
}

/// Pushed on top of the menu home page — slides in horizontally, and
/// swiping right anywhere on the page (via `_SwipeBackPop`, wrapped at the
/// push call site in `_MenuHomePage`) pops back to the menu.
class _GenrePickerPage extends StatefulWidget {
  final DiscoveryController controller;

  const _GenrePickerPage({required this.controller});

  @override
  State<_GenrePickerPage> createState() => _GenrePickerPageState();
}

class _GenrePickerPageState extends State<_GenrePickerPage> {
  late final Set<String> _selected = widget.controller.likedGenres().toSet();

  // Applies immediately — there's no separate Save step. Leaving the page
  // (back button, or the standard right-swipe) just keeps whatever's
  // currently selected.
  void _toggle(String genre, bool isSelected) {
    setState(() => isSelected ? _selected.add(genre) : _selected.remove(genre));
    widget.controller.setLikedGenres(_selected.toList());
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
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
                Text('Liked genres',
                    style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: genrePool.map((genre) {
                  return FilterChip(
                    label: Text(genre),
                    selected: _selected.contains(genre),
                    onSelected: (isSelected) => _toggle(genre, isSelected),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A row in the background menu — icon, label, and a static chevron
/// indicating it navigates to another screen.
class _MenuAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MenuAction(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon),
            const SizedBox(width: 12),
            Text(label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 12),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

/// A simple three-dot staggered bounce, shown in place of the album content
/// while a recommendation is loading — the card itself never disappears.
class _LoadingContent extends StatefulWidget {
  final Color color;

  const _LoadingContent({required this.color});

  @override
  State<_LoadingContent> createState() => _LoadingContentState();
}

class _LoadingContentState extends State<_LoadingContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = (_controller.value - (i * 0.2)) % 1.0;
              final bounce = t < 0.5
                  ? Curves.easeOut.transform(t * 2)
                  : Curves.easeIn.transform(1 - (t - 0.5) * 2);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Transform.translate(
                  offset: Offset(0, -bounce * 8),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                        color: widget.color, shape: BoxShape.circle),
                  ),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}
