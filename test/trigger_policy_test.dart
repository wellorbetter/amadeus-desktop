import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/trigger_engine.dart';

TriggerDecision _candidate({
  required String id,
  required int score,
  required TriggerLane lane,
  Duration cooldown = const Duration(hours: 1),
}) => TriggerDecision(
  id: id,
  label: id,
  prompt: 'prompt-$id',
  reason: 'reason-$id',
  score: score,
  cooldown: cooldown,
  lane: lane,
);

void main() {
  const policy = TriggerPolicy();
  final now = DateTime.utc(2026, 8, 27, 12);

  test('highest score wins regardless of candidate order', () {
    final selected = policy.select(
      candidates: [
        _candidate(id: 'hourly', score: 40, lane: TriggerLane.ambient),
        _candidate(id: 'focus', score: 84, lane: TriggerLane.wellbeing),
        _candidate(id: 'return', score: 92, lane: TriggerLane.transition),
      ],
      now: now,
      lastTriggeredAt: (_) => null,
    );

    expect(selected?.id, 'return');
    expect(selected?.reason, contains('同时检测到'));
    expect(selected?.reason, contains('focus'));
  });

  test('busy mode keeps wellbeing and transition lanes only', () {
    final selected = policy.select(
      candidates: [
        _candidate(id: 'memory', score: 100, lane: TriggerLane.relationship),
        _candidate(id: 'return', score: 70, lane: TriggerLane.transition),
        _candidate(id: 'random', score: 120, lane: TriggerLane.ambient),
      ],
      now: now,
      lastTriggeredAt: (_) => null,
      busy: true,
    );

    expect(selected?.id, 'return');
  });

  test('quiet hours and startup grace only allow wellbeing', () {
    final candidates = [
      _candidate(id: 'late', score: 80, lane: TriggerLane.wellbeing),
      _candidate(id: 'return', score: 99, lane: TriggerLane.transition),
    ];

    expect(
      policy
          .select(
            candidates: candidates,
            now: now,
            lastTriggeredAt: (_) => null,
            quietHours: true,
          )
          ?.id,
      'late',
    );
    expect(
      policy
          .select(
            candidates: candidates,
            now: now,
            lastTriggeredAt: (_) => null,
            startupGrace: true,
          )
          ?.id,
      'late',
    );
  });

  test('per-trigger cooldown falls back to the next candidate', () {
    final selected = policy.select(
      candidates: [
        _candidate(id: 'late', score: 90, lane: TriggerLane.wellbeing),
        _candidate(id: 'focus', score: 80, lane: TriggerLane.wellbeing),
      ],
      now: now,
      lastTriggeredAt: (id) =>
          id == 'late' ? now.subtract(const Duration(minutes: 20)) : null,
    );

    expect(selected?.id, 'focus');
  });
}
