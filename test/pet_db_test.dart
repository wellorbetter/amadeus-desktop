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
    database.recordProactiveEvent(
      triggerId: 'memory_nudge',
      label: '记忆关心',
      reason: '生成失败，未展示',
      state: 'failed',
      at: at.add(const Duration(minutes: 1)),
    );
    expect(database.latestProactiveAt(triggerId: 'memory_nudge'), isNull);
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

  test('v2 activity-derived facts are removed from long-term memory', () {
    final root = Directory.systemTemp.createTempSync('amadeus-db-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final path = '${root.path}/mem.db';
    final legacy = sqlite3.open(path)
      ..execute(
        'CREATE TABLE daily_facts('
        'date TEXT PRIMARY KEY, active_min INTEGER, idle_min INTEGER, '
        'top_apps TEXT, peak_hours TEXT, diary_has INTEGER)',
      )
      ..execute(
        "INSERT INTO daily_facts VALUES('2026-08-26', 300, 20, '[]', '[]', 0)",
      )
      ..execute(
        'CREATE TABLE memories('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT NOT NULL, '
        'category TEXT NOT NULL, importance INTEGER NOT NULL, ts TEXT NOT NULL, '
        'source TEXT NOT NULL, active INTEGER NOT NULL)',
      )
      ..execute(
        "INSERT INTO memories(content, category, importance, ts, source, active) "
        "VALUES('保留这条用户记忆', 'fact', 3, '2026-08-26', 'audit', 1)",
      );
    legacy.userVersion = 2;
    legacy.close();

    final database = PetDb(pathOverride: path, migrateLegacy: false)..init();
    addTearDown(database.dispose);

    final tables = database.db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'daily_facts'",
    );
    expect(tables, isEmpty);
    expect(database.recentMemoryRows().single['content'], '保留这条用户记忆');
  });
}
