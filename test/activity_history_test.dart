import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/activity_history.dart';
import 'package:timepet/services/pet_config.dart';

void main() {
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

  test('consecutive snapshots become a local activity episode', () {
    final start = DateTime(2026, 8, 27, 9);
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
}
