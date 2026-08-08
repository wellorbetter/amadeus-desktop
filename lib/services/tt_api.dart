import 'dart:convert';
import 'dart:io';

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
        .map((e) => AppUsage(
              name: e['app']?.toString() ?? '?',
              minutes: (e['minutes'] as num?)?.toInt() ?? 0,
            ))
        .where((a) => a.minutes > 0)
        .toList();
    final peak = (json['peak_hours'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((e) => HourUsage(
              hour: (e['hour'] as num?)?.toInt() ?? 0,
              minutes: (e['minutes'] as num?)?.toInt() ?? 0,
            ))
        .toList();
    final diary = json['diary'];
    return DayInfo(
      date: json['date']?.toString() ?? '',
      activeMin: (json['active_min'] as num?)?.toInt() ?? 0,
      idleMin: (json['idle_min'] as num?)?.toInt() ?? 0,
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
    return '${int.parse(parts[1])}月${int.parse(parts[2])}日';
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

/// TimeTrace 聚合数据（本地 8788 API：今日 context + 历史日聚合）。
class TtApi {
  TtApi({String? base})
      : base = base ??
            (Platform.environment['TIMEPET_TT_API'] ?? 'http://127.0.0.1:8788');

  final String base;
  String _foreground = '-';
  int _activeMin = 0;
  int _switches = 0;
  int _idleMin = 0;
  String _topApp = '-';
  String _lastActive = '-';
  String _nowHour = '';
  DateTime? _lastSync;
  DateTime? _lastHistoryAt; // 历史日聚合缓存时间（5 分钟刷一次）
  final List<DayInfo> _history = [];

  /// 历史数据缓存间隔：每 60 秒 tick 只拉实时 context，历史 7 天聚合 5 分钟刷一次。
  static const Duration _historyCache = Duration(minutes: 5);

  bool get hasData => _lastSync != null;
  bool get hasHistory => _history.isNotEmpty;
  List<DayInfo> get history => List.unmodifiable(_history);

  int get activeMinutes => _activeMin;
  int get idleMinutes => _idleMin;
  int get switches => _switches;
  String get foregroundApp => _foreground;

  Future<bool> refresh() async {
    var ok = false;
    try {
      final ctx = await _getJson('/api/context');
      if (ctx != null) {
        _foreground = (ctx['foreground_app'] as String?) ?? '-';
        _activeMin = (ctx['today']?['active_min'] as num?)?.toInt() ?? 0;
        _idleMin = (ctx['today']?['idle_min'] as num?)?.toInt() ?? 0;
        _switches = (ctx['today']?['switches'] as num?)?.toInt() ?? 0;
        _topApp = (ctx['today']?['top_app'] as String?) ?? '-';
        _lastActive = (ctx['last_active_at'] as String?) ?? '-';
        _nowHour = (ctx['now_hour'] as num?)?.toString() ?? '';
        ok = true;
      }
    } catch (e) {
      stderr.writeln('TtApi context failed: $e');
    }

    // 历史日聚合（昨天、前天等）：5 分钟缓存，避免每 60 秒拉一次 7 天数据
    final historyDue = _lastHistoryAt == null ||
        DateTime.now().difference(_lastHistoryAt!) >= _historyCache;
    if (historyDue) {
      try {
        final hist = await _getJson('/api/history?days=7');
        if (hist != null && hist['days'] is List) {
          _history
            ..clear()
            ..addAll((hist['days'] as List)
                .whereType<Map<String, dynamic>>()
                .map(DayInfo.fromJson)
                .where((d) => d.date.isNotEmpty));
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

    if (ok) _lastSync = DateTime.now();
    return ok;
  }

  /// 历史日摘要（昨天/前天等），给 AI 作为语料。
  String historySummary() {
    if (_history.isEmpty) return '';
    final sb = StringBuffer();
    for (final d in _history.take(3)) { // 语料只带近 3 天，控制 system prompt 体积（省 token）
      sb.writeln('${d.readableDate}（${d.date}）：活跃 ${d.activeText}'
          '${d.idleMin > 0 ? '，空闲 ${d.idleMin} 分钟' : ''}'
          '；主要使用：${d.topAppsText}'
          '${d.diaryHas ? '；写了日记' : ''}');
    }
    return sb.toString().trim();
  }

  /// 生成给 AI 的聚合摘要（只含统计数据，不含任何路径/截图）。
  String summary() {
    final sb = StringBuffer();
    if (!hasData) {
      sb.writeln('（暂无 TimeTrace 数据，请确认主程序在运行）');
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
