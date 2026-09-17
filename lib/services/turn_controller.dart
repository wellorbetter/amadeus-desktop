import 'dart:math';

/// 轮次状态机（Spec §7.1）。
///
/// ```text
/// ready -> listening -> recognizing -> thinking -> synthesizing -> speaking -> ready
/// ready -> thinking -> ready                         # 文字输入
/// 任何活动态 -> cancelling -> ready / paused / unavailable
/// ```
///
/// 服务健康、窗口显示、麦克风授权、输出静音、勿扰都**不**属于轮次状态：
/// TTS 不可用不能把可用的文字聊天一起锁死。
enum TurnState {
  ready,
  listening,
  recognizing,
  thinking,
  synthesizing,
  speaking,
  cancelling,
  paused,
  unavailable,
}

/// 轮次由谁发起。决定抢占关系：用户前台交互优先于主动交流（INV-07）。
enum TurnKind {
  /// 用户在输入框里发的文字。
  userText,

  /// 用户按下「说话」发起的语音轮次。
  userVoice,

  /// 启动问候。
  greeting,

  /// 主动交流。
  proactive,

  /// 后台记忆抽取等不面向用户的工作。
  background,
}

extension TurnKindX on TurnKind {
  /// 用户显式发起的轮次。
  bool get isUserInitiated =>
      this == TurnKind.userText || this == TurnKind.userVoice;
}

/// 一轮的最终归属。
///
/// 与 [TurnState] 不同：状态描述「现在在做什么」，归属描述「这一轮算不算数」。
/// 两者必须分开，否则会把正常完成的轮次和被取消的轮次混为一谈 ——
/// 前者的记忆抽取结果应当写入，后者不应当。
enum TurnOutcome {
  /// 仍在进行。
  active,

  /// 正常收尾。
  completed,

  /// 被停止、被抢占，或因配置/记忆变更而失效。
  cancelled,
}

/// 轮次身份三元组（Spec §7.1）。
class TurnIdentity {
  const TurnIdentity({
    required this.sessionId,
    required this.turnId,
    required this.generationEpoch,
  });

  final String sessionId;
  final int turnId;

  /// 单调递增。开始新轮、取消、变更输出设备、删除记忆、切换模型、锁屏
  /// 都会推进它，从而使所有旧句柄一次性失效。
  final int generationEpoch;

  @override
  String toString() => '$sessionId/t$turnId/e$generationEpoch';
}

/// 一次轮次的句柄。
///
/// 五条异步回调路径（ASR、LLM、TTS、播放器、记忆抽取）都必须持有它，
/// 并在提交任何副作用**之前**检查 [isValid]。这是 INV-03 的唯一执行点。
class TurnHandle {
  TurnHandle._(this._owner, this.identity, this.kind);

  final TurnController _owner;
  final TurnIdentity identity;
  final TurnKind kind;

  TurnOutcome _outcome = TurnOutcome.active;

  TurnOutcome get outcome => _outcome;

  /// 本句柄是否仍是当前轮次。取消、抢占、配置变更后立即为 false。
  ///
  /// 这是**面向用户可见输出**的守卫：字幕、气泡、播放、口型。
  bool get isValid => _owner.isValid(this);

  /// 本轮是否被取消过。
  bool get isCancelled => _outcome == TurnOutcome.cancelled;

  /// 本轮的结果是否允许落盘。
  ///
  /// 这是**面向持久化**的守卫：记忆抽取、消息入库。与 [isValid] 的区别是
  /// 它容许「本轮已正常结束、用户已经开始下一轮」这种情况 ——
  /// 上一轮的记忆不该因为用户手快就丢掉。只有被取消的轮次才不许落盘。
  bool get canPersist => _outcome != TurnOutcome.cancelled;

  /// 仅在句柄仍是当前轮次时执行 [action]。失效则原样丢弃并返回 null，
  /// **不产生任何副作用**（不覆盖字幕、不播放、不写口型）。
  T? guard<T>(T Function() action) => isValid ? action() : null;

  /// 仅在本轮未被取消时执行 [action]，用于记忆等落盘副作用。
  T? guardPersist<T>(T Function() action) => canPersist ? action() : null;

  /// 推进状态。句柄失效时是空操作。
  bool advance(TurnState next) => _owner._advance(this, next);

  /// 正常收尾：回到 ready。句柄失效时是空操作。
  bool complete() => _owner._complete(this);

  @override
  String toString() => '${kind.name}@$identity';
}

/// 轮次编排中枢。
///
/// 从 UI 里抽出来的原因：ASR、LLM、TTS、播放器、记忆抽取是五条独立异步
/// 回调路径。把「谁是当前轮次」这件事留在 widget 的一个 bool 上，等语音接进来
/// 就会变成最难排查的一类竞态缺陷 —— 旧轮次的音频覆盖新字幕、取消后仍然写记忆。
///
/// 本类不依赖 Flutter，可直接单测。
class TurnController {
  TurnController({String? sessionId, void Function(String message)? logger})
    : sessionId = sessionId ?? _newSessionId(),
      _log = logger;

  final String sessionId;
  final void Function(String message)? _log;

  static const Set<TurnState> _activeStates = {
    TurnState.listening,
    TurnState.recognizing,
    TurnState.thinking,
    TurnState.synthesizing,
    TurnState.speaking,
  };

  TurnState _state = TurnState.ready;
  int _turnId = 0;
  int _epoch = 0;
  TurnHandle? _active;

  /// 状态变化通知（供 UI 刷新）。
  void Function(TurnState state)? onStateChanged;

  TurnState get state => _state;
  int get generationEpoch => _epoch;
  int get lastTurnId => _turnId;
  TurnHandle? get activeTurn => _active;

  /// 有轮次正在进行。
  bool get isBusy => _activeStates.contains(_state);

  /// 可以开始新轮次。
  bool get isIdle => _state == TurnState.ready;

  /// 正在进行的轮次由用户显式发起。
  bool get isUserTurnActive => isBusy && (_active?.kind.isUserInitiated ?? false);

  /// 开始一轮。
  ///
  /// 返回 null 表示**被拒绝**，调用方不得继续。拒绝的三种情况：
  /// - 能力不可用（[TurnState.unavailable]）或已暂停（锁屏）。
  /// - 已有轮次在跑，且本次不具备抢占资格。
  /// - 主动轮次永远不抢占任何已有轮次（INV-07）。
  ///
  /// [interrupt] 只对用户发起的轮次有效，表示用户明确要中断当前轮。
  /// 用户轮次可以无条件抢占问候与主动轮次；两个用户轮次之间必须显式 [interrupt]，
  /// 不允许悄悄叠加两轮播放（Spec §7.1）。
  TurnHandle? begin(TurnKind kind, {bool interrupt = false}) {
    if (_state == TurnState.unavailable || _state == TurnState.paused) {
      _logLine('begin rejected kind=${kind.name} state=${_state.name}');
      return null;
    }
    if (!isIdle) {
      final current = _active?.kind;
      final preemptsLowerPriority =
          kind.isUserInitiated && current != null && !current.isUserInitiated;
      final explicitInterrupt = kind.isUserInitiated && interrupt;
      if (!preemptsLowerPriority && !explicitInterrupt) {
        _logLine(
          'begin rejected kind=${kind.name} busy=${current?.name} '
          'state=${_state.name}',
        );
        return null;
      }
      cancel(reason: 'preempted by ${kind.name}');
    }
    _turnId++;
    _epoch++;
    final handle = TurnHandle._(
      this,
      TurnIdentity(
        sessionId: sessionId,
        turnId: _turnId,
        generationEpoch: _epoch,
      ),
      kind,
    );
    _active = handle;
    _setState(kind == TurnKind.userVoice ? TurnState.listening : TurnState.thinking);
    _logLine('begin $handle');
    return handle;
  }

  bool isValid(TurnHandle handle) =>
      handle._outcome == TurnOutcome.active &&
      handle.identity.sessionId == sessionId &&
      handle.identity.generationEpoch == _epoch &&
      _active == handle;

  bool _advance(TurnHandle handle, TurnState next) {
    if (!isValid(handle)) {
      _logLine('advance dropped (stale) $handle -> ${next.name}');
      return false;
    }
    if (next == TurnState.ready) return _complete(handle);
    _setState(next);
    return true;
  }

  bool _complete(TurnHandle handle) {
    if (!isValid(handle)) {
      _logLine('complete dropped (stale) $handle');
      return false;
    }
    handle._outcome = TurnOutcome.completed;
    _active = null;
    _setState(TurnState.ready);
    _logLine('complete $handle');
    return true;
  }

  /// 取消当前轮次。不经过模型，永远可用（INV-03）。
  ///
  /// 推进 epoch 并把该轮标记为 cancelled，使所有在途回调立即失效 ——
  /// 既不覆盖字幕，也不写入记忆。没有轮次在跑时是安全的空操作。
  ///
  /// 停止只结束轮次，**不改变外部状态**：`paused` 与 `unavailable` 是锁屏与
  /// 能力缺失造成的，按一下停止不该让不可用的能力看起来又可用了。
  void cancel({String reason = 'user'}) {
    final cancelled = _active;
    final blocked =
        _state == TurnState.paused || _state == TurnState.unavailable;
    if (cancelled == null && (isIdle || blocked)) {
      _logLine('cancel noop reason=$reason state=${_state.name}');
      return;
    }
    cancelled?._outcome = TurnOutcome.cancelled;
    _active = null;
    _epoch++;
    _logLine('cancel $cancelled reason=$reason -> epoch=$_epoch');
    if (blocked) return;
    _setState(TurnState.cancelling);
    _setState(TurnState.ready);
  }

  /// 使在途轮次失效，但不表示用户按了停止。
  ///
  /// 用于「旧结果已经不能用了」的场合：变更输出设备、删除或纠正记忆、
  /// 切换模型、切换人设、配置热更新。在途轮次按取消处理，其结果一律不落盘。
  void invalidate({required String reason}) {
    _epoch++;
    final dropped = _active;
    dropped?._outcome = TurnOutcome.cancelled;
    _active = null;
    _logLine('invalidate reason=$reason dropped=$dropped -> epoch=$_epoch');
    if (_state != TurnState.paused && _state != TurnState.unavailable) {
      _setState(TurnState.ready);
    }
  }

  /// 锁屏 / 系统睡眠：停止主动与采集播放，并丢弃在途结果。
  void pause({String reason = 'locked'}) {
    cancel(reason: reason);
    _setState(TurnState.paused);
    _logLine('paused reason=$reason');
  }

  /// 恢复。不补播漏掉的内容，不自动开麦。
  void resume() {
    if (_state != TurnState.paused) return;
    _setState(TurnState.ready);
    _logLine('resumed');
  }

  /// 能力整体不可用（无模型、无设备）。此时拒绝新轮次，但停止入口仍然有效。
  void markUnavailable({required String reason}) {
    cancel(reason: reason);
    _setState(TurnState.unavailable);
    _logLine('unavailable reason=$reason');
  }

  void markAvailable() {
    if (_state != TurnState.unavailable) return;
    _setState(TurnState.ready);
    _logLine('available');
  }

  void _setState(TurnState next) {
    if (_state == next) return;
    _state = next;
    onStateChanged?.call(next);
  }

  void _logLine(String message) => _log?.call('turn: $message');

  static String _newSessionId() {
    final rnd = Random();
    final now = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final tail = rnd.nextInt(1 << 20).toRadixString(36).padLeft(4, '0');
    return 's$now$tail';
  }
}
