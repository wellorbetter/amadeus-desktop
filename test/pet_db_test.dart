import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:timepet/services/pet_db.dart';

void main() {
  test('schema migration exposes memory and proactive audit operations', () {
    final root = Directory.systemTemp.createTempSync('amadeus-db-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final path = '${root.path}/mem.db';
    final database = PetDb(pathOverride: path, migrateLegacy: false)..init();
    addTearDown(database.dispose);

    expect(database.initialized, isTrue);
    expect(database.db.userVersion, PetDb.schemaVersion);

    database.addMemory('喜欢安静的界面', category: 'preference', importance: 3);
    final row = database.recentMemoryRows().single;
    database.updateMemory(
      row['id'] as int,
      content: '喜欢安静、低干扰的界面',
      category: 'preference',
      importance: 4,
    );
    expect(database.recentMemoryRows().single['importance'], 4);
    expect(database.recentMemoryRows().single['content'], '喜欢安静、低干扰的界面');

    final at = DateTime.utc(2026, 8, 27, 12, 30);
    database.recordProactiveEvent(
      triggerId: 'focus_reminder',
      label: '专注提醒',
      reason: '连续专注达到阈值',
      at: at,
    );
    final event = database.recentProactiveEvents().single;
    expect(event['trigger_id'], 'focus_reminder');
    expect(event['state'], 'fired');
    expect(database.latestProactiveAt(triggerId: 'focus_reminder'), at);
    expect(
      database.proactiveCountSince(at.subtract(const Duration(seconds: 1))),
      1,
    );

    database.setAgentState('observing', '正在观察', at: at);
    expect(database.agentState()?['state'], 'observing');
    expect(database.agentState()?['updatedAt'], at.toIso8601String());
  });

  test('corrupt database is preserved before automatic recovery', () {
    final root = Directory.systemTemp.createTempSync('amadeus-db-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final path = '${root.path}/mem.db';
    File(path).writeAsStringSync('not a sqlite database');
    final database = PetDb(pathOverride: path, migrateLegacy: false)..init();
    addTearDown(database.dispose);

    expect(database.initialized, isTrue);
    expect(database.db.userVersion, PetDb.schemaVersion);
    expect(
      root.listSync().whereType<File>().any(
        (file) => file.path.contains('mem.db.corrupt-'),
      ),
      isTrue,
    );

    database.dispose();
    final reopened = sqlite3.open(path);
    addTearDown(reopened.close);
    expect(reopened.userVersion, PetDb.schemaVersion);
  });

  test('newer schema is never overwritten during downgrade', () {
    final root = Directory.systemTemp.createTempSync('amadeus-db-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final path = '${root.path}/mem.db';
    final future = sqlite3.open(path)..userVersion = PetDb.schemaVersion + 10;
    future.close();

    final database = PetDb(pathOverride: path, migrateLegacy: false)..init();
    addTearDown(database.dispose);

    expect(database.initialized, isFalse);
    expect(
      root.listSync().whereType<File>().where(
        (file) => file.path.contains('.corrupt-'),
      ),
      isEmpty,
    );
    final unchanged = sqlite3.open(path);
    addTearDown(unchanged.close);
    expect(unchanged.userVersion, PetDb.schemaVersion + 10);
  });
}
