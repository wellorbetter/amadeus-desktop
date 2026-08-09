import 'pet_db.dart';
import 'pet_logger.dart';
import 'tt_api.dart';

/// 记忆层（本地 SQLite 分层记忆）：
/// - 工作记忆：最近对话（messages 表）
/// - 事实记忆：TimeTrace 每日聚合（daily_facts 表）
/// - 语义记忆：经审核的长期记忆（memories 表，偏好/习惯/目标/事件）
/// - 用户画像：由 daily_facts 计算的规律摘要
/// 记忆审核：用户消息含稳定信息信号时，由 LLM 提取并写入语义记忆。
class PetMemory {
  PetMemory._();

  static final PetMemory instance = PetMemory._();

  static const int _msgCap = 60;
  static const int _summaryLen = 6;
  static const int _factsDays = 3; // 事实记忆只带近 3 天，控制 system prompt 体积（省 token）

  /// 记忆提取信号：命中才触发 LLM 审核（省成本）。
  static final RegExp _signal = RegExp(
    r'我(?:喜欢|讨厌|爱|想|希望|打算|计划|习惯|记得|忘|是|在|有|要|会|最近|每天|经常|偶尔|从来)'
    r'|我的|我对象|我朋友|我家人|别忘|记住|以后|目标|想买|想去|想学|在学',
  );

  void load() => PetDb.instance.init();

  // ---- 工作记忆 ----

  void record(String role, String content) {
    if (content.isEmpty) return;
    PetDb.instance.addMessage(role, content);
    PetDb.instance.trimMessages(_msgCap);
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

  /// 把 LLM 审核结果写入长期记忆（去重 + 重要性过滤）。
  void storeAudited(List<Map<String, dynamic>> items) {
    var stored = 0;
    for (final it in items) {
      final content = it['content']?.toString().trim() ?? '';
      if (content.isEmpty || content.length > 500) continue;
      final rawImportance = it['importance'];
      final importance = rawImportance is num
          ? rawImportance.toInt().clamp(1, 5).toInt()
          : 1;
      if (importance < 2) continue;
      const categories = {
        'preference',
        'habit',
        'goal',
        'fact',
        'event',
        'relationship',
      };
      final candidate = it['category']?.toString();
      final cat = categories.contains(candidate) ? candidate! : 'fact';
      if (PetDb.instance.memoryExists(content)) continue;
      PetDb.instance.addMemory(
        content,
        category: cat,
        importance: importance,
        source: 'audit',
      );
      stored++;
    }
    if (stored > 0) {
      PetLog.i('mem: audited stored=$stored total=${memoryCount()}');
    }
  }

  /// 按当前话题召回相关长期记忆（用于 system prompt）。
  String relevantMemories(String query, {int limit = 3}) {
    if (query.isEmpty) return '';
    final rows = PetDb.instance.searchMemories(query, limit: limit);
    if (rows.isEmpty) return '';
    final sb = StringBuffer('长期记忆（可能相关，自然融入，不要直白引用）：\n');
    for (final r in rows) {
      sb.writeln('- ${r['content']}');
    }
    return sb.toString().trim();
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
