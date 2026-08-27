import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'app_paths.dart';
import 'pet_logger.dart';

class _NewerDatabaseSchema implements Exception {
  const _NewerDatabaseSchema(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 本地 SQLite 记忆库（%APPDATA%/timepet/mem.db）。
/// 分层记忆：
/// - messages    工作记忆：最近对话（替换旧 mem.json entries）
/// - memories    语义记忆：经审核的长期记忆（偏好/习惯/目标/事件）
/// - key_value   元信息（迁移标记等）
///
/// Computer History 始终留在短期 activity.db，不复制到长期记忆库。
class PetDb {
  PetDb({String? pathOverride, bool migrateLegacy = true})
    : _pathOverride = pathOverride,
      _migrateLegacy = migrateLegacy;

  static final PetDb instance = PetDb();

  static const schemaVersion = 3;

  final String? _pathOverride;
  final bool _migrateLegacy;

  Database? _db;

  bool get initialized => _db != null;

  Database get db {
    final d = _db;
    if (d == null) throw StateError('PetDb not initialized');
    return d;
  }

  String get path {
    return _pathOverride ?? AppPaths.memoryFile.path;
  }

  void init() {
    if (_db != null) return;
    try {
      _openAndMigrate();
      PetLog.i('db: init ok path=$path');
    } catch (e) {
      PetLog.e('db: init error: $e');
      _db?.close();
      _db = null;
      if (e is _NewerDatabaseSchema) return;
      final backup = _backupBrokenDatabase();
      try {
        _openAndMigrate();
        PetLog.i('db: recovered with a fresh database backup=$backup');
      } catch (recoveryError) {
        PetLog.e('db: recovery error: $recoveryError');
        _db?.close();
        _db = null;
      }
    }
  }

  void _openAndMigrate() {
    final f = File(path);
    f.parent.createSync(recursive: true);
    _db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA synchronous=NORMAL');
    db.execute('PRAGMA busy_timeout=5000');
    db.execute('PRAGMA foreign_keys=ON');
    final integrity = db.select('PRAGMA quick_check').first.values.first;
    if (integrity != 'ok') throw StateError('SQLite quick_check: $integrity');
    _migrateSchema();
    if (_migrateLegacy) _migrateFromMemJson();
  }

  void _migrateSchema() {
    final current = db.userVersion;
    if (current > schemaVersion) {
      throw _NewerDatabaseSchema(
        'Database schema $current is newer than supported $schemaVersion',
      );
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      _createSchema();
      // v1/v2 copied activity-derived daily facts into the long-lived memory
      // database. Remove that projection on upgrade so observation retention
      // and the user's clear controls remain truthful.
      if (current < 3) db.execute('DROP TABLE IF EXISTS daily_facts');
      db.userVersion = schemaVersion;
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  String? _backupBrokenDatabase() {
    final source = File(path);
    if (!source.existsSync()) return null;
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final backupPath = '$path.corrupt-$stamp';
    try {
      source.renameSync(backupPath);
      for (final suffix in const ['-wal', '-shm']) {
        final sidecar = File('$path$suffix');
        if (sidecar.existsSync()) {
          sidecar.renameSync('$backupPath$suffix');
        }
      }
      return backupPath;
    } catch (error) {
      PetLog.e('db: failed to preserve corrupt database: $error');
      return null;
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
    db.execute(
      'CREATE TABLE IF NOT EXISTS proactive_events('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'trigger_id TEXT NOT NULL,'
      'label TEXT NOT NULL,'
      'reason TEXT NOT NULL,'
      'state TEXT NOT NULL,'
      'ts TEXT NOT NULL)',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_proactive_events_id '
      'ON proactive_events(id)',
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
        // Legacy free-form facts are intentionally not imported. Computer
        // History is rebuilt from its short-lived observation store instead.
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

  void updateMemory(
    int id, {
    required String content,
    required String category,
    required int importance,
  }) {
    if (_db == null || content.trim().isEmpty) return;
    db.execute(
      'UPDATE memories SET content = ?, category = ?, importance = ? '
      'WHERE id = ? AND active = 1',
      [content.trim(), category, importance.clamp(1, 5), id],
    );
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

  // ---- 主动交互审计与 Agent 状态 ----

  void recordProactiveEvent({
    required String triggerId,
    required String label,
    required String reason,
    String state = 'fired',
    DateTime? at,
  }) {
    if (_db == null) return;
    db.execute(
      'INSERT INTO proactive_events(trigger_id, label, reason, state, ts) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        triggerId,
        label,
        reason,
        state,
        (at ?? DateTime.now()).toIso8601String(),
      ],
    );
  }

  List<Map<String, Object?>> recentProactiveEvents({int limit = 8}) {
    if (_db == null) return const [];
    return db
        .select(
          'SELECT id, trigger_id, label, reason, state, ts '
          'FROM proactive_events ORDER BY id DESC LIMIT ?',
          [limit],
        )
        .map((row) => Map<String, Object?>.from(row))
        .toList();
  }

  DateTime? latestProactiveAt({String? triggerId}) {
    if (_db == null) return null;
    final rows = triggerId == null
        ? db.select(
            "SELECT ts FROM proactive_events WHERE state = 'fired' "
            'ORDER BY id DESC LIMIT 1',
          )
        : db.select(
            "SELECT ts FROM proactive_events WHERE state = 'fired' "
            'AND trigger_id = ? ORDER BY id DESC LIMIT 1',
            [triggerId],
          );
    if (rows.isEmpty) return null;
    return DateTime.tryParse('${rows.first['ts']}');
  }

  int proactiveCountSince(DateTime since) {
    if (_db == null) return 0;
    final rows = db.select(
      "SELECT COUNT(*) AS c FROM proactive_events WHERE state = 'fired' "
      'AND ts >= ?',
      [since.toIso8601String()],
    );
    return rows.first['c'] as int? ?? 0;
  }

  void trimProactiveEvents({int keep = 300}) {
    if (_db == null) return;
    db.execute(
      'DELETE FROM proactive_events WHERE id NOT IN '
      '(SELECT id FROM proactive_events ORDER BY id DESC LIMIT ?)',
      [keep],
    );
  }

  void setAgentState(String state, String detail, {DateTime? at}) {
    setKv(
      'agent_runtime',
      jsonEncode({
        'state': state,
        'detail': detail,
        'updatedAt': (at ?? DateTime.now()).toIso8601String(),
      }),
    );
  }

  Map<String, dynamic>? agentState() {
    final raw = getKv('agent_runtime');
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
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
