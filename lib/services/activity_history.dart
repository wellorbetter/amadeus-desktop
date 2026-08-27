import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';

import 'app_paths.dart';
import 'pet_config.dart';
import 'pet_logger.dart';

class ActivitySnapshot {
  const ActivitySnapshot({
    required this.appName,
    required this.appId,
    required this.idleSeconds,
    required this.capturedAt,
  });

  factory ActivitySnapshot.fromMap(Map<Object?, Object?> map) {
    return ActivitySnapshot(
      appName: map['appName']?.toString().trim() ?? '',
      appId: map['appId']?.toString().trim() ?? '',
      idleSeconds: (map['idleSeconds'] as num?)?.toInt() ?? 0,
      capturedAt: DateTime.now(),
    );
  }

  final String appName;
  final String appId;
  final int idleSeconds;
  final DateTime capturedAt;
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
      final map = await _channel.invokeMapMethod<Object?, Object?>(
        'getSnapshot',
      );
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
    if (excluded || self) {
      _finishCurrent(snapshot.capturedAt);
      return;
    }

    final idle = snapshot.idleSeconds >= cfg.activityIdleSeconds;
    final appName = idle ? '空闲' : snapshot.appName;
    final key = idle ? '__idle__' : '${snapshot.appId}|$normalized';
    if (_currentKey != key) {
      _finishCurrent(snapshot.capturedAt);
      _startSession(snapshot, appName, idle, key);
    } else {
      _updateCurrent(snapshot.capturedAt);
    }
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
                .select('SELECT COUNT(*) AS n FROM usage_sessions')
                .first['n']
            as num)
        .toInt();
  }

  void clearSince(DateTime? since) {
    init();
    _finishCurrent(DateTime.now());
    if (since == null) {
      _database.execute('DELETE FROM usage_sessions');
    } else {
      _database.execute('DELETE FROM usage_sessions WHERE ended_at >= ?', [
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
