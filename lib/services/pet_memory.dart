import 'agent_context.dart';
import 'pet_config.dart';
import 'pet_db.dart';
import 'pet_logger.dart';

/// 记忆层（本地 SQLite 分层记忆）：
/// - 工作记忆：最近对话（messages 表）
/// - 语义记忆：经审核的长期记忆（memories 表，偏好/习惯/目标/事件）
/// 记忆审核：用户消息含稳定信息信号时，由 LLM 提取并写入语义记忆。
/// Computer History 属于短期观察层，不通过本类持久化。
class PetMemory implements AgentMemorySource {
  PetMemory({PetDb? database, PetConfig? config})
    : _database = database ?? PetDb.instance,
      _config = config ?? PetConfig.instance;

  static final PetMemory instance = PetMemory();

  final PetDb _database;
  final PetConfig _config;

  static const int _msgCap = 60;
  static const int _summaryLen = 6;

  /// 记忆提取信号：命中才触发 LLM 审核（省成本）。
  static final RegExp _signal = RegExp(
    r'我(?:喜欢|讨厌|爱|想|希望|打算|计划|习惯|记得|忘|是|在|有|要|会|最近|每天|经常|偶尔|从来)'
    r'|我的|我对象|我朋友|我家人|别忘|记住|以后|目标|想买|想去|想学|在学',
  );

  void load() => _database.init();

  // ---- 工作记忆 ----

  void record(String role, String content) {
    if (content.isEmpty) return;
    _database.addMessage(role, content);
    _database.trimMessages(_msgCap);
  }

  String summary() {
    final rows = _database.recentMessages(_summaryLen);
    if (rows.isEmpty) return '（暂无历史对话）';
    final sb = StringBuffer();
    for (final r in rows) {
      final who = r['role'] == 'user' ? '用户' : 'Amadeus';
      var text = (r['content'] as String? ?? '').replaceAll('\n', ' ');
      if (text.length > 120) {
        text = '${text.substring(0, 120)}…'; // 单条消息截断，控制 token
      }
      sb.writeln('$who：$text');
    }
    return sb.toString();
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
      if (_config.memoryDisabledCategories.contains(cat)) continue;
      if (_database.memoryExists(content)) continue;
      _database.addMemory(
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
    final rows = _database.searchMemories(query, limit: limit);
    if (rows.isEmpty) return '';
    final sb = StringBuffer('长期记忆（可能相关，自然融入，不要直白引用）：\n');
    for (final r in rows) {
      sb.writeln('- ${r['content']}');
    }
    return sb.toString().trim();
  }

  @override
  String workingSummary() => summary();

  @override
  String relevantSummary(String query) => relevantMemories(query);

  /// 重要性最高的记忆（主动触发用）。
  Map<String, Object?>? topMemory({int excludeId = -1}) =>
      _database.topMemory(excludeId: excludeId);

  int memoryCount() => _database.memoryCount();

  List<Map<String, Object?>> recentMemoryRows({int limit = 8}) =>
      _database.recentMemoryRows(limit: limit);
}
