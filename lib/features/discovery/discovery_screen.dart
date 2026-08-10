import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../data/genre_pool.dart';
import 'discovery_controller.dart';

class DiscoveryScreen extends StatefulWidget {
  final DiscoveryController controller;

  const DiscoveryScreen({super.key, required this.controller});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

// The main card (art + labels + buttons) sits on top of a hidden background
// menu, full-screen at rest. Dragging it upward translates it off-screen at
// the top, exposing the menu underneath at the bottom; releasing snaps it
// to fully closed or fully open rather than resting wherever the drag ended.
class _DiscoveryScreenState extends State<DiscoveryScreen> with SingleTickerProviderStateMixin {
  double _pendingRating = 3;
  String? _lastSeenAlbumMbid;
  bool _genresPanelOpen = false;
  late AnimationController _liftController;

  static const _snapDuration = Duration(milliseconds: 600);
  static const _snapCurve = Curves.easeInOutCubicEmphasized;

  @override
  void initState() {
    super.initState();
    widget.controller.loadNext();
    _liftController = AnimationController(vsync: this, duration: _snapDuration);
  }

  @override
  void dispose() {
    _liftController.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details, double liftAmount) {
    _liftController.value -= details.delta.dy / liftAmount;
  }

  void _onDragEnd(DragEndDetails details) {
    final flingVelocity = details.velocity.pixelsPerSecond.dy;
    final target = flingVelocity < -250
        ? 1.0
        : flingVelocity > 250
            ? 0.0
            : (_liftController.value > 0.5 ? 1.0 : 0.0);
    _liftController.animateTo(target, duration: _snapDuration, curve: _snapCurve);
  }

  // Always safe to call regardless of current state — checks internally so
  // it can be wired up once as a static callback rather than rebuilt every
  // animation frame with a live "is it open" condition baked in.
  void _close() {
    if (_liftController.value > 0.01) {
      _liftController.animateTo(0, duration: _snapDuration, curve: _snapCurve);
    }
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
    if (controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Something went wrong:\n${controller.errorMessage}', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: controller.loadNext, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }

    final album = controller.currentAlbum;
    if (album == null) {
      return const Center(child: Text('No recommendation yet.'));
    }

    // A new album arrived — reset the rating slider back to neutral rather
    // than carrying over whatever was left from the previous album.
    if (_lastSeenAlbumMbid != album.mbid) {
      _lastSeenAlbumMbid = album.mbid;
      _pendingRating = 3;
    }

    final colors = Theme.of(context).colorScheme;
    final screenHeight = MediaQuery.of(context).size.height;
    // The card is shorter than the screen even at rest, so a sliver of the
    // background color is always visible at the bottom. Dragging it all the
    // way up leaves a deliberate "lip" of the card visible at the very top
    // instead of disappearing entirely — that lip is what "any tap brings
    // it back" acts on, and what a downward drag on the exposed background
    // also targets.
    const restPeek = 48.0;
    const topRemnant = 96.0;
    final cardHeight = screenHeight - restPeek;
    final liftAmount = cardHeight - topRemnant;

    return Stack(
      children: [
        // Background — the menu, hidden behind the card until lifted.
        // Anchored to the bottom, since that's the edge the card's own
        // bottom recedes from first as it translates upward. Also
        // drag-responsive: swiping down anywhere on the exposed background
        // brings the card back down, same physics as dragging the card
        // itself.
        Positioned.fill(
          child: GestureDetector(
            onVerticalDragUpdate: (details) => _onDragUpdate(details, liftAmount),
            onVerticalDragEnd: _onDragEnd,
            child: Container(
              color: colors.surface,
              child: SafeArea(
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
                          expanded: _genresPanelOpen,
                          onTap: () => setState(() => _genresPanelOpen = !_genresPanelOpen),
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topCenter,
                          child: _genresPanelOpen
                              ? _genrePanel(context, controller)
                              : const SizedBox(width: double.infinity),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),

        // Foreground — the card. Full height at rest (top: 0), so it covers
        // the menu entirely until dragged. Built once and reused via
        // AnimatedBuilder's `child` — only the Positioned wrapper rebuilds
        // every animation tick, not the whole card (art, chips, slider,
        // buttons), which is what was making the drag/snap feel janky.
        AnimatedBuilder(
          animation: _liftController,
          child: GestureDetector(
            onVerticalDragUpdate: (details) => _onDragUpdate(details, liftAmount),
            onVerticalDragEnd: _onDragEnd,
            onTap: _close,
            child: Container(
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 16)],
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: double.infinity,
                            height: screenHeight * 0.34,
                            child: album.coverArtUrl != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: Image.network(
                                      album.coverArtUrl!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (context, error, stackTrace) => _artworkPlaceholder(context),
                                    ),
                                  )
                                : _artworkPlaceholder(context),
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
                                    .map((g) => Padding(
                                          padding: const EdgeInsets.only(right: 6),
                                          child: Chip(label: Text(g), visualDensity: VisualDensity.compact),
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

  Widget _artworkPlaceholder(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      color: colors.surfaceContainerHigh,
      child: Icon(Icons.album, size: 64, color: colors.onSurfaceVariant),
    );
  }

  Widget _genrePanel(BuildContext context, DiscoveryController controller) {
    final selected = controller.likedGenres().toSet();

    return StatefulBuilder(
      builder: (context, setPanelState) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Used to seed recommendations when there\'s nothing to branch from yet.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: genrePool.map((genre) {
                return FilterChip(
                  label: Text(genre),
                  selected: selected.contains(genre),
                  onSelected: (isSelected) => setPanelState(() {
                    isSelected ? selected.add(genre) : selected.remove(genre);
                  }),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                controller.setLikedGenres(selected.toList());
                setState(() => _genresPanelOpen = false);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showPlayOptions(BuildContext context, DiscoveryController controller) {
    final links = controller.playLinks;
    final entries = links.isEmpty
        ? {'Search (no direct link found)': controller.fallbackSearchUrl()}.entries
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
                      launchUrl(Uri.parse(entry.value), mode: LaunchMode.externalApplication);
                    },
                  ))
              .toList(),
        ),
      ),
    );
  }
}

/// A row in the background menu layer — an icon, a label, and a
/// chevron that flips to show expanded/collapsed state.
class _MenuAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool expanded;
  final VoidCallback onTap;

  const _MenuAction({
    required this.icon,
    required this.label,
    required this.expanded,
    required this.onTap,
  });

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
            AnimatedRotation(
              turns: expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.expand_more),
            ),
          ],
        ),
      ),
    );
  }
}
