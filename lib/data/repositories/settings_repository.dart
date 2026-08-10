import '../../core/db/app_database.dart';

/// App-level UI preferences — currently just one. Kept separate from
/// RecommendationRepository's app_state usage since this is a display
/// preference, not a recommendation input.
class SettingsRepository {
  final AppDatabase database;

  SettingsRepository(this.database);

  /// The menu item name (e.g. "Liked genres") to auto-expand when the menu
  /// is revealed, or null for "None".
  String? defaultExpandedMenuItem() {
    final rows = database.db.select('SELECT default_expanded_menu_item FROM app_state WHERE id = 0');
    if (rows.isEmpty) return null;
    return rows.first['default_expanded_menu_item'] as String?;
  }

  void setDefaultExpandedMenuItem(String? menuItemName) {
    database.db.execute(
      'INSERT INTO app_state (id, default_expanded_menu_item) VALUES (0, ?) '
      'ON CONFLICT(id) DO UPDATE SET default_expanded_menu_item = excluded.default_expanded_menu_item',
      [menuItemName],
    );
  }
}
