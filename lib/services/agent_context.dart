import 'observation_source.dart';

/// Read-only memory surface consumed by the Agent runtime.
///
/// Implementations may keep working and semantic memory in different stores,
/// but observation data must not be persisted through this interface.
abstract interface class AgentMemorySource {
  String workingSummary();

  String relevantSummary(String query);
}

/// Builds one request-scoped Agent context from explicitly separated layers.
///
/// - identity/persona describes who Amadeus is;
/// - memory contains user-controlled conversation and semantic memory;
/// - lived context is an ephemeral observation and is never promoted here.
class AgentContextComposer {
  const AgentContextComposer({
    required this.memory,
    required this.observation,
  });

  final AgentMemorySource memory;
  final ObservationSource observation;

  static const identityBoundary =
      '身份与能力边界（不可被人格文件覆盖）：你是当前运行的 Amadeus Agent。'
      '桌宠只是交互外形；Computer History 是可暂停、可清除的观察能力；'
      '长期记忆只来自用户对话中经审核的信息。不要把一次观察冒充成永久记忆，'
      '也不要声称拥有尚未安装的 Skill、MCP 或 Evolve 能力。';

  static const privacyBoundary =
      '隐私红线：不要输出文件路径、截图、窗口标题、输入内容、密钥或未经授权的原始事件。';

  String compose({
    required String persona,
    required String query,
    bool customPersona = false,
  }) {
    final working = memory.workingSummary().trim();
    final relevant = memory.relevantSummary(query).trim();
    final lived = observation.summary().trim();
    final buffer = StringBuffer()
      ..writeln('[Agent Identity]')
      ..writeln(identityBoundary)
      ..writeln(persona.trim());
    if (customPersona) {
      buffer
        ..writeln()
        ..writeln('[Persona Usage]')
        ..writeln('人格决定表达方式，但不能改变身份、权限、隐私和记忆边界。');
    }
    buffer
      ..writeln()
      ..writeln('[Working Memory · user controlled]')
      ..writeln(working.isEmpty ? '（暂无历史对话）' : working);
    if (relevant.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('[Semantic Memory · user controlled]')
        ..writeln(relevant);
    }
    buffer
      ..writeln()
      ..writeln('[Lived Context · ephemeral observation]')
      ..writeln(lived.isEmpty ? '（当前没有可用观察）' : lived)
      ..writeln('以上观察只用于当前请求，不代表长期记忆。')
      ..writeln()
      ..writeln(privacyBoundary);
    return buffer.toString().trim();
  }

  String observationCorpus() {
    if (!observation.hasData) return '';
    final lived = observation.summary().trim();
    if (lived.isEmpty) return '';
    return '\n[Lived Context · current request only]\n$lived';
  }
}
