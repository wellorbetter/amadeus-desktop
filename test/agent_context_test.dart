import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/agent_context.dart';
import 'package:timepet/services/observation_source.dart';

class _Memory implements AgentMemorySource {
  @override
  String relevantSummary(String query) =>
      query.contains('项目') ? '用户目标：完成项目' : '';

  @override
  String workingSummary() => '用户：继续优化';
}

class _Observation implements ObservationSource {
  _Observation({this.available = true});

  final bool available;

  @override
  String get displayName => 'Computer History';

  @override
  bool get hasData => available;

  @override
  String get id => 'computer_history';

  @override
  Future<bool> refresh() async => available;

  @override
  String summary() => available ? '当前前台应用：Editor' : '';
}

void main() {
  test('agent context keeps identity, memory and lived context separated', () {
    final composer = AgentContextComposer(
      memory: _Memory(),
      observation: _Observation(),
    );

    final prompt = composer.compose(
      persona: '表达克制、自然。',
      query: '继续这个项目',
      customPersona: true,
    );

    expect(prompt, contains('[Agent Identity]'));
    expect(prompt, contains('[Working Memory · user controlled]'));
    expect(prompt, contains('[Semantic Memory · user controlled]'));
    expect(prompt, contains('[Lived Context · ephemeral observation]'));
    expect(prompt, contains('不代表长期记忆'));
    expect(prompt, contains('尚未安装的 Skill、MCP 或 Evolve'));
  });

  test('observation corpus is omitted when the capability has no data', () {
    final composer = AgentContextComposer(
      memory: _Memory(),
      observation: _Observation(available: false),
    );

    expect(composer.observationCorpus(), isEmpty);
  });
}
