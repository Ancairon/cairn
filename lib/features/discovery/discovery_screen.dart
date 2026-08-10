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

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  double _pendingRating = 3;
  String? _lastSeenAlbumMbid;

  @override
  void initState() {
    super.initState();
    widget.controller.loadNext();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('record_reccomend'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Liked genres',
            onPressed: () => _showGenrePicker(context, widget.controller),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) => _body(widget.controller),
      ),
    );
  }

  Widget _body(DiscoveryController controller) {
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

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (album.coverArtUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(
                album.coverArtUrl!,
                errorBuilder: (context, error, stackTrace) => _artworkPlaceholder(),
              ),
            )
          else
            _artworkPlaceholder(),
          const SizedBox(height: 16),
          Text(album.title, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
          Text(
            '${album.artistName} · ${album.firstReleaseYear ?? 'unknown year'}',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          if (album.genres.isNotEmpty)
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: album.genres.map((g) => Chip(label: Text(g))).toList(),
            ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 12,
            children: [
              FilterChip(
                label: const Text('Own on CD'),
                avatar: const Icon(Icons.album),
                selected: album.ownsCd,
                onSelected: (_) => controller.toggleOwnsCd(),
              ),
              FilterChip(
                label: const Text('Own on vinyl'),
                avatar: const Icon(Icons.album_outlined),
                selected: album.ownsVinyl,
                onSelected: (_) => controller.toggleOwnsVinyl(),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Rating: ${_pendingRating.round()} star${_pendingRating.round() == 1 ? '' : 's'}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Slider(
            value: _pendingRating,
            min: 1,
            max: 5,
            divisions: 4,
            label: '${_pendingRating.round()}',
            onChanged: (value) => setState(() => _pendingRating = value),
          ),
          FilledButton(
            onPressed: () => controller.rate(_pendingRating.round()),
            child: const Text('Rate'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _showPlayOptions(context, controller),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Play'),
          ),
        ],
      ),
    );
  }

  Widget _artworkPlaceholder() {
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        color: Colors.grey.shade300,
        child: const Icon(Icons.album, size: 64, color: Colors.grey),
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

  void _showGenrePicker(BuildContext context, DiscoveryController controller) {
    final selected = controller.likedGenres().toSet();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Pick genres you like', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'Used to seed recommendations when there\'s nothing to branch from yet.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: genrePool.map((genre) {
                        return FilterChip(
                          label: Text(genre),
                          selected: selected.contains(genre),
                          onSelected: (isSelected) => setSheetState(() {
                            isSelected ? selected.add(genre) : selected.remove(genre);
                          }),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    controller.setLikedGenres(selected.toList());
                    Navigator.pop(context);
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
