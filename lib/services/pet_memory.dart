import 'pet_db.dart';
import 'pet_logger.dart';
import 'tt_api.dart';

/// 一次记忆审核写入的结果。
///
/// 分成三类而不是一个数字：`stored` 是真写进去了，`skipped` 是内容本就不该写
/// （重复、用户删过），`faulted` 是磁盘或数据库出了问题。只有 `faulted == 0`
/// 时才可以对用户说「记住了」（INV-04）。
class AuditStoreResult {
  const AuditStoreResult({
    required this.stored,
    required this.skipped,
    required this.faulted,
  });

  final int stored;
  final int skipped;
  final int faulted;

  bool get anyStored => stored > 0;
  bool get healthy => faulted == 0;

  @override
  String toString() =>
      'AuditStoreResult(stored=$stored skipped=$skipped faulted=$faulted)';
}

/// 一份带版本的召回结果。
///
/// 版本必须跟着文本一起交出去：调用方拼进 system prompt 之后，用户可能删掉其中
/// 一条记忆，此时这份上下文就过期了，必须重建而不是继续用（INV-06）。
class RecalledContext {
  const RecalledContext(this.text, this.contextVersion);

  final String text;
  final int contextVersion;

  bool get isEmpty => text.isEmpty;

  /// 生成这份上下文之后，记忆有没有被删除或纠正过。
  bool get stale => PetDb.instance.contextStale(contextVersion);
}

/// 记忆层（本地 SQLite 分层记忆）：
/// - 工作记忆：最近对话（messages 表）
/// - 事实记忆：TimeTrace 每日聚合（daily_facts 表）
/// - 语义记忆：经审核的长期记忆（memories 表，偏好/习惯/目标/事件）
/// - 用户画像：由 daily_facts 计算的规律摘要
/// 记忆审核：用户消息含稳定信息信号时，由 LLM 提取并写入语义记忆。
class PetMemory {
  PetMemory._();

  static final PetMemory instance = PetMemory._();

  static const int _msgCap = PetDb.messageCap;
  static const int _summaryLen = 6;
  static const int _factsDays = 3; // 事实记忆只带近 3 天，控制 system prompt 体积（省 token）

  /// 记忆提取信号：命中才触发 LLM 审核（省成本）。
  static final RegExp _signal = RegExp(
    r'我(?:喜欢|讨厌|爱|想|希望|打算|计划|习惯|记得|忘|是|在|有|要|会|最近|每天|经常|偶尔|从来)'
    r'|我的|我对象|我朋友|我家人|别忘|记住|以后|目标|想买|想去|想学|在学',
  );

  /// 打开记忆库。返回是否可用 —— 不可用时上层不能假装记忆功能正常。
  bool load({String? at}) => PetDb.instance.init(at: at);

  /// 当前上下文版本。删除或纠正记忆后会变。
  int get contextVersion => PetDb.instance.contextVersion;

  // ---- 工作记忆 ----

  WriteOutcome record(String role, String content) {
    if (content.isEmpty) return WriteOutcome.failed('empty_content');
    final written = PetDb.instance.addMessage(role, content);
    if (written.failed) {
      PetLog.w('mem: record failed reason=${written.reason}');
      return written;
    }
    PetDb.instance.trimMessages(_msgCap);
    return written;
  }

  String summary() {
    final rows = PetDb.instance.recentMessages(_summaryLen);
    if (rows.isEmpty) return '（暂无历史对话）';
    final sb = StringBuffer();
    for (final r in rows) {
      final who = r['role'] == 'user' ? '用户' : '红莉栖';
      var text = (r['content'] as String? ?? '').replaceAll('\n', ' ');
      if (text.length > 120) {
        text = '${text.substring(0, 120)}…'; // 单条消息截断，控制 token
      }
      sb.writeln('$who：$text');
    }
    return sb.toString();
  }

  // ---- 事实记忆 ----

  void absorbFactsFrom(TtApi tt) {
    if (!tt.hasHistory) return;
    for (final d in tt.history) {
      PetDb.instance.upsertDailyFact(d);
    }
  }

  String factsSummary() {
    final days = PetDb.instance.dailyFactsRecent(_factsDays);
    if (days.isEmpty) return '';
    final sb = StringBuffer('近期状态：\n');
    for (final d in days) {
      final apps = d.topApps
          .take(4)
          .map((a) => '${a.name} ${a.minutes} 分钟')
          .join('、');
      sb.writeln(
        '- ${d.readableDate}：活跃 ${d.activeText}'
        '${d.idleMin > 0 ? '，空闲 ${d.idleMin} 分钟' : ''}'
        '，主要使用 ${apps.isEmpty ? '无' : apps}'
        '${d.diaryHas ? '，写了日记' : ''}',
      );
    }
    return sb.toString().trim();
  }

  // ---- 语义记忆（审核写入 + 召回）----

  /// 用户消息是否包含值得审核的信号。
  bool hasMemorySignal(String text) => _signal.hasMatch(text);

  static const Set<String> _categories = {
    'preference',
    'habit',
    'goal',
    'fact',
    'event',
    'relationship',
  };

  /// 把 LLM 审核结果写入长期记忆（去重 + 重要性过滤）。
  ///
  /// 这里的来源是 [MemoryProvenance.modelAudited] —— **模型审核不是用户确认**。
  /// 两者在库里必须分得开：用户确认过的内容可以直接当事实用，模型自己提取的
  /// 只能当推测，日后要让用户复核也才有依据。
  AuditStoreResult storeAudited(List<Map<String, dynamic>> items) {
    var stored = 0;
    var skipped = 0;
    var faulted = 0;
    for (final it in items) {
      final content = it['content']?.toString().trim() ?? '';
      if (content.isEmpty || content.length > 500) {
        skipped++;
        continue;
      }
      final rawImportance = it['importance'];
      final importance = rawImportance is num
          ? rawImportance.toInt().clamp(1, 5).toInt()
          : 1;
      if (importance < 2) {
        skipped++;
        continue;
      }
      final candidate = it['category']?.toString();
      final cat = _categories.contains(candidate) ? candidate! : 'fact';
      final written = PetDb.instance.addMemory(
        content,
        category: cat,
        importance: importance,
        provenance: MemoryProvenance.modelAudited,
        // 审核器**不得**越过墓碑：用户删过的东西再被自动写回来，
        // 删除就等于没删（INV-06）。
      );
      if (written.ok) {
        stored++;
      } else if (written.faulted) {
        faulted++;
        PetLog.w('mem: audit write faulted reason=${written.reason}');
      } else {
        skipped++;
        if (written.reason == 'tombstoned') {
          PetLog.i('mem: audit skipped tombstoned content');
        }
      }
    }
    if (stored > 0 || faulted > 0) {
      PetLog.i(
        'mem: audited stored=$stored skipped=$skipped '
        'faulted=$faulted total=${memoryCount()}',
      );
    }
    return AuditStoreResult(
      stored: stored,
      skipped: skipped,
      faulted: faulted,
    );
  }

  /// 用户亲口确认的一条记忆。
  ///
  /// 与 [storeAudited] 的区别不只是标签：用户确认可以覆盖他自己以前删掉的
  /// 内容（改主意了），自动审核不行。
  WriteOutcome storeConfirmed(
    String content, {
    String category = 'fact',
    int importance = 3,
  }) {
    final cat = _categories.contains(category) ? category : 'fact';
    final written = PetDb.instance.addMemory(
      content,
      category: cat,
      importance: importance.clamp(1, 5),
      provenance: MemoryProvenance.userConfirmed,
      overrideTombstone: true,
    );
    if (written.faulted) {
      PetLog.w('mem: confirmed write faulted reason=${written.reason}');
    }
    return written;
  }

  /// 删除一条记忆。会让已生成的上下文过期（INV-06）。
  WriteOutcome forget(int id) => PetDb.instance.deleteMemory(id);

  /// 纠正一条记忆：旧的立墓碑，新的按用户确认写入。
  WriteOutcome correct(int id, String content) =>
      PetDb.instance.correctMemory(id, content);

  /// 按当前话题召回相关长期记忆（用于 system prompt）。
  String relevantMemories(String query, {int limit = 3}) =>
      recall(query, limit: limit).text;

  /// 同 [relevantMemories]，但带上生成时的上下文版本。
  ///
  /// 拿了文本还要拿版本，是因为这段文本会被缓存进 prompt 或主动候选里；
  /// 期间用户删掉其中一条，缓存就必须作废（INV-06）。
  RecalledContext recall(String query, {int limit = 3}) {
    final version = PetDb.instance.contextVersion;
    if (query.isEmpty) return RecalledContext('', version);
    final rows = PetDb.instance.searchMemories(query, limit: limit);
    if (rows.isEmpty) return RecalledContext('', version);
    final sb = StringBuffer('长期记忆（可能相关，自然融入，不要直白引用）：\n');
    for (final r in rows) {
      sb.writeln('- ${r['content']}');
    }
    return RecalledContext(sb.toString().trim(), version);
  }

  /// 重要性最高的记忆（主动触发用）。
  Map<String, Object?>? topMemory({int excludeId = -1}) =>
      PetDb.instance.topMemory(excludeId: excludeId);

  int memoryCount() => PetDb.instance.memoryCount();

  List<Map<String, Object?>> recentMemoryRows({int limit = 8}) =>
      PetDb.instance.recentMemoryRows(limit: limit);

  // ---- 用户画像 ----

  Map<String, dynamic> profile() {
    final days = PetDb.instance.dailyFactsRecent(7);
    if (days.isEmpty) return {'has': false};
    var totalActive = 0;
    var lateNights = 0;
    final appMin = <String, int>{};
    for (final d in days) {
      totalActive += d.activeMin;
      if (d.peakHours.any((h) => h >= 23 || h < 5)) lateNights++;
      for (final a in d.topApps) {
        appMin[a.name] = (appMin[a.name] ?? 0) + a.minutes;
      }
    }
    final topApps = appMin.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {
      'has': true,
      'days': days.length,
      'avgActiveMin': (totalActive / days.length).round(),
      'lateNightRatio': lateNights / days.length,
      'topApp': topApps.isNotEmpty ? topApps.first.key : '',
      'topAppMin': topApps.isNotEmpty ? topApps.first.value : 0,
    };
  }

  String profileText() {
    final p = profile();
    if (p['has'] != true) return '';
    final sb = StringBuffer('用户画像（规律参考，自然融入，不要直白念出）：\n');
    sb.writeln(
      '- 近 ${p['days']} 天日均活跃约 ${((p['avgActiveMin'] as int) / 60).toStringAsFixed(1)} 小时',
    );
    if ((p['lateNightRatio'] as double) > 0.3) {
      sb.writeln('- 深夜活跃天数偏多');
    }
    if ((p['topApp'] as String).isNotEmpty) {
      sb.writeln('- 常用应用：${p['topApp']}（近 7 天 ${p['topAppMin']} 分钟）');
    }
    return sb.toString().trim();
  }
}
