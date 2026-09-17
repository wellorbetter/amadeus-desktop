import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:timepet/services/pet_db.dart';
import 'package:timepet/services/pet_memory.dart';

/// U7 自检：记忆来源链、墓碑、上下文版本与真实数据迁移。
///
/// 全部跑在真的 SQLite 文件上 —— 迁移是否真的只加列不动数据、删除后审核器
/// 会不会把内容写回来，这些只有在真库上才作数。
///
/// 对应 Spec §8（记忆权威与来源链）、INV-01（PetMemory 是唯一权威）、
/// INV-04（不谎称已记住）、INV-06（删除必须影响后续上下文与主动候选）、
/// INV-09（不破坏既有数据）。
void main() {
  String tempDbPath(String tag) {
    final dir = Directory.systemTemp.createTempSync('petdb_$tag');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    return '${dir.path}/mem.db';
  }

  /// 手写一个 v1 老库。
  ///
  /// 刻意**照抄** v1 的 DDL 而不是调用实现里的建表函数：借实现来造老库的话，
  /// 建表语句一改，"老库"就跟着变成新库，迁移测试自己就失效了。
  void createV1(
    String path, {
    int? userVersion,
    List<(String, String, int)> memories = const [],
    List<(String, String)> messages = const [],
  }) {
    final db = sqlite3.open(path);
    db.execute(
      'CREATE TABLE messages('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'role TEXT NOT NULL,'
      'content TEXT NOT NULL,'
      'ts TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE daily_facts('
      'date TEXT PRIMARY KEY,'
      'active_min INTEGER NOT NULL DEFAULT 0,'
      'idle_min INTEGER NOT NULL DEFAULT 0,'
      "top_apps TEXT NOT NULL DEFAULT '[]',"
      "peak_hours TEXT NOT NULL DEFAULT '[]',"
      'diary_has INTEGER NOT NULL DEFAULT 0)',
    );
    db.execute(
      'CREATE TABLE memories('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'content TEXT NOT NULL,'
      "category TEXT NOT NULL DEFAULT 'fact',"
      'importance INTEGER NOT NULL DEFAULT 1,'
      'ts TEXT NOT NULL,'
      "source TEXT NOT NULL DEFAULT 'auto',"
      'active INTEGER NOT NULL DEFAULT 1)',
    );
    db.execute('CREATE TABLE key_value(k TEXT PRIMARY KEY, v TEXT)');
    for (final (content, category, importance) in memories) {
      db.execute(
        'INSERT INTO memories(content, category, importance, ts, source) '
        'VALUES (?, ?, ?, ?, ?)',
        [content, category, importance, '2026-08-01T10:00:00.000', 'audit'],
      );
    }
    for (final (role, content) in messages) {
      db.execute('INSERT INTO messages(role, content, ts) VALUES (?, ?, ?)', [
        role,
        content,
        '2026-08-01T10:00:00.000',
      ]);
    }
    db.execute('INSERT INTO daily_facts(date, active_min) VALUES (?, ?)', [
      '2026-08-01',
      321,
    ]);
    // v1 从不写 user_version，默认就是 0。允许显式设成 1 来覆盖另一种老库。
    if (userVersion != null) db.execute('PRAGMA user_version = $userVersion');
    db.close();
  }

  int userVersionOf(String path) {
    final db = sqlite3.open(path);
    final v = db.select('PRAGMA user_version').first.values.first as int;
    db.close();
    return v;
  }

  setUp(() => PetDb.instance.dispose());
  tearDown(() => PetDb.instance.dispose());

  group('迁移：老库能升到当前版本，且一行都不动', () {
    test('全新库直接建到当前版本，上下文版本从 1 开始', () {
      final path = tempDbPath('fresh');

      expect(PetMemory.instance.load(at: path), isTrue);

      expect(userVersionOf(path), PetDb.schemaVersion);
      expect(PetMemory.instance.contextVersion, 1);
      expect(PetDb.instance.memoryCount(), 0);
    });

    test('v1 老库（没写过 user_version）升级后数据一字不改', () {
      final path = tempDbPath('v1implicit');
      createV1(
        path,
        memories: [
          ('用户不喝咖啡', 'preference', 4),
          ('用户在写毕业论文', 'goal', 5),
        ],
        messages: [('user', '在吗'), ('assistant', '在。')],
      );
      expect(userVersionOf(path), 0, reason: 'v1 老库本来就没有版本号');

      expect(PetMemory.instance.load(at: path), isTrue);

      expect(userVersionOf(path), PetDb.schemaVersion);
      final rows = PetDb.instance.db.select(
        'SELECT id, content, category, importance, ts, source, active '
        'FROM memories ORDER BY id',
      );
      expect(rows.length, 2);
      expect(rows[0]['content'], '用户不喝咖啡');
      expect(rows[0]['category'], 'preference');
      expect(rows[0]['importance'], 4);
      expect(rows[0]['ts'], '2026-08-01T10:00:00.000');
      expect(rows[0]['source'], 'audit', reason: '既有列的值不许被迁移改写');
      expect(rows[0]['active'], 1);
      expect(rows[1]['content'], '用户在写毕业论文');
      expect(PetDb.instance.messageCount(), 2);
      expect(
        PetDb.instance.dailyFactsRecent(5).single.activeMin,
        321,
        reason: '事实记忆同样不该在迁移里丢掉',
      );
    });

    test('老库里的记忆标为 legacy，不得当成用户确认过', () {
      final path = tempDbPath('legacy');
      createV1(path, memories: [('用户讨厌香菜', 'preference', 3)]);

      PetMemory.instance.load(at: path);

      final row = PetDb.instance.recentMemoryRows().single;
      expect(row['provenance'], MemoryProvenance.legacy.id);
      expect(
        row['provenance'],
        isNot(MemoryProvenance.userConfirmed.id),
        reason: '老库无从判断来源，不能因为"看着像用户说的"就升级成已确认',
      );
    });

    test('显式标了 v1 的老库同样能升级', () {
      final path = tempDbPath('v1explicit');
      createV1(path, userVersion: 1, memories: [('用户是左手党', 'fact', 2)]);

      expect(PetMemory.instance.load(at: path), isTrue);

      expect(userVersionOf(path), PetDb.schemaVersion);
      expect(PetDb.instance.recentMemoryRows().single['content'], '用户是左手党');
    });

    test('重复打开不重复迁移，也不重置上下文版本', () {
      final path = tempDbPath('reopen');
      PetMemory.instance.load(at: path);
      PetMemory.instance.storeConfirmed('用户养了只猫');
      final id = PetDb.instance.recentMemoryRows().single['id'] as int;
      PetMemory.instance.forget(id);
      final bumped = PetMemory.instance.contextVersion;
      expect(bumped, greaterThan(1));
      PetDb.instance.dispose();

      expect(PetMemory.instance.load(at: path), isTrue);

      expect(userVersionOf(path), PetDb.schemaVersion);
      expect(
        PetMemory.instance.contextVersion,
        bumped,
        reason: '重开一次就把版本清回去的话，重启后已删的记忆会重新生效',
      );
      expect(
        PetDb.instance.memoryTombstoned('用户养了只猫'),
        isTrue,
        reason: '墓碑必须跨进程存活',
      );
    });

    test('比程序更新的库不动它，也不降级', () {
      final path = tempDbPath('future');
      createV1(path, userVersion: 99, memories: [('未来版本写的', 'fact', 2)]);

      expect(PetMemory.instance.load(at: path), isTrue);

      expect(
        userVersionOf(path),
        99,
        reason: '降级要删列，那是真的丢数据 —— 宁可不动',
      );
      expect(PetDb.instance.db.select('SELECT * FROM memories').length, 1);
    });

    test('迁移失败时判定不可用，不留下半旧的 schema', () {
      final path = tempDbPath('badmigrate');
      // 造一个 `memories` 是视图的库：`_tableExists` 只认 table，于是迁移会
      // 走建表分支并撞上同名对象而失败。要的就是这条失败路径。
      final raw = sqlite3.open(path);
      raw.execute('CREATE TABLE real_mem(id INTEGER PRIMARY KEY, content TEXT)');
      raw.execute('CREATE VIEW memories AS SELECT * FROM real_mem');
      raw.close();

      expect(PetMemory.instance.load(at: path), isFalse);
      expect(PetDb.instance.initialized, isFalse);
      expect(PetDb.instance.initError, isNotEmpty);

      // 半开的句柄最难查：initialized 为真而表其实不在，写入要到运行时才零散
      // 地失败。这里必须是干净的"不可用"。
      final written = PetMemory.instance.storeConfirmed('不该写进去');
      expect(written.faulted, isTrue);
      expect(written.reason, 'db_uninitialized');
      expect(userVersionOf(path), 0, reason: '失败必须整体回滚，版本号不能先落地');
    });

    test('文件根本不是数据库时如实失败，且写入不抛异常', () {
      final path = tempDbPath('garbage');
      File(path).writeAsStringSync('这不是 SQLite，只是一坨字节');

      expect(PetMemory.instance.load(at: path), isFalse);
      expect(PetDb.instance.initError, isNotEmpty);

      final result = PetMemory.instance.storeAudited([
        {'content': '用户喜欢下雨天', 'category': 'preference', 'importance': 4},
      ]);
      expect(result.anyStored, isFalse);
      expect(result.healthy, isFalse, reason: '库打不开时不能对用户说"记住了"');
      expect(PetMemory.instance.record('user', '喂').faulted, isTrue);
      expect(PetMemory.instance.relevantMemories('下雨'), isEmpty);
    });
  });

  group('来源链与墓碑', () {
    setUp(() => PetMemory.instance.load(at: tempDbPath('prov')));

    test('模型审核写入标为 model_audited，不是用户确认', () {
      final result = PetMemory.instance.storeAudited([
        {'content': '用户在准备考研', 'category': 'goal', 'importance': 5},
      ]);

      expect(result.stored, 1);
      expect(result.healthy, isTrue);
      final row = PetDb.instance.recentMemoryRows().single;
      expect(row['provenance'], MemoryProvenance.modelAudited.id);
      expect(
        row['provenance'],
        isNot(MemoryProvenance.userConfirmed.id),
        reason: '审核的是模型自己，不是用户 —— 两者混同就没法让用户复核',
      );
    });

    test('重要性不足或超长的条目被跳过，但不算故障', () {
      final result = PetMemory.instance.storeAudited([
        {'content': '用户今天点了外卖', 'importance': 1},
        {'content': 'x' * 501, 'importance': 5},
        {'content': '', 'importance': 5},
        {'content': '用户对花生过敏', 'category': 'fact', 'importance': 5},
      ]);

      expect(result.stored, 1);
      expect(result.skipped, 3);
      expect(result.healthy, isTrue, reason: '跳过不是写坏了');
      expect(PetDb.instance.memoryCount(), 1);
    });

    test('同一条内容不重复写入', () {
      PetMemory.instance.storeAudited([
        {'content': '用户住在杭州', 'importance': 3},
      ]);
      final again = PetMemory.instance.storeAudited([
        {'content': '用户住在杭州', 'importance': 3},
      ]);

      expect(again.stored, 0);
      expect(again.skipped, 1);
      expect(PetDb.instance.memoryCount(), 1);
    });

    test('用户确认的写入标为 user_confirmed', () {
      final written = PetMemory.instance.storeConfirmed(
        '用户的生日是 3 月 14 号',
        category: 'fact',
        importance: 5,
      );

      expect(written.ok, isTrue);
      expect(
        PetDb.instance.recentMemoryRows().single['provenance'],
        MemoryProvenance.userConfirmed.id,
      );
    });

    test('删掉的记忆不出现在召回、最近列表和主动候选里', () {
      PetMemory.instance.storeConfirmed('用户在戒糖', importance: 5);
      final id = PetDb.instance.recentMemoryRows().single['id'] as int;

      expect(PetMemory.instance.forget(id).ok, isTrue);

      expect(PetMemory.instance.relevantMemories('戒糖'), isEmpty);
      expect(PetMemory.instance.recentMemoryRows(), isEmpty);
      expect(
        PetMemory.instance.topMemory(),
        isNull,
        reason: '主动触发的候选也必须跟着失效（INV-06）',
      );
      expect(PetMemory.instance.memoryCount(), 0);
    });

    test('审核器不得把用户删过的内容再写回来', () {
      PetMemory.instance.storeAudited([
        {'content': '用户和同事吵了一架', 'importance': 4},
      ]);
      final id = PetDb.instance.recentMemoryRows().single['id'] as int;
      PetMemory.instance.forget(id);

      // 同样的话再说一次，审核器又提取到同一条内容。
      final again = PetMemory.instance.storeAudited([
        {'content': '用户和同事吵了一架', 'importance': 4},
      ]);

      expect(again.stored, 0, reason: '删了又被自动写回来，等于删除无效');
      expect(again.healthy, isTrue, reason: '这是有意拒绝，不是写入故障');
      expect(PetMemory.instance.memoryCount(), 0);
      expect(PetMemory.instance.relevantMemories('同事'), isEmpty);
    });

    test('用户自己可以把删过的内容再确认回来', () {
      PetMemory.instance.storeConfirmed('用户想去北海道');
      final id = PetDb.instance.recentMemoryRows().single['id'] as int;
      PetMemory.instance.forget(id);

      final back = PetMemory.instance.storeConfirmed('用户想去北海道');

      expect(back.ok, isTrue, reason: '用户改主意时不该被自己的墓碑挡住');
      expect(PetMemory.instance.memoryCount(), 1);
      expect(
        PetDb.instance.recentMemoryRows().single['provenance'],
        MemoryProvenance.userConfirmed.id,
      );
    });

    test('纠正后旧的立墓碑，新的挂上纠正链', () {
      PetMemory.instance.storeAudited([
        {'content': '用户是猫派', 'category': 'preference', 'importance': 4},
      ]);
      final oldId = PetDb.instance.recentMemoryRows().single['id'] as int;

      expect(PetMemory.instance.correct(oldId, '用户其实是狗派').ok, isTrue);

      final rows = PetDb.instance.recentMemoryRows();
      expect(rows.length, 1, reason: '纠正不是新增一条并列的事实');
      expect(rows.single['content'], '用户其实是狗派');
      expect(rows.single['provenance'], MemoryProvenance.userConfirmed.id);
      expect(
        rows.single['category'],
        'preference',
        reason: '纠正只改内容，分类与重要性沿用旧的',
      );
      final chain = PetDb.instance.db.select(
        'SELECT corrected_from FROM memories WHERE active = 1',
      );
      expect(chain.single['corrected_from'], oldId);
      expect(PetDb.instance.memoryTombstoned('用户是猫派'), isTrue);
      // 召回本身不会空 —— 子串匹配不足时会按重要性补足，补进来的是纠正后的
      // 那条。要断言的是被纠正掉的旧说法不再出现。
      expect(PetMemory.instance.relevantMemories('猫派'), isNot(contains('用户是猫派')));
    });

    test('写不进去时不报告已记住（INV-04）', () {
      // query_only 让 SQLite 真的拒绝写入 —— 比断言"假设磁盘满了"实在。
      PetDb.instance.db.execute('PRAGMA query_only = ON');

      final audited = PetMemory.instance.storeAudited([
        {'content': '用户明天要面试', 'importance': 5},
      ]);
      expect(audited.anyStored, isFalse);
      expect(audited.faulted, 1);
      expect(audited.healthy, isFalse);

      final confirmed = PetMemory.instance.storeConfirmed('用户明天要面试');
      expect(confirmed.ok, isFalse);
      expect(confirmed.faulted, isTrue, reason: '磁盘写不动是故障，不是"内容不该写"');

      PetDb.instance.db.execute('PRAGMA query_only = OFF');
    });

    test('删不存在的记忆如实报 not_found，不静默成功', () {
      final r = PetMemory.instance.forget(4242);

      expect(r.ok, isFalse);
      expect(r.reason, 'not_found');
      expect(r.faulted, isFalse, reason: '记录本来就不在，不是数据库坏了');
    });
  });

  group('上下文版本：删除必须让已生成的上下文过期', () {
    setUp(() => PetMemory.instance.load(at: tempDbPath('ctx')));

    test('删除记忆让此前召回的上下文过期', () {
      PetMemory.instance.storeConfirmed('用户在减肥', importance: 5);
      final recalled = PetMemory.instance.recall('减肥');
      expect(recalled.text, contains('用户在减肥'));
      expect(recalled.stale, isFalse);

      final id = PetDb.instance.recentMemoryRows().single['id'] as int;
      PetMemory.instance.forget(id);

      expect(
        recalled.stale,
        isTrue,
        reason: '不失效的话，已拼进 prompt 的这条记忆下一句照样出现',
      );
    });

    test('纠正记忆同样让上下文过期', () {
      PetMemory.instance.storeConfirmed('用户在上海工作');
      final recalled = PetMemory.instance.recall('工作');
      final id = PetDb.instance.recentMemoryRows().single['id'] as int;

      PetMemory.instance.correct(id, '用户在深圳工作');

      expect(recalled.stale, isTrue);
    });

    test('清空记忆让上下文过期（但清空不留墓碑）', () {
      PetMemory.instance.storeAudited([
        {'content': '用户喜欢爵士乐', 'importance': 3},
      ]);
      final recalled = PetMemory.instance.recall('爵士');
      expect(recalled.text, isNotEmpty);

      expect(PetDb.instance.clearMemories().ok, isTrue);

      expect(recalled.stale, isTrue);
      expect(
        PetDb.instance.memoryTombstoned('用户喜欢爵士乐'),
        isFalse,
        reason: '清空是真删除，留不下墓碑 —— 这与逐条删除的语义不同',
      );
      final again = PetMemory.instance.storeAudited([
        {'content': '用户喜欢爵士乐', 'importance': 3},
      ]);
      expect(again.stored, 1, reason: '清空之后审核器可以重新写入同样的内容');
    });

    test('新增记忆不让已有上下文过期', () {
      final recalled = PetMemory.instance.recall('随便什么');

      PetMemory.instance.storeConfirmed('用户新养了只乌龟');

      expect(
        recalled.stale,
        isFalse,
        reason: '多记一条不影响已生成的上下文，没必要逼上层重建',
      );
    });
  });

  group('留存口径：60 条且 30 天', () {
    setUp(() {
      PetMemory.instance.load(at: tempDbPath('trim'));
      // 老 mem.json 若存在会被导入，先清干净再算条数。
      PetDb.instance.db.execute('DELETE FROM messages');
    });

    test('超过 60 条时只留最近 60 条', () {
      for (var i = 0; i < 70; i++) {
        PetMemory.instance.record('user', '第 $i 句');
      }

      expect(PetDb.instance.messageCount(), PetDb.messageCap);
      final kept = PetDb.instance.recentMessages(100);
      expect(kept.first['content'], '第 10 句');
      expect(kept.last['content'], '第 69 句');
    });

    test('超过 30 天的消息即使不足 60 条也要清掉', () {
      final old = DateTime.now().subtract(const Duration(days: 31));
      PetDb.instance.addMessage('user', '一个月前说的', ts: old.toIso8601String());
      PetDb.instance.addMessage('user', '今天说的');
      expect(PetDb.instance.messageCount(), 2);

      expect(PetDb.instance.trimMessages(PetDb.messageCap).ok, isTrue);

      expect(
        PetDb.instance.messageCount(),
        1,
        reason: '只按条数裁的话，聊得少的用户库里会一直留着半年前的对话',
      );
      expect(PetDb.instance.recentMessages(10).single['content'], '今天说的');
    });

    test('刚好 30 天内的消息不被裁掉', () {
      final recent = DateTime.now().subtract(const Duration(days: 29));
      PetDb.instance.addMessage('user', '上个月末说的', ts: recent.toIso8601String());

      PetDb.instance.trimMessages(PetDb.messageCap);

      expect(PetDb.instance.messageCount(), 1);
    });
  });
}
