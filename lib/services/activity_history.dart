import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';

import 'app_paths.dart';
import 'pet_config.dart';
import 'pet_logger.dart';

enum ActivityDecision { active, idle, excluded }

class ActivitySnapshot {
  const ActivitySnapshot({
    required this.appName,
    required this.appId,
    required this.idleSeconds,
    required this.capturedAt,
    this.nativeDecision,
    this.nativeCoreVersion,
  });

  factory ActivitySnapshot.fromMap(Map<Object?, Object?> map) {
    return ActivitySnapshot(
      appName: map['appName']?.toString().trim() ?? '',
      appId: map['appId']?.toString().trim() ?? '',
      idleSeconds: (map['idleSeconds'] as num?)?.toInt() ?? 0,
      capturedAt: DateTime.now(),
      nativeDecision: switch ((map['decision'] as num?)?.toInt()) {
        0 => ActivityDecision.active,
        1 => ActivityDecision.idle,
        2 => ActivityDecision.excluded,
        _ => null,
      },
      nativeCoreVersion: (map['coreVersion'] as num?)?.toInt(),
    );
  }

  final String appName;
  final String appId;
  final int idleSeconds;
  final DateTime capturedAt;
  final ActivityDecision? nativeDecision;
  final int? nativeCoreVersion;
}

class ActivityEpisode {
  const ActivityEpisode({
    required this.id,
    required this.appName,
    required this.startedAt,
    required this.endedAt,
    required this.durationSeconds,
  });

  final int id;
  final String appName;
  final DateTime startedAt;
  final DateTime endedAt;
  final int durationSeconds;

  String get durationText {
    if (durationSeconds < 60) return '不到 1 分钟';
    final minutes = (durationSeconds / 60).round();
    if (minutes < 60) return '$minutes 分钟';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分钟';
  }
}

class ActivityDayPoint {
  const ActivityDayPoint({
    required this.date,
    required this.activeSeconds,
    required this.idleSeconds,
    required this.switches,
  });

  final DateTime date;
  final int activeSeconds;
  final int idleSeconds;
  final int switches;
}

class ActivityPulse {
  const ActivityPulse({
    required this.activeSeconds,
    required this.idleSeconds,
    required this.switches,
    required this.rawEvents,
    required this.topApp,
    required this.days,
  });

  final int activeSeconds;
  final int idleSeconds;
  final int switches;
  final int rawEvents;
  final String topApp;
  final List<ActivityDayPoint> days;

  int get focusScore {
    if (activeSeconds == 0) return 0;
    final total = (activeSeconds + idleSeconds).clamp(1, 1 << 62).toInt();
    final activeRatio = activeSeconds * 100 ~/ total;
    final switchPenalty = (switches - 12).clamp(0, 40).toInt();
    return (activeRatio - switchPenalty).clamp(0, 100).toInt();
  }
}

typedef ActivitySnapshotProvider = Future<ActivitySnapshot?> Function();

/// Built-in, local-only activity event stream inspired by Computer History.
///
/// The native layer exposes only the frontmost application identity and idle
/// duration. No screenshots, audio, window titles, file paths, or typed text
/// are collected. Raw sessions expire automatically and are stored separately
/// from Amadeus long-term memory.
class ActivityHistory {
  ActivityHistory({String? pathOverride, ActivitySnapshotProvider? provider})
    : _pathOverride = pathOverride,
      _provider = provider;

  static final ActivityHistory instance = ActivityHistory();
  static const MethodChannel _channel = MethodChannel('amadeus/activity');
  static const Duration pollInterval = Duration(seconds: 10);

  final String? _pathOverride;
  final ActivitySnapshotProvider? _provider;
  Database? _db;
  Timer? _timer;
  bool _capturing = false;
  int? _currentId;
  String? _currentKey;
  DateTime? _currentStartedAt;
  DateTime? _lastPurgeAt;

  String get path => _pathOverride ?? AppPaths.activityFile.path;
  bool get initialized => _db != null;

  Database get _database {
    final value = _db;
    if (value == null) throw StateError('ActivityHistory not initialized');
    return value;
  }

  void init() {
    if (_db != null) return;
    final file = File(path);
    file.parent.createSync(recursive: true);
    _db = sqlite3.open(path);
    _database
      ..execute('PRAGMA journal_mode=WAL')
      ..execute('PRAGMA synchronous=NORMAL')
      ..execute('PRAGMA busy_timeout=5000')
      ..execute(
        'CREATE TABLE IF NOT EXISTS usage_sessions('
        'id INTEGER PRIMARY KEY AUTOINCREMENT,'
        "app_path TEXT NOT NULL DEFAULT '',"
        'app_name TEXT NOT NULL,'
        'window_title TEXT,'
        'started_at TEXT NOT NULL,'
        'ended_at TEXT,'
        'duration_secs INTEGER NOT NULL DEFAULT 0,'
        'is_idle INTEGER NOT NULL DEFAULT 0,'
        'date TEXT NOT NULL)',
      )
      ..execute(
        'CREATE INDEX IF NOT EXISTS idx_activity_date '
        'ON usage_sessions(date)',
      )
      ..execute(
        'CREATE INDEX IF NOT EXISTS idx_activity_ended '
        'ON usage_sessions(ended_at)',
      )
      ..execute(
        'CREATE TABLE IF NOT EXISTS activity_events('
        'sequence INTEGER PRIMARY KEY AUTOINCREMENT,'
        'app_id TEXT NOT NULL,'
        'app_name TEXT NOT NULL,'
        'captured_at TEXT NOT NULL,'
        'idle_secs INTEGER NOT NULL DEFAULT 0,'
        'state TEXT NOT NULL,'
        'date TEXT NOT NULL)',
      )
      ..execute(
        'CREATE INDEX IF NOT EXISTS idx_activity_events_date '
        'ON activity_events(date, captured_at)',
      );
  }

  void start() {
    if (_timer != null) return;
    init();
    unawaited(capture());
    _timer = Timer.periodic(pollInterval, (_) => unawaited(capture()));
    PetLog.i('activity: built-in sensor started (10s)');
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _finishCurrent(DateTime.now());
  }

  Future<void> capture() async {
    final cfg = PetConfig.instance;
    if (!cfg.activityAwarenessEnabled || cfg.activityAwarenessPaused) {
      _finishCurrent(DateTime.now());
      return;
    }
    if (_capturing) return;
    _capturing = true;
    try {
      init();
      final snapshot = await (_provider?.call() ?? _nativeSnapshot());
      if (snapshot == null || snapshot.appName.isEmpty) return;
      recordSnapshot(snapshot);
      final now = DateTime.now();
      if (_lastPurgeAt == null ||
          now.difference(_lastPurgeAt!) > const Duration(hours: 1)) {
        purge(retentionHours: cfg.activityRetentionHours);
        _lastPurgeAt = now;
      }
    } catch (error) {
      PetLog.w('activity: capture failed: $error');
    } finally {
      _capturing = false;
    }
  }

  Future<ActivitySnapshot?> _nativeSnapshot() async {
    if (!Platform.isWindows && !Platform.isMacOS) return null;
    try {
      final map = await _channel
          .invokeMapMethod<Object?, Object?>('getSnapshot', {
            'idleThreshold': PetConfig.instance.activityIdleSeconds,
            'excludedApps': PetConfig.instance.activityExcludedApps,
          });
      return map == null ? null : ActivitySnapshot.fromMap(map);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      PetLog.w('activity: native sensor unavailable: ${error.code}');
      return null;
    }
  }

  void recordSnapshot(ActivitySnapshot snapshot) {
    init();
    final cfg = PetConfig.instance;
    final normalized = snapshot.appName.toLowerCase();
    final excluded = cfg.activityExcludedApps.any((entry) {
      final candidate = entry.trim().toLowerCase();
      return candidate.isNotEmpty &&
          (normalized == candidate || normalized.contains(candidate));
    });
    final self = const {
      'timepet',
      'timepet.exe',
      'amadeus',
      'amadeus.exe',
      'amadeus-desktop',
      'amadeus-desktop.exe',
    }.contains(normalized);
    final decision = snapshot.nativeCoreVersion == 1
        ? snapshot.nativeDecision
        : null;
    if (excluded || self || decision == ActivityDecision.excluded) {
      _finishCurrent(snapshot.capturedAt);
      return;
    }

    final idle =
        decision == ActivityDecision.idle ||
        (decision == null && snapshot.idleSeconds >= cfg.activityIdleSeconds);
    final appName = idle ? '空闲' : snapshot.appName;
    final key = idle ? '__idle__' : '${snapshot.appId}|$normalized';
    _appendEvent(snapshot, appName, idle);
    if (_currentKey != key) {
      _finishCurrent(snapshot.capturedAt);
      _startSession(snapshot, appName, idle, key);
    } else {
      _updateCurrent(snapshot.capturedAt);
    }
  }

  void _appendEvent(ActivitySnapshot snapshot, String appName, bool idle) {
    _database.execute(
      'INSERT INTO activity_events('
      'app_id, app_name, captured_at, idle_secs, state, date) '
      'VALUES(?, ?, ?, ?, ?, ?)',
      [
        snapshot.appId,
        appName,
        snapshot.capturedAt.toIso8601String(),
        snapshot.idleSeconds,
        idle ? 'idle' : 'active',
        _dateKey(snapshot.capturedAt),
      ],
    );
  }

  void _startSession(
    ActivitySnapshot snapshot,
    String appName,
    bool idle,
    String key,
  ) {
    final started = snapshot.capturedAt;
    _database.execute(
      'INSERT INTO usage_sessions('
      'app_path, app_name, window_title, started_at, ended_at, '
      'duration_secs, is_idle, date) VALUES(?, ?, NULL, ?, ?, 0, ?, ?)',
      [
        snapshot.appId,
        appName,
        started.toIso8601String(),
        started.toIso8601String(),
        idle ? 1 : 0,
        _dateKey(started),
      ],
    );
    _currentId = _database.lastInsertRowId;
    _currentKey = key;
    _currentStartedAt = started;
  }

  void _updateCurrent(DateTime ended) {
    final id = _currentId;
    final started = _currentStartedAt;
    if (id == null || started == null) return;
    final duration = ended.difference(started).inSeconds.clamp(0, 86400);
    _database.execute(
      'UPDATE usage_sessions SET ended_at = ?, duration_secs = ? '
      'WHERE id = ?',
      [ended.toIso8601String(), duration, id],
    );
  }

  void _finishCurrent(DateTime ended) {
    if (_db != null) _updateCurrent(ended);
    _currentId = null;
    _currentKey = null;
    _currentStartedAt = null;
  }

  List<ActivityEpisode> recentEpisodes({int limit = 12}) {
    init();
    return _database
        .select(
          'SELECT id, app_name, started_at, ended_at, duration_secs '
          'FROM usage_sessions WHERE is_idle = 0 AND duration_secs > 0 '
          'ORDER BY started_at DESC LIMIT ?',
          [limit],
        )
        .map((row) {
          final started = DateTime.tryParse('${row['started_at']}');
          final ended = DateTime.tryParse('${row['ended_at']}');
          return ActivityEpisode(
            id: (row['id'] as num).toInt(),
            appName: '${row['app_name']}',
            startedAt: started ?? DateTime.fromMillisecondsSinceEpoch(0),
            endedAt: ended ?? started ?? DateTime.fromMillisecondsSinceEpoch(0),
            durationSeconds: (row['duration_secs'] as num?)?.toInt() ?? 0,
          );
        })
        .toList(growable: false);
  }

  int eventCount() {
    init();
    return (_database
                .select('SELECT COUNT(*) AS n FROM activity_events')
                .first['n']
            as num)
        .toInt();
  }

  ActivityPulse pulse({int days = 7}) {
    init();
    final safeDays = days.clamp(1, 31).toInt();
    final now = DateTime.now();
    final points = <ActivityDayPoint>[];
    for (var offset = safeDays - 1; offset >= 0; offset--) {
      final date = now.subtract(Duration(days: offset));
      final rows = _database.select(
        'SELECT duration_secs, is_idle FROM usage_sessions WHERE date = ?',
        [_dateKey(date)],
      );
      var active = 0;
      var idle = 0;
      var switches = 0;
      for (final row in rows) {
        final seconds = (row['duration_secs'] as num?)?.toInt() ?? 0;
        if ((row['is_idle'] as num?)?.toInt() == 1) {
          idle += seconds;
        } else {
          active += seconds;
          switches++;
        }
      }
      points.add(
        ActivityDayPoint(
          date: date,
          activeSeconds: active,
          idleSeconds: idle,
          switches: switches,
        ),
      );
    }

    final today = points.last;
    final topRows = _database.select(
      'SELECT app_name, SUM(duration_secs) AS seconds '
      'FROM usage_sessions WHERE date = ? AND is_idle = 0 '
      'GROUP BY app_name ORDER BY seconds DESC LIMIT 1',
      [_dateKey(now)],
    );
    final rawRows = _database.select(
      'SELECT COUNT(*) AS n FROM activity_events WHERE date = ?',
      [_dateKey(now)],
    );
    return ActivityPulse(
      activeSeconds: today.activeSeconds,
      idleSeconds: today.idleSeconds,
      switches: today.switches,
      rawEvents: (rawRows.first['n'] as num).toInt(),
      topApp: topRows.isEmpty ? '暂无' : '${topRows.first['app_name']}',
      days: List.unmodifiable(points),
    );
  }

  void clearSince(DateTime? since) {
    init();
    _finishCurrent(DateTime.now());
    if (since == null) {
      _database
        ..execute('DELETE FROM activity_events')
        ..execute('DELETE FROM usage_sessions');
    } else {
      _database
        ..execute('DELETE FROM activity_events WHERE captured_at >= ?', [
          since.toIso8601String(),
        ])
        ..execute('DELETE FROM usage_sessions WHERE ended_at >= ?', [
          since.toIso8601String(),
        ]);
    }
  }

  void purge({required int retentionHours}) {
    init();
    final cutoff = DateTime.now().subtract(Duration(hours: retentionHours));
    _database.execute('DELETE FROM usage_sessions WHERE ended_at < ?', [
      cutoff.toIso8601String(),
    ]);
    _database.execute('DELETE FROM activity_events WHERE captured_at < ?', [
      cutoff.toIso8601String(),
    ]);
  }

  void close() {
    stop();
    _db?.close();
    _db = null;
  }

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
