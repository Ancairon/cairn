import 'package:flutter/material.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/backup_repository.dart';

/// Display label -> stored value for the default-player-app setting. The
/// stored value is the stable constant from settings_repository.dart; the
/// label is just what's shown in the UI.
const _playerAppOptions = {
  'Spotify': playerAppSpotify,
  'YouTube Music': playerAppYoutubeMusic,
};

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

  const SettingsPage(
      {super.key,
      required this.settings,
      required this.onResetSkipPenalties,
      required this.onClearArtworkCache,
      required this.onClearAlbumCache,
      required this.onBackup,
      required this.onPickBackupFolder});

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
              const SizedBox(height: 8),
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
              const SizedBox(height: 8),
              _OptionTile(
                label: 'Reset skip penalties',
                selected: false,
                onTap: _resetSkipPenalties,
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text('Data', style: textTheme.titleMedium),
              ),
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
                label: 'Backup ratings',
                selected: false,
                onTap: widget.onBackup,
              ),
              SwitchListTile(
                title: const Text('Automatic weekly backups'),
                subtitle: Text(_backupFolder == null
                    ? 'Choose a backup folder first'
                    : 'Overwrites ${BackupRepository.fileName} when due'),
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
            ],
          ),
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
  final bool selected;
  final VoidCallback onTap;

  const _OptionTile(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      trailing: selected
          ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: onTap,
    );
  }
}
