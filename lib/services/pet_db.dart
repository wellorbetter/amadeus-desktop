import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'pet_logger.dart';
import 'tt_api.dart';
import 'app_paths.dart';

/// 单日事实（结构化，供画像/召回使用）。
class DailyFact {
  DailyFact({
    required this.date,
    required this.activeMin,
    required this.idleMin,
    required this.topApps,
    required this.peakHours,
    required this.diaryHas,
  });

  final String date;
  final int activeMin;
  final int idleMin;
  final List<AppUsage> topApps;
  final List<int> peakHours;
  final bool diaryHas;

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
}

/// 本地 SQLite 记忆库（%APPDATA%/timepet/mem.db）。
/// 分层记忆：
/// - messages    工作记忆：最近对话（替换旧 mem.json entries）
/// - daily_facts 事实记忆：TimeTrace 每日聚合（结构化，供画像/召回）
/// - memories    语义记忆：经审核的长期记忆（偏好/习惯/目标/事件）
/// - key_value   元信息（迁移标记等）
class PetDb {
  PetDb._();

  static final PetDb instance = PetDb._();

  Database? _db;

  bool get initialized => _db != null;

  Database get db {
    final d = _db;
    if (d == null) throw StateError('PetDb not initialized');
    return d;
  }

  String get path {
    return AppPaths.memoryFile.path;
  }

  void init() {
    if (_db != null) return;
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      _db = sqlite3.open(path);
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('PRAGMA synchronous=NORMAL');
      db.execute('PRAGMA foreign_keys=ON');
      _createSchema();
      _migrateFromMemJson();
      PetLog.i('db: init ok path=$path');
    } catch (e) {
      PetLog.e('db: init error: $e');
    }
  }

  void _createSchema() {
    db.execute(
      'CREATE TABLE IF NOT EXISTS messages('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'role TEXT NOT NULL,'
      'content TEXT NOT NULL,'
      'ts TEXT NOT NULL)',
    );
    db.execute('CREATE INDEX IF NOT EXISTS idx_messages_id ON messages(id)');
    db.execute(
      'CREATE TABLE IF NOT EXISTS daily_facts('
      'date TEXT PRIMARY KEY,'
      'active_min INTEGER NOT NULL DEFAULT 0,'
      'idle_min INTEGER NOT NULL DEFAULT 0,'
      "top_apps TEXT NOT NULL DEFAULT '[]',"
      "peak_hours TEXT NOT NULL DEFAULT '[]',"
      'diary_has INTEGER NOT NULL DEFAULT 0)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS memories('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'content TEXT NOT NULL,'
      "category TEXT NOT NULL DEFAULT 'fact',"
      'importance INTEGER NOT NULL DEFAULT 1,'
      'ts TEXT NOT NULL,'
      "source TEXT NOT NULL DEFAULT 'auto',"
      'active INTEGER NOT NULL DEFAULT 1)',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_memories_active '
      'ON memories(active, importance)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS key_value('
      'k TEXT PRIMARY KEY,'
      'v TEXT)',
    );
  }

  // ---- 迁移：旧 mem.json -> SQLite ----

  void _migrateFromMemJson() {
    try {
      if (getKv('memjson_migrated') == '1') return;
      final f = File(
        '${AppPaths.userDataDirectory.path}${Platform.pathSeparator}mem.json',
      );
      if (f.existsSync()) {
        final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final entries = json['entries'] as List? ?? const [];
        for (final e in entries) {
          if (e is! Map<String, dynamic>) continue;
          final role = e['role']?.toString() ?? 'user';
          final content = e['content']?.toString() ?? '';
          if (content.isEmpty) continue;
          addMessage(role, content, ts: e['ts']?.toString());
        }
        // 旧 facts 文本会在启动时由 TtApi 重新结构化吸收
        try {
          f.renameSync('${f.path}.bak');
        } catch (_) {}
        PetLog.i('db: mem.json imported ${entries.length} entries');
      }
      setKv('memjson_migrated', '1');
    } catch (e) {
      PetLog.e('db: migrate mem.json error: $e');
    }
  }

  // ---- 工作记忆：messages ----

  void addMessage(String role, String content, {String? ts}) {
    try {
      db.execute('INSERT INTO messages(role, content, ts) VALUES (?, ?, ?)', [
        role,
        content,
        ts ?? DateTime.now().toIso8601String(),
      ]);
    } catch (e) {
      PetLog.e('db: addMessage error: $e');
    }
  }

  List<Map<String, Object?>> recentMessages(int limit) {
    if (_db == null) return const [];
    return db
        .select(
          'SELECT role, content, ts FROM messages ORDER BY id DESC LIMIT ?',
          [limit],
        )
        .toList()
        .reversed
        .toList();
  }

  int messageCount() {
    if (_db == null) return 0;
    final rows = db.select('SELECT COUNT(*) AS c FROM messages');
    return rows.first['c'] as int? ?? 0;
  }

  void trimMessages(int keep) {
    if (_db == null) return;
    db.execute(
      'DELETE FROM messages WHERE id NOT IN '
      '(SELECT id FROM messages ORDER BY id DESC LIMIT ?)',
      [keep],
    );
  }

  // ---- 事实记忆：daily_facts ----

  void upsertDailyFact(DayInfo d) {
    if (_db == null) return;
    try {
      db.execute(
        'INSERT INTO daily_facts(date, active_min, idle_min, top_apps, peak_hours, diary_has) '
        'VALUES (?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(date) DO UPDATE SET '
        'active_min=excluded.active_min, idle_min=excluded.idle_min, '
        'top_apps=excluded.top_apps, peak_hours=excluded.peak_hours, '
        'diary_has=excluded.diary_has',
        [
          d.date,
          d.activeMin,
          d.idleMin,
          jsonEncode(
            d.topApps
                .map((a) => {'name': a.name, 'minutes': a.minutes})
                .toList(),
          ),
          jsonEncode(d.peakHours.map((h) => h.hour).toList()),
          d.diaryHas ? 1 : 0,
        ],
      );
    } catch (e) {
      PetLog.e('db: upsertDailyFact error: $e');
    }
  }

  List<DailyFact> dailyFactsRecent(int limit) {
    if (_db == null) return const [];
    try {
      final rows = db.select(
        'SELECT * FROM daily_facts ORDER BY date DESC LIMIT ?',
        [limit],
      );
      return rows.map(_dailyFactFromRow).toList().reversed.toList();
    } catch (e) {
      PetLog.e('db: dailyFactsRecent error: $e');
      return const [];
    }
  }

  DailyFact _dailyFactFromRow(Row row) {
    List<AppUsage> apps = const [];
    List<int> peak = const [];
    try {
      apps = (jsonDecode(row['top_apps'] as String? ?? '[]') as List)
          .whereType<Map<String, dynamic>>()
          .map(
            (e) => AppUsage(
              name: e['name']?.toString() ?? '?',
              minutes: (e['minutes'] as num?)?.toInt() ?? 0,
            ),
          )
          .toList();
    } catch (_) {}
    try {
      peak = (jsonDecode(row['peak_hours'] as String? ?? '[]') as List)
          .whereType<num>()
          .map((h) => h.toInt())
          .toList();
    } catch (_) {}
    return DailyFact(
      date: row['date'] as String? ?? '',
      activeMin: row['active_min'] as int? ?? 0,
      idleMin: row['idle_min'] as int? ?? 0,
      topApps: apps,
      peakHours: peak,
      diaryHas: (row['diary_has'] as int? ?? 0) == 1,
    );
  }

  // ---- 语义记忆：memories ----

  void addMemory(
    String content, {
    String category = 'fact',
    int importance = 1,
    String source = 'auto',
  }) {
    if (_db == null || content.isEmpty) return;
    try {
      db.execute(
        'INSERT INTO memories(content, category, importance, ts, source, active) '
        'VALUES (?, ?, ?, ?, ?, 1)',
        [
          content,
          category,
          importance,
          DateTime.now().toIso8601String(),
          source,
        ],
      );
    } catch (e) {
      PetLog.e('db: addMemory error: $e');
    }
  }

  bool memoryExists(String content) {
    if (_db == null) return false;
    final rows = db.select(
      'SELECT 1 FROM memories WHERE active = 1 AND content = ? LIMIT 1',
      [content],
    );
    return rows.isNotEmpty;
  }

  int memoryCount() {
    if (_db == null) return 0;
    final rows = db.select(
      'SELECT COUNT(*) AS c FROM memories WHERE active = 1',
    );
    return rows.first['c'] as int? ?? 0;
  }

  List<Map<String, Object?>> recentMemoryRows({int limit = 8}) {
    if (_db == null) return const [];
    try {
      return db
          .select(
            'SELECT id, content, category, importance, ts, source FROM memories '
            'WHERE active = 1 ORDER BY id DESC LIMIT ?',
            [limit],
          )
          .map((row) => Map<String, Object?>.from(row))
          .toList();
    } catch (e) {
      PetLog.e('db: recent memories error: $e');
      return const [];
    }
  }

  void deleteMemory(int id) {
    if (_db == null) return;
    db.execute('UPDATE memories SET active = 0 WHERE id = ?', [id]);
  }

  /// 召回：先按子串匹配，不足再按重要性补足（本地小规模用 LIKE 足够）。
  List<Map<String, Object?>> searchMemories(String query, {int limit = 3}) {
    final q = query.trim();
    if (_db == null || q.isEmpty) return const [];
    try {
      final rows = db.select(
        'SELECT id, content, category, importance, ts FROM memories '
        'WHERE active = 1 AND content LIKE \'%\' || ? || \'%\' '
        'ORDER BY importance DESC, id DESC LIMIT ?',
        [q, limit],
      ).toList();
      if (rows.length < limit) {
        final matched = rows.map((r) => r['id'] as int).toList();
        final args = <Object?>[...matched, limit - rows.length];
        final extra = db
            .select(
              'SELECT id, content, category, importance, ts FROM memories '
              'WHERE active = 1 '
              '${matched.isEmpty ? '' : 'AND id NOT IN (${List.filled(matched.length, '?').join(',')})'} '
              'ORDER BY importance DESC, id DESC LIMIT ?',
              args,
            )
            .toList();
        rows.addAll(extra);
      }
      return rows.map((r) => Map<String, Object?>.from(r)).toList();
    } catch (e) {
      PetLog.e('db: searchMemories error: $e');
      return const [];
    }
  }

  Map<String, Object?>? topMemory({int excludeId = -1}) {
    if (_db == null) return null;
    try {
      final rows = db.select(
        'SELECT id, content, category, importance, ts FROM memories '
        'WHERE active = 1 AND id != ? ORDER BY importance DESC, id DESC LIMIT 1',
        [excludeId],
      );
      return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
    } catch (e) {
      PetLog.e('db: topMemory error: $e');
      return null;
    }
  }

  void clearMemories() {
    if (_db == null) return;
    try {
      db.execute('DELETE FROM memories');
      PetLog.i('db: memories cleared');
    } catch (e) {
      PetLog.e('db: clearMemories error: $e');
    }
  }

  // ---- 元信息 ----

  String? getKv(String k) {
    if (_db == null) return null;
    final rows = db.select('SELECT v FROM key_value WHERE k = ?', [k]);
    return rows.isEmpty ? null : rows.first['v'] as String?;
  }

  void setKv(String k, String v) {
    if (_db == null) return;
    db.execute('INSERT OR REPLACE INTO key_value(k, v) VALUES (?, ?)', [k, v]);
  }

  void dispose() {
    _db?.close();
    _db = null;
  }
}
