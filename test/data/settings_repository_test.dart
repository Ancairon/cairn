import 'package:test/test.dart';
import 'package:cairn/core/db/app_database.dart';
import 'package:cairn/data/repositories/settings_repository.dart';

void main() {
  test('persists rated albums presentation preferences', () {
    final db = AppDatabase.memory();
    final settings = SettingsRepository(db);

    expect(settings.ratedAlbumsSort(), isNull);
    expect(settings.ratedAlbumsView(), isNull);
    expect(settings.ratedAlbumsSize(), isNull);

    settings.setRatedAlbumsSort('artist');
    settings.setRatedAlbumsView('grid');
    settings.setRatedAlbumsSize('large');

    expect(settings.ratedAlbumsSort(), 'artist');
    expect(settings.ratedAlbumsView(), 'grid');
    expect(settings.ratedAlbumsSize(), 'large');

    expect(settings.autoBackupsEnabled(), isFalse);
    expect(settings.backupConsent(), isNull);
    settings.setBackupFolderPath('/tmp/cairn-backups');
    settings.setBackupConsent('accepted');
    settings.setAutoBackupsEnabled(true);
    expect(settings.autoBackupsEnabled(), isTrue);
    expect(settings.backupFolderPath(), '/tmp/cairn-backups');
    expect(settings.backupConsent(), 'accepted');

    db.close();
  });
}
