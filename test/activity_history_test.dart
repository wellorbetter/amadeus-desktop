import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:timepet/services/activity_history.dart';
import 'package:timepet/services/pet_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('activity database preserves corrupt file and recreates schema', () {
    final root = Directory.systemTemp.createTempSync('amadeus-activity-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final path = '${root.path}/activity.db';
    File(path).writeAsStringSync('broken sqlite');
    final history = ActivityHistory(pathOverride: path)..init();
    addTearDown(history.close);

    expect(history.initialized, isTrue);
    expect(
      root.listSync().whereType<File>().any(
        (file) => file.path.contains('activity.db.corrupt-'),
      ),
      isTrue,
    );
  });

  test('newer activity schema is never overwritten during downgrade', () {
    final root = Directory.systemTemp.createTempSync('amadeus-activity-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final path = '${root.path}/activity.db';
    final future = sqlite3.open(path)
      ..userVersion = ActivityHistory.schemaVersion + 10;
    future.close();

    final history = ActivityHistory(pathOverride: path)..init();
    addTearDown(history.close);

    expect(history.initialized, isFalse);
    final unchanged = sqlite3.open(path);
    addTearDown(unchanged.close);
    expect(unchanged.userVersion, ActivityHistory.schemaVersion + 10);
    expect(
      root.listSync().whereType<File>().where(
        (file) => file.path.contains('.corrupt-'),
      ),
      isEmpty,
    );
  });

  late Directory root;
  late ActivityHistory history;

  setUp(() {
    root = Directory.systemTemp.createTempSync('amadeus-activity-test-');
    history = ActivityHistory(pathOverride: '${root.path}/activity.db');
    final cfg = PetConfig.instance;
    cfg.activityAwarenessEnabled = true;
    cfg.activityAwarenessPaused = false;
    cfg.activityIdleSeconds = 300;
    cfg.activityExcludedApps = const [];
  });

  tearDown(() {
    history.close();
    root.deleteSync(recursive: true);
    PetConfig.instance.resetToDefaults(persist: false);
  });

  test(
    'Linux native channel sample enters the local observation stream',
    () async {
      if (!Platform.isLinux) return;
      const channel = MethodChannel('amadeus/activity');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getSnapshot');
        expect(call.arguments, isA<Map<Object?, Object?>>());
        return <Object?, Object?>{
          'appName': 'Code',
          'appId': 'linux:Code',
          'idleSeconds': 7,
          'decision': 0,
          'coreVersion': 1,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await history.capture();

      expect(history.sensorStatus, ActivitySensorStatus.available);
      expect(history.hasCurrentSnapshot, isTrue);
      expect(history.currentForegroundApp, 'Code');
      expect(history.eventCount(), 1);
    },
  );

  test(
    'Linux Wayland sensor failure remains explicit and fail-closed',
    () async {
      if (!Platform.isLinux) return;
      const channel = MethodChannel('amadeus/activity');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) => throw PlatformException(
          code: 'unsupported_session',
          message: 'Wayland global activity is unavailable.',
        ),
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await history.capture();

      expect(history.sensorStatus, ActivitySensorStatus.unsupportedSession);
      expect(history.hasCurrentSnapshot, isFalse);
      expect(history.eventCount(), 0);
    },
  );

  test('consecutive snapshots become a local activity episode', () {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 9);
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Android Studio',
        appId: 'com.google.android.studio',
        idleSeconds: 0,
        capturedAt: start,
      ),
    );
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Android Studio',
        appId: 'com.google.android.studio',
        idleSeconds: 0,
        capturedAt: start.add(const Duration(seconds: 65)),
      ),
    );
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Terminal',
        appId: 'com.apple.Terminal',
        idleSeconds: 0,
        capturedAt: start.add(const Duration(seconds: 70)),
      ),
    );

    final episodes = history.recentEpisodes();
    expect(
      episodes.map((episode) => episode.appName),
      contains('Android Studio'),
    );
    final studio = episodes.firstWhere(
      (episode) => episode.appName == 'Android Studio',
    );
    expect(studio.durationSeconds, 70);
    expect(history.eventCount(), 3);
    final pulse = history.pulse();
    expect(pulse.topApp, 'Android Studio');
    expect(pulse.activeSeconds, 70);
    expect(pulse.rawEvents, 3);
  });

  test('native Rust privacy decision fails closed before persistence', () {
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Secret Workspace',
        appId: 'secret.app',
        idleSeconds: 0,
        capturedAt: DateTime.now(),
        nativeDecision: ActivityDecision.excluded,
        nativeCoreVersion: 1,
      ),
    );

    expect(history.eventCount(), 0);
    expect(history.recentEpisodes(), isEmpty);
  });

  test('current idle state uses the native duration, not daily totals', () {
    final now = DateTime.now();
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Editor',
        appId: 'editor.app',
        idleSeconds: 900,
        capturedAt: now,
      ),
    );
    expect(history.currentlyIdle, isTrue);
    expect(history.currentIdleSeconds, 900);
    expect(history.hasCurrentSnapshot, isTrue);
    expect(history.currentForegroundApp, '空闲');

    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Editor',
        appId: 'editor.app',
        idleSeconds: 0,
        capturedAt: now.add(const Duration(seconds: 10)),
      ),
    );
    expect(history.currentlyIdle, isFalse);
    expect(history.currentIdleSeconds, 0);
    expect(history.currentForegroundApp, 'Editor');
  });

  test('excluded apps and idle sessions do not appear in the timeline', () {
    PetConfig.instance.activityExcludedApps = const ['Password'];
    final start = DateTime(2026, 8, 27, 10);
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Password Manager',
        appId: 'secret.app',
        idleSeconds: 0,
        capturedAt: start,
      ),
    );
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Editor',
        appId: 'editor.app',
        idleSeconds: 600,
        capturedAt: start.add(const Duration(minutes: 1)),
      ),
    );
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Browser',
        appId: 'browser.app',
        idleSeconds: 0,
        capturedAt: start.add(const Duration(minutes: 2)),
      ),
    );

    expect(history.recentEpisodes(), isEmpty);
  });

  test('raw activity can be cleared by time range', () {
    final start = DateTime.now().subtract(const Duration(minutes: 30));
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Editor',
        appId: 'editor.app',
        idleSeconds: 0,
        capturedAt: start,
      ),
    );
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Terminal',
        appId: 'terminal.app',
        idleSeconds: 0,
        capturedAt: start.add(const Duration(minutes: 5)),
      ),
    );
    expect(history.eventCount(), 2);

    history.clearSince(DateTime.now().subtract(const Duration(hours: 1)));
    expect(history.eventCount(), 0);
  });

  test('one session is split at local midnight', () {
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    final start = DateTime(
      yesterday.year,
      yesterday.month,
      yesterday.day,
      23,
      59,
    );
    final nextDay = DateTime(start.year, start.month, start.day + 1);
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Editor',
        appId: 'editor.app',
        idleSeconds: 0,
        capturedAt: start,
      ),
    );
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Editor',
        appId: 'editor.app',
        idleSeconds: 0,
        capturedAt: nextDay.add(const Duration(minutes: 1)),
      ),
    );
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Terminal',
        appId: 'terminal.app',
        idleSeconds: 0,
        capturedAt: nextDay.add(const Duration(minutes: 2)),
      ),
    );

    final database = sqlite3.open(history.path, mode: OpenMode.readOnly);
    addTearDown(database.close);
    final rows = database.select(
      "SELECT date, duration_secs FROM usage_sessions WHERE app_name = 'Editor' "
      'ORDER BY started_at',
    );
    expect(rows, hasLength(2));
    expect(rows[0]['duration_secs'], 60);
    expect(rows[1]['duration_secs'], 120);
    expect(rows[0]['date'], isNot(rows[1]['date']));
  });

  test('range clearing truncates a crossing session at the cutoff', () {
    final now = DateTime.now();
    final start = now.subtract(const Duration(hours: 2));
    final cutoff = now.subtract(const Duration(hours: 1));
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Editor',
        appId: 'editor.app',
        idleSeconds: 0,
        capturedAt: start,
      ),
    );
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Terminal',
        appId: 'terminal.app',
        idleSeconds: 0,
        capturedAt: now,
      ),
    );

    history.clearSince(cutoff);

    final database = sqlite3.open(history.path, mode: OpenMode.readOnly);
    addTearDown(database.close);
    final rows = database.select(
      "SELECT ended_at, duration_secs FROM usage_sessions WHERE app_name = 'Editor'",
    );
    expect(rows, hasLength(1));
    expect(rows.single['ended_at'], cutoff.toIso8601String());
    expect(rows.single['duration_secs'], 3600);
  });

  test('retention truncates a crossing session without retaining old time', () {
    final now = DateTime.now();
    final start = now.subtract(const Duration(hours: 3));
    final cutoff = now.subtract(const Duration(hours: 2));
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Editor',
        appId: 'editor.app',
        idleSeconds: 0,
        capturedAt: start,
      ),
    );
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Terminal',
        appId: 'terminal.app',
        idleSeconds: 0,
        capturedAt: now.subtract(const Duration(hours: 1)),
      ),
    );

    history.purge(retentionHours: 2, now: now);

    final database = sqlite3.open(history.path, mode: OpenMode.readOnly);
    addTearDown(database.close);
    final rows = database.select(
      "SELECT started_at, duration_secs FROM usage_sessions WHERE app_name = 'Editor'",
    );
    expect(rows, hasLength(1));
    expect(rows.single['started_at'], cutoff.toIso8601String());
    expect(rows.single['duration_secs'], 3600);
  });

  test(
    'writer recreates its current session after another engine clears it',
    () {
      final clearer = ActivityHistory(pathOverride: history.path)..init();
      addTearDown(clearer.close);
      final now = DateTime.now();
      history.recordSnapshot(
        ActivitySnapshot(
          appName: 'Editor',
          appId: 'editor.app',
          idleSeconds: 0,
          capturedAt: now,
        ),
      );

      clearer.clearSince(null);
      history.recordSnapshot(
        ActivitySnapshot(
          appName: 'Editor',
          appId: 'editor.app',
          idleSeconds: 0,
          capturedAt: now.add(const Duration(seconds: 10)),
        ),
      );

      expect(history.eventCount(), 1);
      final database = sqlite3.open(history.path, mode: OpenMode.readOnly);
      addTearDown(database.close);
      expect(
        database.select('SELECT COUNT(*) AS n FROM usage_sessions').first['n'],
        1,
      );
    },
  );
}
