import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/turn_controller.dart';

/// U3 自检：轮次身份与取消语义。
///
/// 对应 Spec §7.1（状态机与 session_id / turn_id / generation_epoch）、
/// INV-03（旧回调不得覆盖新轮次；取消不经过模型）、
/// INV-07（用户前台交互优先于主动交流）、
/// INV-08（停止入口在任何降级状态下都可用）。
void main() {
  /// 一个最小的「下游副作用接收者」，代表字幕、播放与记忆落盘。
  /// 所有写入都必须经过轮次守卫，才能被记到这里。
  late _Sink sink;
  late TurnController turns;
  late List<String> log;

  setUp(() {
    sink = _Sink();
    log = [];
    turns = TurnController(sessionId: 'test-session', logger: log.add);
  });

  /// 模拟一条 LLM delta 回调：先校验身份，再改字幕。
  void deliverDelta(TurnHandle h, String text) {
    h.guard(() => sink.subtitle += text);
  }

  /// 模拟记忆抽取回调：先校验身份，再落盘。
  void deliverMemory(TurnHandle h, String content) {
    h.guardPersist(() => sink.memories.add(content));
  }

  group('状态机与身份', () {
    test('文字轮次走 ready -> thinking -> ready', () {
      expect(turns.state, TurnState.ready);
      expect(turns.isIdle, isTrue);

      final h = turns.begin(TurnKind.userText)!;
      // 同步进入 thinking：UI 能在不等模型的情况下立刻给出本地反馈。
      expect(turns.state, TurnState.thinking);
      expect(turns.isBusy, isTrue);
      expect(h.isValid, isTrue);

      deliverDelta(h, '你好');
      expect(h.complete(), isTrue);

      expect(turns.state, TurnState.ready);
      expect(turns.activeTurn, isNull);
      expect(sink.subtitle, '你好');
      expect(h.outcome, TurnOutcome.completed);
    });

    test('语音轮次从 listening 起步，可走完整链路', () {
      final h = turns.begin(TurnKind.userVoice)!;
      expect(turns.state, TurnState.listening);

      for (final s in [
        TurnState.recognizing,
        TurnState.thinking,
        TurnState.synthesizing,
        TurnState.speaking,
      ]) {
        expect(h.advance(s), isTrue, reason: '应能推进到 ${s.name}');
        expect(turns.state, s);
      }

      h.complete();
      expect(turns.state, TurnState.ready);
    });

    test('turn_id 与 generation_epoch 单调递增，session_id 稳定', () {
      final first = turns.begin(TurnKind.userText)!;
      first.complete();
      final second = turns.begin(TurnKind.userText)!;

      expect(first.identity.sessionId, 'test-session');
      expect(second.identity.sessionId, 'test-session');
      expect(second.identity.turnId, greaterThan(first.identity.turnId));
      expect(
        second.identity.generationEpoch,
        greaterThan(first.identity.generationEpoch),
      );
    });
  });

  group('互斥与优先级', () {
    test('已有轮次在跑时，第二个文字轮次被拒绝而不是叠加', () {
      final first = turns.begin(TurnKind.userText)!;
      final second = turns.begin(TurnKind.userText);

      expect(second, isNull, reason: '不允许悄悄并行两轮');
      expect(first.isValid, isTrue, reason: '被拒绝的一方不该影响进行中的轮次');
      expect(turns.activeTurn, first);
    });

    test('问候轮次同样受互斥保护', () {
      final first = turns.begin(TurnKind.userText)!;
      // 旧实现里 _greet 不做任何检查，会直接踩掉正在进行的回答。
      expect(turns.begin(TurnKind.greeting), isNull);
      expect(turns.activeTurn, first);
    });

    test('主动轮次永远不抢占任何已有轮次', () {
      final user = turns.begin(TurnKind.userText)!;
      expect(turns.begin(TurnKind.proactive), isNull);
      expect(turns.begin(TurnKind.proactive, interrupt: true), isNull,
          reason: 'interrupt 对主动无效，主动不得打断用户');
      expect(turns.activeTurn, user);
    });

    test('用户轮次无条件抢占主动轮次，旧轮次立即失效', () {
      final proactive = turns.begin(TurnKind.proactive)!;
      deliverDelta(proactive, '在忙吗？');

      final user = turns.begin(TurnKind.userText)!;
      expect(user, isNotNull);
      expect(proactive.isValid, isFalse);
      expect(proactive.isCancelled, isTrue);

      // 被抢占的主动轮次后续 delta 全部丢弃。
      deliverDelta(proactive, '（被抢占后还在吐字）');
      expect(sink.subtitle, '在忙吗？');
      expect(user.isValid, isTrue);
    });

    test('两个用户轮次之间需要显式 interrupt', () {
      final first = turns.begin(TurnKind.userText)!;
      expect(turns.begin(TurnKind.userVoice), isNull);

      final second = turns.begin(TurnKind.userVoice, interrupt: true);
      expect(second, isNotNull);
      expect(first.isCancelled, isTrue);
      expect(turns.activeTurn, second);
    });
  });

  group('取消后到达的回调不产生副作用', () {
    test('取消后的 LLM delta 不覆盖字幕', () {
      final h = turns.begin(TurnKind.userText)!;
      deliverDelta(h, '前半句');

      turns.cancel(reason: 'user stop');

      deliverDelta(h, '取消之后才到的后半句');
      expect(sink.subtitle, '前半句', reason: '取消后不得继续追加字幕');
      expect(h.isValid, isFalse);
      expect(turns.state, TurnState.ready, reason: '取消后应回到可用状态');
    });

    test('取消后的记忆抽取不落盘', () {
      final h = turns.begin(TurnKind.userText)!;
      turns.cancel();

      deliverMemory(h, '用户住在杭州');
      expect(sink.memories, isEmpty);
      expect(h.canPersist, isFalse);
    });

    test('旧轮次的回调不会写进新轮次的字幕', () async {
      final old = turns.begin(TurnKind.userText)!;
      // 旧轮次的一条慢回调，在被取消之后才落地。
      final late = Future<void>.delayed(
        const Duration(milliseconds: 20),
        () => deliverDelta(old, '旧轮次的迟到内容'),
      );

      turns.cancel(reason: 'user stop');
      final fresh = turns.begin(TurnKind.userText)!;
      deliverDelta(fresh, '新轮次的回答');

      await late;

      expect(sink.subtitle, '新轮次的回答');
      expect(fresh.isValid, isTrue);
    });

    test('正常完成的轮次，即使用户已开始下一轮，记忆仍然落盘', () {
      final done = turns.begin(TurnKind.userText)!;
      done.complete();

      // 用户手快，记忆抽取还没回来就发了下一句。
      final next = turns.begin(TurnKind.userText)!;
      deliverMemory(done, '用户喜欢喝黑咖啡');

      expect(sink.memories, ['用户喜欢喝黑咖啡'],
          reason: '正常结束的轮次不该因为用户手快就丢记忆');
      // 但它已经不能再改字幕了。
      deliverDelta(done, '不该出现');
      expect(sink.subtitle, isEmpty);
      expect(next.isValid, isTrue);
    });

    test('失效句柄推进状态与收尾都是空操作', () {
      final h = turns.begin(TurnKind.userText)!;
      turns.cancel();
      final other = turns.begin(TurnKind.userText)!;

      expect(h.advance(TurnState.speaking), isFalse);
      expect(h.complete(), isFalse);
      expect(turns.state, TurnState.thinking, reason: '旧句柄不得改动当前状态');
      expect(turns.activeTurn, other);
    });

    test('空闲时取消是安全的空操作', () {
      turns.cancel(reason: 'noop');
      expect(turns.state, TurnState.ready);
      expect(turns.generationEpoch, 0);
      expect(log.join('\n'), contains('cancel noop'));
    });
  });

  group('配置与记忆变更使旧结果失效', () {
    test('配置热更新在生成中途到达时，先失效再应用', () {
      final h = turns.begin(TurnKind.userText)!;
      deliverDelta(h, '按旧人设生成的');

      // 旧实现直接 _ai.updateConfig，导致半句旧人设 + 半句新人设。
      turns.invalidate(reason: 'config-changed');

      deliverDelta(h, '换人设后又追加的');
      deliverMemory(h, '换配置前抽出的记忆');

      expect(sink.subtitle, '按旧人设生成的');
      expect(sink.memories, isEmpty);
      expect(turns.isIdle, isTrue, reason: '失效后应当可以立刻开新一轮');
      expect(turns.begin(TurnKind.userText), isNotNull);
    });

    test('删除记忆后，在途轮次的结果不再落盘', () {
      final h = turns.begin(TurnKind.userText)!;
      turns.invalidate(reason: 'memory-deleted');
      deliverMemory(h, '基于已删除记忆产生的内容');
      expect(sink.memories, isEmpty);
    });
  });

  group('暂停与不可用', () {
    test('锁屏期间拒绝一切新轮次，恢复后不自动补播', () {
      turns.pause(reason: 'locked');
      expect(turns.state, TurnState.paused);

      expect(turns.begin(TurnKind.proactive), isNull);
      expect(turns.begin(TurnKind.userText), isNull);
      expect(turns.begin(TurnKind.userText, interrupt: true), isNull);

      turns.resume();
      expect(turns.state, TurnState.ready);
      expect(turns.begin(TurnKind.userText), isNotNull);
    });

    test('锁屏会取消在途轮次', () {
      final h = turns.begin(TurnKind.proactive)!;
      turns.pause();
      deliverDelta(h, '锁屏后才到的主动内容');
      expect(sink.subtitle, isEmpty);
      expect(h.isCancelled, isTrue);
    });

    test('能力不可用时拒绝新轮次，但停止入口仍然有效', () {
      final h = turns.begin(TurnKind.userText)!;
      turns.markUnavailable(reason: 'model gone');

      expect(h.isCancelled, isTrue, reason: '不可用时在途轮次必须被取消');
      expect(turns.begin(TurnKind.userText), isNull);

      // INV-08：停止路径不依赖模型，任何状态下都不许抛。
      turns.cancel(reason: 'user stop while unavailable');
      expect(turns.state, TurnState.unavailable);

      turns.markAvailable();
      expect(turns.begin(TurnKind.userText), isNotNull);
    });
  });

  group('可观测性', () {
    test('状态变化对外通知，且取消会经过 cancelling', () {
      final seen = <TurnState>[];
      turns.onStateChanged = seen.add;

      final h = turns.begin(TurnKind.userVoice)!;
      h.advance(TurnState.recognizing);
      h.advance(TurnState.thinking);
      turns.cancel();

      expect(seen, [
        TurnState.listening,
        TurnState.recognizing,
        TurnState.thinking,
        TurnState.cancelling,
        TurnState.ready,
      ]);
    });

    test('被拒绝与被丢弃的回调都留下日志', () {
      final h = turns.begin(TurnKind.userText)!;
      turns.begin(TurnKind.proactive);
      turns.cancel();
      h.advance(TurnState.speaking);

      final text = log.join('\n');
      expect(text, contains('begin rejected kind=proactive'));
      expect(text, contains('advance dropped (stale)'));
    });
  });
}

class _Sink {
  String subtitle = '';
  final List<String> memories = [];
}
