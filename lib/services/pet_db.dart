import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'pet_logger.dart';
import 'tt_api.dart';

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

/// 一条记忆的来源。
///
/// 这决定该记忆能不能被当作「用户确认过的事实」使用，因此必须与内容一起存，
/// 不能靠猜。旧库里的记忆一律是 [legacy]：它们写入时没有留下来源，
/// 事后无法区分是模型提取的还是用户说过的。
enum MemoryProvenance {
  /// v1 旧库里已存在的记忆。**不得**当作用户确认过的事实。
  legacy('legacy'),

  /// LLM 从对话里提取并「审核」过。
  ///
  /// 审核的是模型自己，不是用户 —— 这只是一次自动判断，与用户确认不同级。
  modelAudited('model_audited'),

  /// 用户明确确认或亲手写下的。
  userConfirmed('user_confirmed');

  const MemoryProvenance(this.id);

  /// 落库用的稳定字符串。不用 enum 的下标，否则加一个枚举值就会改写旧数据的含义。
  final String id;

  static MemoryProvenance parse(String? value) => values.firstWhere(
    (p) => p.id == value,
    orElse: () => MemoryProvenance.legacy,
  );
}

/// 一次写入的结果。
///
/// 存在的理由只有一个：让调用方能区分「写进去了」和「没写进去」。
/// 原先所有写方法都是吞掉异常后静默返回 void，未初始化时更是直接空操作，
/// 于是 UI 只能假定成功 —— 那正是 INV-04 禁止的虚假「已记住」。
class WriteOutcome {
  const WriteOutcome._(this.ok, this.reason, this.rowId);

  factory WriteOutcome.done({int? rowId}) => WriteOutcome._(true, '', rowId);

  /// [reason] 是稳定的机器可读原因，不是给用户看的文案。
  factory WriteOutcome.failed(String reason) =>
      WriteOutcome._(false, reason, null);

  final bool ok;
  final String reason;
  final int? rowId;

  bool get failed => !ok;

  /// 内容本就不该写入（重复、被删过、空串），不是故障。
  bool get rejected => failed && !_faults.contains(reason);

  static const Set<String> _faults = {
    'db_uninitialized',
    'db_write_error',
  };

  /// 真的出了故障：磁盘写不进去或库没打开。这种情况绝不能对用户说「已记住」。
  bool get faulted => failed && _faults.contains(reason);

  @override
  String toString() => ok ? 'WriteOutcome.ok' : 'WriteOutcome($reason)';
}

/// 本地 SQLite 记忆库（%APPDATA%/timepet/mem.db）。
/// 分层记忆：
/// - messages    工作记忆：最近对话（替换旧 mem.json entries）
/// - daily_facts 事实记忆：TimeTrace 每日聚合（结构化，供画像/召回）
/// - memories    语义记忆：经审核的长期记忆（偏好/习惯/目标/事件）
/// - key_value   元信息（迁移标记、上下文版本）
class PetDb {
  PetDb._();

  static final PetDb instance = PetDb._();

  /// 当前 schema 版本。落在 `PRAGMA user_version` 上。
  ///
  /// 刻意不另建 `schema_version` 表：版本必须能在读任何业务表之前拿到，
  /// 而且不能出现「表里写了 v2、pragma 还是 v1」这种两个版本源互相矛盾的状态。
  static const int schemaVersion = 2;

  static const String _kContextVersion = 'context_version';

  /// 工作记忆留存：最多 60 条，且不超过 30 天。
  static const int messageCap = 60;
  static const Duration messageMaxAge = Duration(days: 30);

  Database? _db;
  String? _openedPath;
  String _initError = '';

  bool get initialized => _db != null;

  /// 上一次 [init] 的失败原因。空串表示没有失败。
  String get initError => _initError;

  Database get db {
    final d = _db;
    if (d == null) throw StateError('PetDb not initialized');
    return d;
  }

  String get defaultPath {
    final appData =
        Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    return '$appData/timepet/mem.db';
  }

  String get path => _openedPath ?? defaultPath;

  /// 打开并迁移数据库。返回是否可用。
  ///
  /// [at] 只给测试与迁移演练用；正常运行走 [defaultPath]。
  bool init({String? at}) {
    if (_db != null) return true;
    final target = at ?? defaultPath;
    try {
      File(target).parent.createSync(recursive: true);
      _db = sqlite3.open(target);
      _openedPath = target;
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('PRAGMA synchronous=NORMAL');
      db.execute('PRAGMA foreign_keys=ON');
      _migrateSchema();
      _migrateFromMemJson();
      _initError = '';
      PetLog.i('db: init ok path=$target schema=${_userVersion()}');
      return true;
    } catch (e) {
      // 打开失败时不留半开的句柄：否则 initialized 为 true 而表可能不存在，
      // 后面每次写入都抛异常，比直接判定不可用更难查。
      try {
        _db?.close();
      } catch (_) {}
      _db = null;
      _openedPath = null;
      _initError = '$e';
      PetLog.e('db: init error: $e');
      return false;
    }
  }

  int _userVersion() {
    final rows = db.select('PRAGMA user_version');
    return rows.first.values.first as int? ?? 0;
  }

  // ---- schema 迁移 ----

  /// 按版本逐级迁移。全程在一个事务里，中途失败就整体回滚，
  /// 不会留下「加了一半列」的库。
  void _migrateSchema() {
    final from = _userVersion();
    if (from == schemaVersion) return;
    if (from > schemaVersion) {
      // 用旧版本程序打开新库。这里不动它 —— 降级删列会真的丢数据。
      PetLog.w('db: schema v$from newer than supported v$schemaVersion');
      return;
    }

    db.execute('BEGIN');
    try {
      if (from == 0) {
        // 0 有两种含义：全新库，或 v1 老库（那时还没写过 user_version）。
        // 用业务表是否存在来区分，别的判断都不可靠。
        final legacy = _tableExists('memories');
        _createSchemaV1();
        _upgradeV1ToV2();
        db.execute('PRAGMA user_version = $schemaVersion');
        PetLog.i('db: schema ${legacy ? 'migrated v1(implicit)' : 'created'} '
            '-> v$schemaVersion');
      } else if (from == 1) {
        _upgradeV1ToV2();
        db.execute('PRAGMA user_version = $schemaVersion');
        PetLog.i('db: schema migrated v1 -> v$schemaVersion');
      }
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      // 迁移失败必须往外抛：让 init() 判定数据库不可用，而不是带着半旧
      // 的 schema 继续跑 —— 那会让写入在运行时才零散地失败。
      throw StateError('schema migration from v$from failed: $e');
    }
  }

  bool _tableExists(String name) => db
      .select("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [
        name,
      ])
      .isNotEmpty;

  bool _columnExists(String table, String column) => db
      .select('PRAGMA table_info($table)')
      .any((row) => row['name'] == column);

  void _createSchemaV1() {
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

  /// v1 -> v2：补来源链与墓碑。
  ///
  /// 只加列、不改任何既有列的值（INV-09）。旧记忆靠 DEFAULT 落到 `legacy`，
  /// 因为它们确实无从判断来源 —— 不能因为「看起来像用户说的」就升级成已确认。
  void _upgradeV1ToV2() {
    if (!_columnExists('memories', 'provenance')) {
      db.execute(
        'ALTER TABLE memories ADD COLUMN provenance TEXT NOT NULL '
        "DEFAULT '${MemoryProvenance.legacy.id}'",
      );
    }
    // 墓碑：记下删除时间。`active = 0` 只够过滤，不足以防复活 ——
    // 审核器按同样的内容再写一次就「复活」了，而用户明确删过。
    if (!_columnExists('memories', 'deleted_at')) {
      db.execute('ALTER TABLE memories ADD COLUMN deleted_at TEXT');
    }
    // 纠正链：新记忆指向被它取代的那条，便于审计「这条是怎么变成现在这样的」。
    if (!_columnExists('memories', 'corrected_from')) {
      db.execute('ALTER TABLE memories ADD COLUMN corrected_from INTEGER');
    }
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_memories_content ON memories(content)',
    );
    db.execute(
      'INSERT OR IGNORE INTO key_value(k, v) VALUES (?, ?)',
      [_kContextVersion, '1'],
    );
  }

  // ---- 迁移：旧 mem.json -> SQLite ----

  void _migrateFromMemJson() {
    try {
      if (getKv('memjson_migrated') == '1') return;
      final appData =
          Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
      final f = File('$appData/timepet/mem.json');
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

  // ---- 上下文版本 ----

  /// 上下文版本。删除或纠正记忆时递增。
  ///
  /// 已经拼进 system prompt 的记忆、以及排队待发的主动候选，都必须在版本变化后
  /// 重建 —— 否则用户删掉一条记忆，下一句话里它照样出现（INV-06）。
  int get contextVersion =>
      int.tryParse(getKv(_kContextVersion) ?? '') ?? (initialized ? 1 : 0);

  /// 拿着 [seen] 版本的上下文是否已经过期。
  bool contextStale(int seen) => seen != contextVersion;

  WriteOutcome _bumpContextVersion() {
    final next = contextVersion + 1;
    return setKv(_kContextVersion, '$next');
  }

  // ---- 工作记忆：messages ----

  WriteOutcome addMessage(String role, String content, {String? ts}) {
    if (_db == null) return WriteOutcome.failed('db_uninitialized');
    if (content.isEmpty) return WriteOutcome.failed('empty_content');
    try {
      db.execute('INSERT INTO messages(role, content, ts) VALUES (?, ?, ?)', [
        role,
        content,
        ts ?? DateTime.now().toIso8601String(),
      ]);
      return WriteOutcome.done(rowId: db.lastInsertRowId);
    } catch (e) {
      PetLog.e('db: addMessage error: $e');
      return WriteOutcome.failed('db_write_error');
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

  /// 按条数与年龄两条口径裁剪工作记忆。
  ///
  /// 只按条数裁不够：聊得少的用户会让半年前的对话一直留在库里，
  /// 而留存口径写的是 60 条 **且** 30 天。
  WriteOutcome trimMessages(int keep, {Duration maxAge = messageMaxAge}) {
    if (_db == null) return WriteOutcome.failed('db_uninitialized');
    try {
      db.execute(
        'DELETE FROM messages WHERE id NOT IN '
        '(SELECT id FROM messages ORDER BY id DESC LIMIT ?)',
        [keep],
      );
      final cutoff = DateTime.now().subtract(maxAge).toIso8601String();
      // ts 是 ISO8601，字典序与时间序一致，可以直接比。
      db.execute('DELETE FROM messages WHERE ts < ?', [cutoff]);
      return WriteOutcome.done();
    } catch (e) {
      PetLog.e('db: trimMessages error: $e');
      return WriteOutcome.failed('db_write_error');
    }
  }

  // ---- 事实记忆：daily_facts ----

  WriteOutcome upsertDailyFact(DayInfo d) {
    if (_db == null) return WriteOutcome.failed('db_uninitialized');
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
      return WriteOutcome.done();
    } catch (e) {
      PetLog.e('db: upsertDailyFact error: $e');
      return WriteOutcome.failed('db_write_error');
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

  /// 写入一条语义记忆。
  ///
  /// [provenance] 必须如实填写，尤其是「模型审核过」不等于「用户确认过」。
  /// 用户删过的内容默认拒绝写回（墓碑），只有用户自己确认时才允许
  /// （[overrideTombstone]）—— 让审核器绕过这一条就等于删除无效。
  WriteOutcome addMemory(
    String content, {
    String category = 'fact',
    int importance = 1,
    required MemoryProvenance provenance,
    bool overrideTombstone = false,
    int? correctedFrom,
  }) {
    if (_db == null) return WriteOutcome.failed('db_uninitialized');
    final text = content.trim();
    if (text.isEmpty) return WriteOutcome.failed('empty_content');
    try {
      final existing = db.select(
        'SELECT id, active FROM memories WHERE content = ? '
        'ORDER BY id DESC LIMIT 1',
        [text],
      );
      if (existing.isNotEmpty) {
        final active = (existing.first['active'] as int? ?? 1) == 1;
        if (active) return WriteOutcome.failed('duplicate');
        if (!overrideTombstone) return WriteOutcome.failed('tombstoned');
      }
      db.execute(
        'INSERT INTO memories'
        '(content, category, importance, ts, source, active, provenance, corrected_from) '
        'VALUES (?, ?, ?, ?, ?, 1, ?, ?)',
        [
          text,
          category,
          importance,
          DateTime.now().toIso8601String(),
          // source 只为设置面板的既有显示保留，判断一律看 provenance，
          // 不让同一件事有两个说法。
          provenance.id,
          provenance.id,
          correctedFrom,
        ],
      );
      return WriteOutcome.done(rowId: db.lastInsertRowId);
    } catch (e) {
      PetLog.e('db: addMemory error: $e');
      return WriteOutcome.failed('db_write_error');
    }
  }

  /// 是否存在同内容的**活跃**记忆。
  bool memoryExists(String content) {
    if (_db == null) return false;
    final rows = db.select(
      'SELECT 1 FROM memories WHERE active = 1 AND content = ? LIMIT 1',
      [content.trim()],
    );
    return rows.isNotEmpty;
  }

  /// 该内容是否被用户删过。删过就不该由自动审核再写回来。
  bool memoryTombstoned(String content) {
    if (_db == null) return false;
    final rows = db.select(
      'SELECT 1 FROM memories WHERE active = 0 AND content = ? LIMIT 1',
      [content.trim()],
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
      return db.select(
        'SELECT id, content, category, importance, ts, source, provenance '
        'FROM memories WHERE active = 1 ORDER BY id DESC LIMIT ?',
        [limit],
      ).map((row) => Map<String, Object?>.from(row)).toList();
    } catch (e) {
      PetLog.e('db: recent memories error: $e');
      return const [];
    }
  }

  /// 删除一条记忆：立墓碑并递增上下文版本。
  ///
  /// 递增版本是删除生效的一半 —— 不递增的话，已经拼进 prompt 的旧上下文与
  /// 已排队的主动候选仍然带着这条内容（INV-06）。
  WriteOutcome deleteMemory(int id) {
    if (_db == null) return WriteOutcome.failed('db_uninitialized');
    try {
      db.execute(
        'UPDATE memories SET active = 0, deleted_at = ? WHERE id = ?',
        [DateTime.now().toIso8601String(), id],
      );
      if (db.updatedRows == 0) return WriteOutcome.failed('not_found');
      final bumped = _bumpContextVersion();
      if (bumped.failed) return bumped;
      return WriteOutcome.done(rowId: id);
    } catch (e) {
      PetLog.e('db: deleteMemory error: $e');
      return WriteOutcome.failed('db_write_error');
    }
  }

  /// 纠正一条记忆：旧的立墓碑，新的作为用户确认写入，并递增上下文版本。
  WriteOutcome correctMemory(int id, String content) {
    if (_db == null) return WriteOutcome.failed('db_uninitialized');
    final text = content.trim();
    if (text.isEmpty) return WriteOutcome.failed('empty_content');
    final old = db.select(
      'SELECT category, importance FROM memories WHERE id = ?',
      [id],
    );
    if (old.isEmpty) return WriteOutcome.failed('not_found');
    final removed = deleteMemory(id);
    if (removed.failed) return removed;
    return addMemory(
      text,
      category: old.first['category'] as String? ?? 'fact',
      importance: old.first['importance'] as int? ?? 1,
      provenance: MemoryProvenance.userConfirmed,
      // 纠正是用户亲自动手，允许写回他自己删过的内容。
      overrideTombstone: true,
      correctedFrom: id,
    );
  }

  /// 召回：先按子串匹配，不足再按重要性补足（本地小规模用 LIKE 足够）。
  List<Map<String, Object?>> searchMemories(String query, {int limit = 3}) {
    final q = query.trim();
    if (_db == null || q.isEmpty) return const [];
    try {
      final rows = db.select(
        'SELECT id, content, category, importance, ts, provenance FROM memories '
        'WHERE active = 1 AND content LIKE \'%\' || ? || \'%\' '
        'ORDER BY importance DESC, id DESC LIMIT ?',
        [q, limit],
      ).toList();
      if (rows.length < limit) {
        final matched = rows.map((r) => r['id'] as int).toList();
        final args = <Object?>[...matched, limit - rows.length];
        final extra = db
            .select(
              'SELECT id, content, category, importance, ts, provenance FROM memories '
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
        'SELECT id, content, category, importance, ts, provenance FROM memories '
        'WHERE active = 1 AND id != ? ORDER BY importance DESC, id DESC LIMIT 1',
        [excludeId],
      );
      return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
    } catch (e) {
      PetLog.e('db: topMemory error: $e');
      return null;
    }
  }

  /// 清空语义记忆。
  ///
  /// 这里是真删除，因此**留不下墓碑** —— 用户清空后，审核器可以再次写入同样的
  /// 内容。这与单条删除的语义不同，调用方须让用户知道这是「清空」而非「逐条删」。
  WriteOutcome clearMemories() {
    if (_db == null) return WriteOutcome.failed('db_uninitialized');
    try {
      db.execute('DELETE FROM memories');
      final bumped = _bumpContextVersion();
      PetLog.i('db: memories cleared');
      return bumped;
    } catch (e) {
      PetLog.e('db: clearMemories error: $e');
      return WriteOutcome.failed('db_write_error');
    }
  }

  // ---- 元信息 ----

  String? getKv(String k) {
    if (_db == null) return null;
    try {
      final rows = db.select('SELECT v FROM key_value WHERE k = ?', [k]);
      return rows.isEmpty ? null : rows.first['v'] as String?;
    } catch (e) {
      PetLog.e('db: getKv error: $e');
      return null;
    }
  }

  WriteOutcome setKv(String k, String v) {
    if (_db == null) return WriteOutcome.failed('db_uninitialized');
    try {
      db.execute('INSERT OR REPLACE INTO key_value(k, v) VALUES (?, ?)', [
        k,
        v,
      ]);
      return WriteOutcome.done();
    } catch (e) {
      PetLog.e('db: setKv error: $e');
      return WriteOutcome.failed('db_write_error');
    }
  }

  void dispose() {
    _db?.close();
    _db = null;
    _openedPath = null;
  }
}
