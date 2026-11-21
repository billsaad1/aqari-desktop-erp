import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:app/services/automatic_backup_service.dart';

void main() {
  test('retention removes only older automatic snapshots', () async {
    final directory = await Directory.systemTemp.createTemp('aqari-backup-');
    addTearDown(() => directory.delete(recursive: true));

    final oldest = File(
      '${directory.path}/aqari_auto_backup_20260101_000000_000001.db',
    );
    final newer = File(
      '${directory.path}/aqari_auto_backup_20260102_000000_000001.db',
    );
    final newest = File(
      '${directory.path}/aqari_auto_backup_20260103_000000_000001.db',
    );
    final manual = File('${directory.path}/aqari_erp_backup_20260101.db');
    final restore = File('${directory.path}/aqari_pre_restore_20260101.db');
    for (final file in [oldest, newer, newest, manual, restore]) {
      await file.writeAsString('snapshot');
    }

    await AutomaticBackupService.pruneAutoBackups(directory, keepNewest: 2);

    expect(await oldest.exists(), isFalse);
    expect(await newer.exists(), isTrue);
    expect(await newest.exists(), isTrue);
    expect(await manual.exists(), isTrue);
    expect(await restore.exists(), isTrue);
  });

  test('retries failed destination without repeating a recent success', () {
    final now = DateTime.utc(2026, 1, 2, 12);
    final due = AutomaticBackupService.dueBackupDirectories(
      directories: const ['/local/backups', '/usb/backups'],
      successfulAtMsByPath: {
        '/local/backups': now
            .subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      },
      now: now,
    );

    expect(due, ['/usb/backups']);
    expect(
      AutomaticBackupService.dueBackupDirectories(
        directories: const ['/local/backups', '/usb/backups'],
        successfulAtMsByPath: {
          '/local/backups': now
              .subtract(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        },
        now: now,
        force: true,
      ),
      ['/local/backups', '/usb/backups'],
    );
  });
}
