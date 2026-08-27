import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'activity_history.dart';
import 'app_paths.dart';
import 'observation_source.dart';
import 'pet_config.dart';

/// 单日聚合数据（来自本地 8788 /api/history）。
class DayInfo {
  DayInfo({
    required this.date,
    required this.activeMin,
    required this.idleMin,
    required this.topApps,
    required this.peakHours,
    required this.diaryHas,
  });

  factory DayInfo.fromJson(Map<String, dynamic> json) {
    final apps = (json['top_apps'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (e) => AppUsage(
            name: e['app']?.toString() ?? '?',
            minutes: e['minutes'] is num ? (e['minutes'] as num).toInt() : 0,
          ),
        )
        .where((a) => a.minutes > 0 && !TtApi.isSelfApp(a.name))
        .toList();
    final peak = (json['peak_hours'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((e) => e['hour'] is num)
        .map(
          (e) => HourUsage(
            hour: e['hour'] is num ? (e['hour'] as num).toInt() : 0,
            minutes: e['minutes'] is num ? (e['minutes'] as num).toInt() : 0,
          ),
        )
        .toList();
    final diary = json['diary'];
    return DayInfo(
      date: json['date']?.toString() ?? '',
      activeMin: json['active_min'] is num
          ? (json['active_min'] as num).toInt()
          : 0,
      idleMin: json['idle_min'] is num ? (json['idle_min'] as num).toInt() : 0,
      topApps: apps,
      peakHours: peak,
      diaryHas: diary is Map<String, dynamic>
          ? (diary['has_entry'] as bool? ?? false)
          : false,
    );
  }

  final String date;
  final int activeMin;
  final int idleMin;
  final List<AppUsage> topApps;
  final List<HourUsage> peakHours;
  final bool diaryHas;

  /// 「昨天（8月7日）」这类可读日期名。
  String get readableDate {
    final parts = date.split('-');
    if (parts.length != 3) return date;
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (month == null || day == null) return date;
    return '$month月$day日';
  }

  String get activeText {
    final h = activeMin ~/ 60;
    final m = activeMin % 60;
    if (h == 0) return '$m 分钟';
    if (m == 0) return '$h 小时';
    return '$h 小时 $m 分';
  }

  String get topAppsText {
    if (topApps.isEmpty) return '无';
    return topApps.take(4).map((a) => '${a.name} ${a.minutes} 分钟').join('、');
  }
}

class AppUsage {
  AppUsage({required this.name, required this.minutes});
  final String name;
  final int minutes;
}

class HourUsage {
  HourUsage({required this.hour, required this.minutes});
  final int hour;
  final int minutes;
}

/// Amadeus activity awareness. New activity is captured in-process; existing
/// TimeTrace databases and the old local HTTP bridge remain migration inputs.
class TtApi implements ObservationSource {
  @override
  String get id => 'activity_awareness';

  @override
  String get displayName => '活动感知';
  TtApi({String? base})
    : base =
          base ??
          (Platform.environment['TIMEPET_TT_API'] ?? 'http://127.0.0.1:8788');

  final String base;
  String _foreground = '-';
  int _activeMin = 0;
  int _switches = 0;
  int _idleMin = 0;
  String _topApp = '-';
  String _lastActive = '-';
  String _nowHour = '';
  int _currentIdleSeconds = 0;
  bool _currentlyIdle = false;
  DateTime? _lastSync;
  DateTime? _lastHistoryAt; // 历史日聚合缓存时间（5 分钟刷一次）
  final List<DayInfo> _history = [];

  /// 历史数据缓存间隔：每 60 秒 tick 只拉实时 context，历史 7 天聚合 5 分钟刷一次。
  static const Duration _historyCache = Duration(minutes: 5);

  @override
  bool get hasData => _lastSync != null;
  bool get hasHistory => _history.isNotEmpty;
  List<DayInfo> get history => List.unmodifiable(_history);

  int get activeMinutes => _activeMin;
  int get idleMinutes => _idleMin;
  int get switches => _switches;
  String get foregroundApp => _foreground;
  int get currentIdleSeconds => _currentIdleSeconds;
  bool get currentlyIdle => _currentlyIdle;

  void start() => ActivityHistory.instance.start();
  void stop() => ActivityHistory.instance.stop();

  static bool isSelfApp(String value) {
    final name = value.trim().toLowerCase();
    return const {
      'timepet',
      'timepet.exe',
      'amadeus',
      'amadeus.exe',
      'amadeus-desktop',
      'amadeus-desktop.exe',
    }.contains(name);
  }

  @override
  Future<bool> refresh() async {
    final cfg = PetConfig.instance;
    if (!cfg.activityAwarenessEnabled || cfg.activityAwarenessPaused) {
      _clear();
      return false;
    }
    await ActivityHistory.instance.capture();
    _currentIdleSeconds = ActivityHistory.instance.currentIdleSeconds;
    _currentlyIdle = ActivityHistory.instance.currentlyIdle;
    final currentIdleSeconds = _currentIdleSeconds;
    final currentlyIdle = _currentlyIdle;
    final currentForeground = ActivityHistory.instance.currentForegroundApp;

    // The built-in short-lived activity database is now the primary source.
    // Legacy TimeTrace files remain later candidates for seamless migration.
    if (_refreshFromLocalDatabase()) {
      _lastSync = DateTime.now();
      return true;
    }

    // An empty local timeline clears stale aggregates, but the direct native
    // idle reading is still valid and must survive the legacy HTTP fallback.
    _currentIdleSeconds = currentIdleSeconds;
    _currentlyIdle = currentlyIdle;
    _foreground = currentForeground;
    _nowHour = DateTime.now().hour.toString();
    if (ActivityHistory.instance.hasCurrentSnapshot) _lastActive = '刚刚';

    var ok = false;
    try {
      final ctx = await _getJson('/api/context');
      if (ctx != null) {
        final foreground = (ctx['foreground_app'] as String?) ?? '-';
        _foreground = isSelfApp(foreground) ? '-' : foreground;
        _activeMin = (ctx['today']?['active_min'] as num?)?.toInt() ?? 0;
        _idleMin = (ctx['today']?['idle_min'] as num?)?.toInt() ?? 0;
        _switches = (ctx['today']?['switches'] as num?)?.toInt() ?? 0;
        final top = (ctx['today']?['top_app'] as String?) ?? '-';
        _topApp = isSelfApp(top) ? '-' : top;
        _lastActive = (ctx['last_active_at'] as String?) ?? '-';
        _nowHour = (ctx['now_hour'] as num?)?.toString() ?? '';
        ok = true;
      }
    } catch (e) {
      stderr.writeln('TtApi context failed: $e');
    }

    // 历史日聚合（昨天、前天等）：5 分钟缓存，避免每 60 秒拉一次 7 天数据
    final historyDue =
        _lastHistoryAt == null ||
        DateTime.now().difference(_lastHistoryAt!) >= _historyCache;
    if (historyDue) {
      try {
        final hist = await _getJson('/api/history?days=7');
        if (hist != null && hist['days'] is List) {
          _history
            ..clear()
            ..addAll(
              (hist['days'] as List)
                  .whereType<Map<String, dynamic>>()
                  .map(DayInfo.fromJson)
                  .where((d) => d.date.isNotEmpty),
            );
          _lastHistoryAt = DateTime.now();
          ok = true;
        }
      } catch (e) {
        stderr.writeln('TtApi history failed: $e');
      }
    } else {
      // 缓存期内：context 成功即可认为有数据，避免把缓存的历史误判为离线
      ok = ok || hasHistory;
    }

    // A native snapshot is already useful for current idle/return detection,
    // even before its first usage session accumulates a positive duration.
    ok = ok || ActivityHistory.instance.hasCurrentSnapshot;
    if (ok) _lastSync = DateTime.now();
    return ok;
  }

  void _clear() {
    _foreground = '-';
    _activeMin = 0;
    _switches = 0;
    _idleMin = 0;
    _topApp = '-';
    _lastActive = '-';
    _nowHour = '';
    _currentIdleSeconds = 0;
    _currentlyIdle = false;
    _lastSync = null;
    _lastHistoryAt = null;
    _history.clear();
  }

  /// Reads Amadeus' built-in event store first, then optional legacy TimeTrace
  /// databases. The old HTTP bridge is used when local stores have no usable
  /// aggregate yet, which keeps a fresh install compatible during warm-up.
  bool _refreshFromLocalDatabase() {
    var foundDatabase = false;
    for (final candidate in AppPaths.timeTraceDatabases) {
      if (!candidate.existsSync()) continue;
      foundDatabase = true;
      Database? db;
      try {
        db = sqlite3.open(candidate.path, mode: OpenMode.readOnly);
        final today = _dateKey(DateTime.now());
        final sessions = _sessions(db, today);

        final candidateHistory = <DayInfo>[];
        for (var daysAgo = 7; daysAgo >= 1; daysAgo--) {
          final date = DateTime.now().subtract(Duration(days: daysAgo));
          final key = _dateKey(date);
          final daySessions = _sessions(db, key);
          var activeSeconds = 0;
          var idleSeconds = 0;
          final apps = <String, int>{};
          final hours = <int, int>{};
          for (final row in daySessions) {
            final seconds = (row['duration_secs'] as num?)?.toInt() ?? 0;
            final idle = (row['is_idle'] as num?)?.toInt() == 1;
            if (idle) {
              idleSeconds += seconds;
              continue;
            }
            activeSeconds += seconds;
            final app = '${row['app_name'] ?? '-'}';
            if (!isSelfApp(app)) apps[app] = (apps[app] ?? 0) + seconds;
            final started = '${row['started_at'] ?? ''}';
            final hour = started.length >= 13
                ? int.tryParse(started.substring(11, 13))
                : null;
            if (hour != null) hours[hour] = (hours[hour] ?? 0) + seconds;
          }
          final sortedApps = apps.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          final sortedHours = hours.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          var diaryHas = false;
          try {
            diaryHas = db.select(
              'SELECT 1 FROM diary_entries WHERE date = ? LIMIT 1',
              [key],
            ).isNotEmpty;
          } catch (_) {}
          candidateHistory.add(
            DayInfo(
              date: key,
              activeMin: (activeSeconds / 60).round(),
              idleMin: (idleSeconds / 60).round(),
              topApps: sortedApps
                  .take(8)
                  .map(
                    (entry) => AppUsage(
                      name: entry.key,
                      minutes: (entry.value / 60).round(),
                    ),
                  )
                  .toList(),
              peakHours: sortedHours
                  .take(3)
                  .map(
                    (entry) => HourUsage(
                      hour: entry.key,
                      minutes: (entry.value / 60).round(),
                    ),
                  )
                  .toList(),
              diaryHas: diaryHas,
            ),
          );
        }

        // The built-in database is created on first launch. Do not let an
        // empty file hide a user's existing TimeTrace history during the
        // migration period; move on to the next compatibility source first.
        final hasTodayData = sessions.any(
          (row) => ((row['duration_secs'] as num?)?.toInt() ?? 0) > 0,
        );
        final hasHistoricalData = candidateHistory.any(
          (day) => day.activeMin > 0 || day.idleMin > 0 || day.diaryHas,
        );
        if (!hasTodayData && !hasHistoricalData) continue;

        _applyToday(sessions);
        _history
          ..clear()
          ..addAll(candidateHistory);
        _lastHistoryAt = DateTime.now();
        return true;
      } catch (error) {
        stderr.writeln('Activity history read failed: $error');
      } finally {
        db?.close();
      }
    }
    if (foundDatabase) _clear();
    // An empty built-in database must not suppress the legacy HTTP migration
    // source or make zero values look like a successful observation.
    return false;
  }

  ResultSet _sessions(Database db, String date) => db.select(
    'SELECT app_name, duration_secs, is_idle, started_at, ended_at '
    'FROM usage_sessions WHERE date = ? ORDER BY started_at DESC',
    [date],
  );

  void _applyToday(ResultSet sessions) {
    var activeSeconds = 0;
    var idleSeconds = 0;
    var switches = 0;
    final apps = <String, int>{};
    String? foreground;
    String? lastActive;
    for (final row in sessions) {
      final seconds = (row['duration_secs'] as num?)?.toInt() ?? 0;
      final idle = (row['is_idle'] as num?)?.toInt() == 1;
      if (idle) {
        idleSeconds += seconds;
        continue;
      }
      final app = '${row['app_name'] ?? '-'}';
      if (isSelfApp(app)) continue;
      activeSeconds += seconds;
      switches++;
      apps[app] = (apps[app] ?? 0) + seconds;
      foreground ??= app;
      lastActive ??= '${row['ended_at'] ?? '进行中'}';
    }
    final sorted = apps.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    _foreground = foreground ?? '-';
    _topApp = sorted.isEmpty ? '-' : sorted.first.key;
    _activeMin = (activeSeconds / 60).round();
    _idleMin = (idleSeconds / 60).round();
    _switches = switches;
    _lastActive = lastActive ?? '-';
    _nowHour = DateTime.now().hour.toString();
  }

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  /// 历史日摘要（昨天/前天等），给 AI 作为语料。
  String historySummary() {
    if (_history.isEmpty) return '';
    final sb = StringBuffer();
    final recent = _history.reversed.take(3).toList().reversed;
    for (final d in recent) {
      // 语料只带近 3 天，控制 system prompt 体积（省 token）
      sb.writeln(
        '${d.readableDate}（${d.date}）：活跃 ${d.activeText}'
        '${d.idleMin > 0 ? '，空闲 ${d.idleMin} 分钟' : ''}'
        '；主要使用：${d.topAppsText}'
        '${d.diaryHas ? '；写了日记' : ''}',
      );
    }
    return sb.toString().trim();
  }

  double get lateNightRatio {
    if (_history.isEmpty) return 0;
    final recent = _history.reversed.take(7);
    var days = 0;
    var lateNights = 0;
    for (final day in recent) {
      days++;
      if (day.peakHours.any((item) => item.hour >= 23 || item.hour < 5)) {
        lateNights++;
      }
    }
    return days == 0 ? 0 : lateNights / days;
  }

  /// 生成给 AI 的聚合摘要（只含统计数据，不含任何路径/截图）。
  @override
  String summary() {
    final sb = StringBuffer();
    if (!hasData) {
      sb.writeln('（活动感知尚无数据，或当前已暂停）');
      return sb.toString();
    }
    sb
      ..writeln('当前时间：$nowHour 点')
      ..writeln('当前前台应用：$_foreground')
      ..writeln('今日活跃时长：$_activeMin 分钟，空闲 $_idleMin 分钟')
      ..writeln('窗口切换次数：$_switches 次')
      ..writeln('今日使用最多的应用：$_topApp')
      ..writeln('最后活跃：$_lastActive');
    final h = historySummary();
    if (h.isNotEmpty) sb.writeln(h);
    return sb.toString();
  }

  String get nowHour => _nowHour.isEmpty ? '?' : _nowHour;

  Future<Map<String, dynamic>?> _getJson(String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.getUrl(Uri.parse('$base$path'));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }
}
