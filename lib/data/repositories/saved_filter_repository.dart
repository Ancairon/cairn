import '../../core/db/app_database.dart';
import '../models/saved_filter.dart';

class SavedFilterRepository {
  final AppDatabase database;

  SavedFilterRepository(this.database);

  List<SavedFilter> all() {
    final rows = database.db.select('SELECT * FROM saved_filters ORDER BY created_at ASC');
    return rows
        .map((row) => SavedFilter(
              id: row['id'] as int,
              name: row['name'] as String,
              criteria: SavedFilter.decodeCriteria(row['criteria_json'] as String),
            ))
        .toList();
  }

  SavedFilter create(String name, FilterCriteria criteria) {
    final filter = SavedFilter(name: name, criteria: criteria);
    database.db.execute(
      'INSERT INTO saved_filters (name, criteria_json, created_at) VALUES (?, ?, ?)',
      [name, filter.encodeCriteria(), DateTime.now().millisecondsSinceEpoch],
    );
    final id = database.db.lastInsertRowId;
    return SavedFilter(id: id, name: name, criteria: criteria);
  }

  void update(int id, String name, FilterCriteria criteria) {
    database.db.execute(
      'UPDATE saved_filters SET name = ?, criteria_json = ? WHERE id = ?',
      [name, SavedFilter(name: name, criteria: criteria).encodeCriteria(), id],
    );
  }

  void delete(int id) {
    database.db.execute('DELETE FROM saved_filters WHERE id = ?', [id]);
  }
}
