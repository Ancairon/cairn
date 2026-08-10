import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'discovery_controller.dart';

class DiscoveryScreen extends StatefulWidget {
  final DiscoveryController controller;

  const DiscoveryScreen({super.key, required this.controller});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.loadNext();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('record_reccomend')),
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

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (album.coverArtUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
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
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (i) {
              final stars = i + 1;
              return IconButton(
                iconSize: 36,
                icon: const Icon(Icons.star, color: Colors.amber),
                onPressed: () => controller.rate(stars),
                tooltip: '$stars star${stars == 1 ? '' : 's'}',
              );
            }),
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
}
