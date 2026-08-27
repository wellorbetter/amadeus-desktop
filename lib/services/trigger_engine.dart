import 'dart:async';

import 'pet_config.dart';
import 'pet_logger.dart';
import 'pet_memory.dart';
import 'tt_api.dart';

/// 主动交互触发引擎：每 60 秒基于内置活动感知 + 动态配置评估一次，
/// 满足条件且未超频率限制时，回调 [onProactive] 发起主动聊天。
///
/// 休眠省电：连续空闲达到阈值（sleepIdleMinutes）后进入休眠，
/// 停止一切主动对话（LLM 零调用）；用户恢复活动或主动发消息时自动唤醒。
/// 忙时自适应：今天活跃很久且当前未空闲时，自动拉长间隔、降低每小时上限。
class TriggerEngine {
  TriggerEngine({required this.tt});

  final TtApi tt;
  final PetConfig cfg = PetConfig.instance;

  /// 触发主动聊天时回调（参数为给 AI 的提示词）。
  void Function(String prompt)? onProactive;

  /// 休眠状态变化回调（true=进入休眠，false=唤醒）。
  void Function(bool sleeping)? onSleepChanged;

  Timer? _timer;
  bool _running = false;
  bool _warmup = true; // 启动后的第一次 tick 只做状态/休眠检测，不触发对话（避免和启动问候撞车）

  bool _sleeping = false;
  int _idleStreakTicks = 0; // 连续空闲 tick 数（tick≈1 分钟）
  int _heartbeatTicks = 0; // 心跳日志计数（每 30 tick 报一次）
  bool _busy = false; // 忙时自适应：当前是否处于「忙」

  int _lastHour = -1;
  int _lastSwitches = -1;
  int _activeHour = -1;
  int _hourCount = 0;
  DateTime? _lastProactiveAt;
  DateTime? _longSessionNotifiedAt;
  // 空闲→恢复 / 应用专注 检测状态
  int _lastIdleMin = -1;
  bool _wasIdling = false;
  String _lastForeground = '-';
  int _foregroundTicks = 0;
  DateTime? _focusNotifiedAt;
  int _lastNudgedMemoryId = -1; // 最近一次「记忆关心」用到的记忆 id
  static const int _focusThresholdTicks = 90; // 连续同一前台应用 90 分钟算专注
  static const int _busyActiveMinutes = 240; // 今天活跃超过 4 小时视为「忙」

  bool get sleeping => _sleeping;

  void start() {
    if (_timer != null) return;
    PetLog.i('trigger: engine start (tick=60s)');
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _tick());
    // 启动后立即评估一次：尽快进入/退出休眠判断，避免启动问候撞上用户离开
    unawaited(_tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 用户主动互动（发消息/点桌宠）时强制唤醒。
  void wake() {
    if (_sleeping) _exitSleep();
  }

  void _enterSleep(int idleMin) {
    _sleeping = true;
    PetLog.i(
      'trigger: sleep enter idle=$idleMin (stop proactive, save tokens)',
    );
    onSleepChanged?.call(true);
  }

  void _exitSleep() {
    if (!_sleeping) return;
    _sleeping = false;
    _idleStreakTicks = 0;
    PetLog.i('trigger: sleep exit (user active again)');
    onSleepChanged?.call(false);
  }

  Future<void> _tick() async {
    if (_running) return;
    _running = true;
    try {
      final changed = cfg.reloadIfChanged();
      if (changed) PetLog.i('trigger: config hot-reloaded');
      if (!cfg.proactiveEnabled) return;

      await tt.refresh();
      final hasData = tt.hasData;

      // —— 数据依赖的状态检测（空闲/休眠/专注/忙）——
      // 无活动数据时按「在线模式」处理：保留整点/深夜/记忆关心/随机搭话等
      // 不依赖数据的主动互动（修复：不开数据服务时她完全不理人的问题）。
      var idleGrowing = false;
      var idleReturned = false;
      var focusLong = false;
      if (hasData) {
        // 空闲→恢复检测：空闲分钟数停止增长即认为用户刚回来（需两拍对比）
        final idleNow = tt.idleMinutes;
        idleGrowing = _lastIdleMin >= 0 && idleNow > _lastIdleMin;
        idleReturned = _wasIdling && !idleGrowing && _lastIdleMin >= 0;
        _wasIdling = idleGrowing || (_lastIdleMin < 0 && idleNow > 0);

        // 连续空闲分钟数（近似：tick=60s，空闲分钟持续增长即视为持续空闲）
        if (idleGrowing) {
          final jump = idleNow - _lastIdleMin;
          // 一次 tick 空闲暴涨（睡眠/锁屏恢复）：按整段连续空闲计，立刻进入休眠省 token
          _idleStreakTicks += jump >= 5 ? jump : 1;
        } else {
          _idleStreakTicks = 0;
        }
        _lastIdleMin = idleNow;

        // 休眠省电：连续空闲达到阈值后停止一切主动对话（LLM 零调用）
        if (cfg.sleepEnabled) {
          if (!_sleeping && _idleStreakTicks >= cfg.sleepIdleMinutes) {
            _enterSleep(idleNow);
          } else if (_sleeping && !idleGrowing) {
            _exitSleep();
          }
        }

        // 专注检测：同一前台应用连续累计 tick 数
        final fg = tt.foregroundApp;
        if (fg.isNotEmpty && fg != '-' && fg == _lastForeground) {
          _foregroundTicks++;
        } else {
          _foregroundTicks = 0;
          _lastForeground = fg;
        }
        focusLong = _foregroundTicks >= _focusThresholdTicks;
      } else {
        // 无活动数据：清空数据依赖的状态，避免旧值误触发
        if (_sleeping) _exitSleep();
        _idleStreakTicks = 0;
        _wasIdling = false;
        _lastIdleMin = -1;
        _foregroundTicks = 0;
        _lastForeground = '-';
      }
      // 心跳日志：每 30 tick 报一次状态，便于确认引擎存活（含休眠期）
      _heartbeatTicks++;
      if (_heartbeatTicks % 30 == 0) {
        PetLog.i(
          'trigger: heartbeat sleep=$_sleeping hasData=$hasData '
          'idleStreak=$_idleStreakTicks busy=$_busy',
        );
      }
      if (_sleeping) return;

      // 预热：首 tick 只完成状态检测（空闲streak/休眠判断），不发起主动对话
      if (_warmup) {
        _warmup = false;
        PetLog.i(
          'trigger: warmup tick done (sleep/state only) hasData=$hasData',
        );
        return;
      }

      // 忙时自适应：未空闲且今天活跃很久 → 拉长间隔、降低上限、跳过随机搭话
      final busy =
          hasData &&
          cfg.adaptiveFrequency &&
          !idleGrowing &&
          tt.activeMinutes >= _busyActiveMinutes;
      if (busy != _busy) {
        _busy = busy;
        PetLog.i(
          'trigger: activity=${busy ? 'busy' : 'normal'} '
          'activeMin=${tt.activeMinutes} hasData=$hasData',
        );
      }

      final now = DateTime.now();
      if (_lastHour == -1) _lastHour = now.hour;
      final hourChanged = now.hour != _lastHour;
      _lastHour = now.hour;

      if (now.hour != _activeHour) {
        _activeHour = now.hour;
        _hourCount = 0;
      }

      // 频率限制：最小间隔（忙时 ×2）+ 每小时上限（忙时减半）
      final gap = Duration(
        minutes: (cfg.minIntervalMinutes * (busy ? 2 : 1)).round(),
      );
      if (_lastProactiveAt != null && now.difference(_lastProactiveAt!) < gap) {
        return;
      }
      final maxPerHour = busy ? (cfg.maxPerHour / 2).ceil() : cfg.maxPerHour;
      if (_hourCount >= maxPerHour) return;

      final prompt = _evaluate(
        now,
        hourChanged,
        idleReturned,
        focusLong,
        busy,
        hasData,
      );
      if (prompt == null) return;

      _lastProactiveAt = now;
      _hourCount++;
      PetLog.i('trigger: fire hourCount=$_hourCount prompt=${_clip(prompt)}');
      PetMemory.instance.record('system', '触发主动聊天：$prompt');
      onProactive?.call(prompt);
    } catch (e) {
      PetLog.e('trigger: tick error: $e');
    } finally {
      _running = false;
    }
  }

  String? _evaluate(
    DateTime now,
    bool hourChanged,
    bool idleReturned,
    bool focusLong,
    bool busy,
    bool hasData,
  ) {
    // 1) 整点
    if (cfg.triggerHourly && hourChanged && now.minute <= 2) {
      return '现在是 ${now.hour} 点，自然地和用户打个招呼或关心一句（简短，可结合观测语料，别生硬报数）。';
    }

    // 2) 深夜（画像感知：常熬夜的用户更坚定地催休息）
    if (cfg.triggerLateNight && (now.hour >= 23 || now.hour < 5)) {
      final p = PetMemory.instance.profile();
      if ((p['lateNightRatio'] as double? ?? 0) > 0.4) {
        return '时间不早了（用户最近常熬夜），温柔但更坚定地催用户早点休息（简短自然，可结合观测语料，别生硬报数）。';
      }
      return '时间不早了，温柔地提醒用户注意休息（简短自然，别数叨）。';
    }

    // 2.5) 空闲后回来（依赖数据）
    if (hasData && cfg.triggerIdleReturn && idleReturned) {
      return '用户刚离开又回来了，自然地打个招呼或关心一句（简短，可结合观测语料，别生硬报数）。';
    }

    // 3) 长时间连续使用（依赖数据）
    if (hasData &&
        cfg.triggerLongSession &&
        tt.activeMinutes >= cfg.longSessionMinutes) {
      if (_longSessionNotifiedAt == null ||
          now.difference(_longSessionNotifiedAt!) > const Duration(hours: 2)) {
        _longSessionNotifiedAt = now;
        return '用户好像连续用了很久，自然地关心一句要不要起来活动一下（可结合观测语料，别生硬报数）。';
      }
    }

    // 4) 窗口切换激增（一分钟内切换 >= 8 次，依赖数据）
    if (hasData && cfg.triggerAppSwitchSpike && _lastSwitches != -1) {
      final delta = tt.switches - _lastSwitches;
      _lastSwitches = tt.switches;
      if (delta >= 8) {
        return '用户刚才疯狂切换窗口，轻轻吐槽或关心一句（自然一点，可结合观测语料）。';
      }
    } else if (hasData) {
      _lastSwitches = tt.switches;
    }

    // 4.5) 长时间专注同一应用（依赖数据）
    if (hasData && cfg.triggerFocusReminder && focusLong) {
      if (_focusNotifiedAt == null ||
          now.difference(_focusNotifiedAt!) > const Duration(hours: 2)) {
        _focusNotifiedAt = now;
        return '用户盯着同一个应用很久了，自然地提醒一句起来活动一下（简短，可结合观测语料，别生硬报数）。';
      }
    }

    // 4.8) 记忆驱动的关心：聊过的重要事（目标/偏好/事件），过一会儿自然提起
    if (cfg.triggerMemoryNudge) {
      final mem = PetMemory.instance.topMemory(excludeId: _lastNudgedMemoryId);
      if (mem != null && (mem['importance'] as int? ?? 0) >= 3) {
        _lastNudgedMemoryId = mem['id'] as int? ?? -1;
        return '用户之前提到过：${mem['content']}。自然地关心一下进展（简短，别生硬转场，可结合观测语料）。';
      }
    }

    // 5) 随机搭话（忙时不打扰）
    if (cfg.triggerRandomNudge && !busy) {
      if (_lastProactiveAt == null) {
        return '主动找个话题和用户聊两句（简短自然，像朋友）。';
      }
      final rnd = (now.millisecondsSinceEpoch % 1000) / 1000.0;
      if (rnd < cfg.randomNudgeChance) {
        const topics = [
          '随便找个轻松话题和用户聊两句。',
          '像朋友一样问用户一个问题。',
          '聊聊最近在读的书、音乐或生活日常。',
        ];
        return topics[now.second % topics.length];
      }
    }
    return null;
  }

  String _clip(String s) => s.length > 60 ? '${s.substring(0, 60)}…' : s;
}
