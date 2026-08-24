import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/backup_repository.dart';
import '../../data/repositories/import_repository.dart';
import '../../data/repositories/update_check_repository.dart';

/// Display label -> stored value for the default-player-app setting. The
/// stored value is the stable constant from settings_repository.dart; the
/// label is just what's shown in the UI.
const _playerAppOptions = {
  'Spotify': playerAppSpotify,
  'YouTube Music': playerAppYoutubeMusic,
};

/// Consistent short form for every timestamp shown in Settings (last backup,
/// last import, last update check) — no `intl` dependency, matching this
/// project's plain-dependencies preference.
String _formatTimestamp(DateTime utc) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = utc.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${months[local.month - 1]} ${local.day}, ${local.year} · $hour:$minute';
}

/// The app's settings page: which menu item (if any) should already be open
/// when the background menu is revealed, and which player app (if any) Play
/// should fire straight into. Selections apply immediately, matching the
/// rest of the app's "no Save button" convention (see _GenrePickerPage in
/// discovery_screen.dart).
class SettingsPage extends StatefulWidget {
  final SettingsRepository settings;
  final VoidCallback onResetSkipPenalties;
  final Future<void> Function() onClearArtworkCache;
  final VoidCallback onClearAlbumCache;
  final Future<void> Function() onBackup;
  final Future<String?> Function() onPickBackupFolder;
  final Future<String?> Function() onPickImportFile;
  final Future<ImportPreview> Function(
          String content, void Function(ImportProgress progress) onProgress)
      onPreviewImport;
  final Future<int> Function(ImportPreview preview) onApplyImport;
  final Future<(bool succeeded, String? newerVersion)> Function()
      onCheckForUpdate;
  final Future<int> Function() onRefreshRatedAlbumsMetadata;

  const SettingsPage(
      {super.key,
      required this.settings,
      required this.onResetSkipPenalties,
      required this.onClearArtworkCache,
      required this.onClearAlbumCache,
      required this.onBackup,
      required this.onPickBackupFolder,
      required this.onPickImportFile,
      required this.onPreviewImport,
      required this.onApplyImport,
      required this.onCheckForUpdate,
      required this.onRefreshRatedAlbumsMetadata});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late String? _selected = widget.settings.defaultOpenedMenuItem();
  late String? _selectedPlayerApp = widget.settings.defaultPlayerApp();
  late bool _autoBackupsEnabled = widget.settings.autoBackupsEnabled();
  late String? _backupFolder = widget.settings.backupFolderPath();

  void _select(String? menuItemName) {
    setState(() => _selected = menuItemName);
    widget.settings.setDefaultOpenedMenuItem(menuItemName);
  }

  void _selectPlayerApp(String? playerApp) {
    setState(() => _selectedPlayerApp = playerApp);
    widget.settings.setDefaultPlayerApp(playerApp);
  }

  Future<void> _resetSkipPenalties() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset skip penalties?'),
        content: const Text(
            'All explicit Skip-button penalty counts will be cleared.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (confirmed == true) widget.onResetSkipPenalties();
  }

  Future<void> _setBackupFolder() async {
    final path = await widget.onPickBackupFolder();
    if (!mounted || path == null) return;
    setState(() => _backupFolder = path);
    widget.settings.setBackupFolderPath(path);
  }

  Future<void> _setAutoBackups(bool enabled) async {
    if (!enabled) {
      setState(() => _autoBackupsEnabled = false);
      widget.settings.setAutoBackupsEnabled(false);
      return;
    }
    if (_backupFolder == null) {
      await _setBackupFolder();
      if (!mounted || _backupFolder == null) return;
    }
    if (widget.settings.backupConsent() == null) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Allow weekly backups?'),
          content: const Text(
              'Cairn will overwrite the weekly database backup in the selected folder when a backup is due.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Decline')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Allow')),
          ],
        ),
      );
      widget.settings
          .setBackupConsent(accepted == true ? 'accepted' : 'declined');
      if (accepted != true) {
        setState(() => _autoBackupsEnabled = false);
        widget.settings.setAutoBackupsEnabled(false);
        return;
      }
    } else if (widget.settings.backupConsent() == 'declined') {
      // Re-enabling the setting is an explicit second consent action after
      // the one-time prompt was declined.
      widget.settings.setBackupConsent('accepted');
    }
    setState(() => _autoBackupsEnabled = true);
    widget.settings.setAutoBackupsEnabled(true);
  }

  /// Picks a file, previews the match against local albums, and only writes
  /// anything once the user confirms the counts shown in the dialog below.
  /// Matching an album not already cached locally means a live MusicBrainz
  /// lookup per row, throttled to 1/second — for a large file on a device
  /// that hasn't seen most of these albums before, that's a real wait, so a
  /// modal progress dialog (bar + current row) tracks it.
  Future<void> _importRatings() async {
    final String? content;
    try {
      content = await widget.onPickImportFile();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text("Couldn't read that file — is it a Cairn ratings export?")));
      return;
    }
    if (!mounted || content == null) return;

    final messenger = ScaffoldMessenger.of(context);
    final progress = ValueNotifier<ImportProgress?>(null);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Matching ratings…'),
          content: ValueListenableBuilder<ImportProgress?>(
            valueListenable: progress,
            builder: (context, current, _) {
              final total = current?.total ?? 0;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(
                    value: total == 0 ? null : current!.current / total,
                  ),
                  const SizedBox(height: 12),
                  Text(current == null
                      ? 'Starting…'
                      : '${current.current} / $total'),
                  if (current != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${current.row.artist} – ${current.row.title}',
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );

    void handleProgress(ImportProgress p) => progress.value = p;

    final ImportPreview preview;
    try {
      preview = await widget.onPreviewImport(content, handleProgress);
    } catch (_) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
          content:
              Text("Couldn't read that file — is it a Cairn ratings export?")));
      return;
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!mounted) return;

    final hasExtras = preview.likedGenres != null ||
        preview.savedFilters != null ||
        preview.settings != null;
    if (preview.newCount == 0 && preview.overwriteCount == 0 && !hasExtras) {
      messenger.showSnackBar(SnackBar(
        content: Text(preview.unmatchedCount == 0
            ? 'That file has no ratings to import.'
            : 'None of the ${preview.unmatchedCount} row(s) in that file '
                'could be matched to an album.'),
      ));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import ratings?'),
        content: Text('${preview.newCount} new rating(s) will be added.\n'
            '${preview.overwriteCount} existing rating(s) will be overwritten.\n'
            '${preview.unmatchedCount} row(s) could not be matched and will be skipped.\n'
            '${preview.likedGenres != null ? 'Liked genres will be replaced (${preview.likedGenres!.length}).\n' : ''}'
            '${preview.savedFilters != null ? '${preview.savedFilters!.length} saved filter(s) will be added or updated.\n' : ''}'
            '${preview.settings != null ? 'App preferences (default menu/player app, Rated Albums display) will be updated.\n' : ''}'
            '\n'
            "A safety copy of your current data is saved to Cairn's app "
            'storage first, in case something goes wrong.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Import')),
        ],
      ),
    );
    if (confirmed != true) return;

    final int written;
    try {
      written = await widget.onApplyImport(preview);
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
          content: Text(
              'Import failed partway through — check Rated Albums for what made it in.')));
      return;
    }
    if (!mounted) return;
    setState(() {});
    messenger.showSnackBar(SnackBar(
      content: Text('Imported $written rating${written == 1 ? '' : 's'}.'),
    ));
  }

  Future<void> _checkForUpdate() async {
    final (succeeded, newerVersion) = await widget.onCheckForUpdate();
    if (!mounted) return;
    setState(() {});
    final messenger = ScaffoldMessenger.of(context);
    if (!succeeded) {
      messenger.showSnackBar(const SnackBar(
          content: Text("Couldn't check for updates. Try again later.")));
    } else if (newerVersion != null) {
      messenger.showSnackBar(SnackBar(
        content:
            Text('Update available: v$newerVersion. Download the APK from the '
                'Releases page and install it manually.'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Open Releases',
          onPressed: () => launchUrl(
            Uri.parse(UpdateCheckRepository.releasesPageUrl),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ));
    } else {
      messenger.showSnackBar(
          const SnackBar(content: Text("You're on the latest version.")));
    }
  }

  Future<void> _refreshRatedAlbumsMetadata() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
      content:
          Text("Refreshing rated albums' metadata — this can take a while..."),
      duration: Duration(seconds: 4),
    ));
    final count = await widget.onRefreshRatedAlbumsMetadata();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:
          Text('Refreshed metadata for $count album${count == 1 ? '' : 's'}.'),
    ));
  }

  Future<void> _confirmAction(
      {required String title,
      required String message,
      required Future<void> Function() action}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue')),
        ],
      ),
    );
    if (confirmed == true) await action();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final lastBackupAt = widget.settings.lastBackupAt();
    final lastImportAt = widget.settings.lastImportAt();
    final lastUpdateCheckAt = widget.settings.lastUpdateCheckAt();
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
                child: Center(
                  child: Text('Settings', style: textTheme.titleLarge),
                ),
              ),
              const _SectionHeader('Behavior'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text('Default opened menu item on slide',
                    style: textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  'When you swipe up to reveal the menu, this item opens automatically.',
                  style: textTheme.bodySmall,
                ),
              ),
              _OptionTile(
                label: 'None',
                selected: _selected == null,
                onTap: () => _select(null),
              ),
              for (final item in defaultOpenedMenuItemOptions)
                _OptionTile(
                  label: item,
                  selected: _selected == item,
                  onTap: () => _select(item),
                ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text('Default player app', style: textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  'Play fires straight into this app — a direct link if this album has one, otherwise a search within it.',
                  style: textTheme.bodySmall,
                ),
              ),
              _OptionTile(
                label: 'None',
                selected: _selectedPlayerApp == null,
                onTap: () => _selectPlayerApp(null),
              ),
              for (final entry in _playerAppOptions.entries)
                _OptionTile(
                  label: entry.key,
                  selected: _selectedPlayerApp == entry.value,
                  onTap: () => _selectPlayerApp(entry.value),
                ),
              const _SectionHeader('Discovery'),
              _OptionTile(
                label: 'Reset skip penalties',
                selected: false,
                onTap: _resetSkipPenalties,
              ),
              const _SectionHeader('Data'),
              _OptionTile(
                label: 'Clear artwork cache',
                selected: false,
                onTap: () => _confirmAction(
                  title: 'Clear artwork cache?',
                  message: 'Ratings and album metadata will be preserved.',
                  action: widget.onClearArtworkCache,
                ),
              ),
              _OptionTile(
                label: 'Clear un-rated album cache',
                selected: false,
                onTap: () => _confirmAction(
                  title: 'Clear un-rated album cache?',
                  message: 'Rated albums and ratings will be preserved.',
                  action: () async => widget.onClearAlbumCache(),
                ),
              ),
              _OptionTile(
                label: "Refresh rated albums' metadata",
                selected: false,
                onTap: () => _confirmAction(
                  title: "Refresh rated albums' metadata?",
                  message:
                      'Re-fetches title, cover art, and other metadata for '
                      'every rated album from MusicBrainz. This can take a '
                      'while for a large journal. Ownership flags and '
                      'ratings are preserved.',
                  action: _refreshRatedAlbumsMetadata,
                ),
              ),
              const _SectionHeader('Backup & Restore'),
              _OptionTile(
                label: 'Backup ratings',
                subtitle: 'Share a JSON/CSV export of every rating',
                selected: false,
                onTap: widget.onBackup,
              ),
              _OptionTile(
                label: 'Import ratings',
                subtitle: lastImportAt == null
                    ? 'Restore ratings from a previously exported file'
                    : 'Last import: ${_formatTimestamp(lastImportAt)}',
                selected: false,
                onTap: _importRatings,
              ),
              SwitchListTile(
                title: const Text('Automatic weekly backups'),
                subtitle: Text([
                  _backupFolder == null
                      ? 'Choose a backup folder first'
                      : 'Overwrites ${BackupRepository.fileName} when due',
                  if (lastBackupAt != null)
                    'Last backup: ${_formatTimestamp(lastBackupAt)}',
                ].join('\n')),
                isThreeLine: lastBackupAt != null,
                value: _autoBackupsEnabled,
                onChanged: _setAutoBackups,
              ),
              _OptionTile(
                label: _backupFolder == null
                    ? 'Choose backup folder'
                    : 'Change backup folder',
                selected: false,
                onTap: _setBackupFolder,
              ),
              const _SectionHeader('About'),
              _OptionTile(
                label: 'Check for updates',
                subtitle: lastUpdateCheckAt == null
                    ? null
                    : 'Last checked: ${_formatTimestamp(lastUpdateCheckAt)}',
                selected: false,
                onTap: _checkForUpdate,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// A bold, uppercase divider between groups of related settings — distinct
/// from the plain `titleMedium` labels used for a single control's own
/// heading (e.g. "Default player app") within a section.
class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colors.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
      ),
    );
  }
}

/// A single selectable row — label plus a checkmark when it's the active
/// choice. Deliberately plain (a list, not a fancier radio widget) so adding
/// more options later is just another entry in `_openableMenuItems`.
class _OptionTile extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _OptionTile(
      {required this.label,
      this.subtitle,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: selected
          ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: onTap,
    );
  }
}
