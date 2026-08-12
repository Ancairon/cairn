import '../../core/db/app_database.dart';

/// Player app identifiers for [SettingsRepository.defaultPlayerApp] — stable,
/// plain string constants, matching this project's style elsewhere (e.g.
/// `_seedPreferenceOrder` in deep_link_repository.dart).
const playerAppSpotify = 'spotify';
const playerAppYoutubeMusic = 'youtube_music';

/// Menu entries that can be opened automatically when the discovery menu is
/// revealed. Keep this registry shared by Settings and the menu resolver so a
/// newly added entry cannot silently become unselectable or unopenable.
const defaultOpenedMenuItemOptions = <String>[
  'Liked genres',
  'Rated albums',
  'Settings',
];

/// App-level UI preferences. Kept separate from RecommendationRepository's
/// app_state usage since these are display/behavior preferences, not
/// recommendation inputs.
class SettingsRepository {
  final AppDatabase database;

  SettingsRepository(this.database);

  /// The menu item name (e.g. "Liked genres") to auto-open when the menu
  /// is revealed, or null for "None".
  ///
  /// The backing column stays named `default_expanded_menu_item` — see
  /// lib/core/db/app_database.dart — only the Dart-level name changed.
  String? defaultOpenedMenuItem() {
    final rows = database.db.select(
        'SELECT default_expanded_menu_item FROM app_state WHERE id = 0');
    if (rows.isEmpty) return null;
    return rows.first['default_expanded_menu_item'] as String?;
  }

  void setDefaultOpenedMenuItem(String? menuItemName) {
    database.db.execute(
      'INSERT INTO app_state (id, default_expanded_menu_item) VALUES (0, ?) '
      'ON CONFLICT(id) DO UPDATE SET default_expanded_menu_item = excluded.default_expanded_menu_item',
      [menuItemName],
    );
  }

  /// One of [playerAppSpotify]/[playerAppYoutubeMusic], or null for "None" —
  /// no default set, keep showing the full picker on Play.
  String? defaultPlayerApp() {
    final rows = database.db
        .select('SELECT default_player_app FROM app_state WHERE id = 0');
    if (rows.isEmpty) return null;
    return rows.first['default_player_app'] as String?;
  }

  void setDefaultPlayerApp(String? playerApp) {
    database.db.execute(
      'INSERT INTO app_state (id, default_player_app) VALUES (0, ?) '
      'ON CONFLICT(id) DO UPDATE SET default_player_app = excluded.default_player_app',
      [playerApp],
    );
  }

  /// The persisted presentation choices for the rated-albums page. These are
  /// deliberately plain strings so the database remains easy to inspect and
  /// older installations can safely fall back to the page defaults.
  String? ratedAlbumsSort() => _appStateString('rated_albums_sort');

  void setRatedAlbumsSort(String value) =>
      _setAppStateString('rated_albums_sort', value);

  String? ratedAlbumsView() => _appStateString('rated_albums_view');

  void setRatedAlbumsView(String value) =>
      _setAppStateString('rated_albums_view', value);

  String? ratedAlbumsSize() => _appStateString('rated_albums_size');

  void setRatedAlbumsSize(String value) =>
      _setAppStateString('rated_albums_size', value);

  bool autoBackupsEnabled() {
    final rows = database.db
        .select('SELECT auto_backups_enabled FROM app_state WHERE id = 0');
    if (rows.isEmpty) return false;
    return (rows.first['auto_backups_enabled'] as int?) == 1;
  }

  void setAutoBackupsEnabled(bool enabled) {
    database.db.execute(
      'INSERT INTO app_state (id, auto_backups_enabled) VALUES (0, ?) '
      'ON CONFLICT(id) DO UPDATE SET auto_backups_enabled = excluded.auto_backups_enabled',
      [enabled ? 1 : 0],
    );
  }

  /// Null means the user has not made the one-time consent decision yet.
  /// `accepted` and `declined` are intentionally explicit for auditability.
  String? backupConsent() => _appStateString('backup_consent');

  void setBackupConsent(String value) =>
      _setAppStateString('backup_consent', value);

  String? backupFolderPath() => _appStateString('backup_folder_path');

  void setBackupFolderPath(String? path) =>
      _setNullableAppStateString('backup_folder_path', path);

  DateTime? lastBackupAt() {
    final rows =
        database.db.select('SELECT last_backup_at FROM app_state WHERE id = 0');
    if (rows.isEmpty) return null;
    final timestamp = rows.first['last_backup_at'] as int?;
    return timestamp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true);
  }

  void setLastBackupAt(DateTime value) {
    database.db.execute(
      'INSERT INTO app_state (id, last_backup_at) VALUES (0, ?) '
      'ON CONFLICT(id) DO UPDATE SET last_backup_at = excluded.last_backup_at',
      [value.toUtc().millisecondsSinceEpoch],
    );
  }

  DateTime? lastUpdateCheckAt() {
    final rows = database.db
        .select('SELECT last_update_check_at FROM app_state WHERE id = 0');
    if (rows.isEmpty) return null;
    final timestamp = rows.first['last_update_check_at'] as int?;
    return timestamp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true);
  }

  void setLastUpdateCheckAt(DateTime value) {
    database.db.execute(
      'INSERT INTO app_state (id, last_update_check_at) VALUES (0, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'last_update_check_at = excluded.last_update_check_at',
      [value.toUtc().millisecondsSinceEpoch],
    );
  }

  String? _appStateString(String column) {
    final rows =
        database.db.select('SELECT $column FROM app_state WHERE id = 0');
    if (rows.isEmpty) return null;
    return rows.first[column] as String?;
  }

  void _setAppStateString(String column, String value) {
    database.db.execute(
      'INSERT INTO app_state (id, $column) VALUES (0, ?) '
      'ON CONFLICT(id) DO UPDATE SET $column = excluded.$column',
      [value],
    );
  }

  void _setNullableAppStateString(String column, String? value) {
    database.db.execute(
      'INSERT INTO app_state (id, $column) VALUES (0, ?) '
      'ON CONFLICT(id) DO UPDATE SET $column = excluded.$column',
      [value],
    );
  }
}
