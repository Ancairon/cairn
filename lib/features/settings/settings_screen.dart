import 'package:flutter/material.dart';
import '../../data/repositories/settings_repository.dart';

/// Menu item names that can be set as the default opened item on slide.
/// "Liked genres" is the only openable menu entry today — add new names
/// here as more openable menu items are introduced.
const _openableMenuItems = ['Liked genres'];

/// The app's settings page. Currently a single setting: which menu item (if
/// any) should already be open when the background menu is revealed.
/// Selections apply immediately, matching the rest of the app's "no Save
/// button" convention (see _GenrePickerPage in discovery_screen.dart).
class SettingsPage extends StatefulWidget {
  final SettingsRepository settings;

  const SettingsPage({super.key, required this.settings});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late String? _selected = widget.settings.defaultOpenedMenuItem();

  void _select(String? menuItemName) {
    setState(() => _selected = menuItemName);
    widget.settings.setDefaultOpenedMenuItem(menuItemName);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: Theme.of(context).colorScheme.surface,
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
                  Text('Settings', style: textTheme.titleLarge),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('Default opened menu item on slide', style: textTheme.titleMedium),
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
            for (final item in _openableMenuItems)
              _OptionTile(
                label: item,
                selected: _selected == item,
                onTap: () => _select(item),
              ),
          ],
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

  const _OptionTile({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      trailing: selected ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
      onTap: onTap,
    );
  }
}
