import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 动态配置：%APPDATA%/timepet/config.json
/// 设置面板修改即时保存并热生效，无需重启；也支持外部编辑后 60 秒自动热加载。
class PetConfig {
  PetConfig({String? pathOverride}) : _pathOverride = pathOverride;

  static final PetConfig instance = PetConfig();

  final String? _pathOverride;

  File? _file;
  DateTime? _lastLoad;

  /// 配置版本号：save()/load() 时自增，设置窗口监听它切换深浅主题。
  final ValueNotifier<int> revision = ValueNotifier(0);

  // ---- 外观（Live2D 显示与对话气泡）----
  double modelScale = 1.0; // 模型缩放（相对画布）
  int displayWidth = 440; // 画布宽（CSS px）
  int displayHeight = 640; // 画布高（CSS px）
  int hOffset = 0; // 水平偏移（相对居中）
  int vOffset = 10; // 底部留白（px）
  double modelOpacity = 1.0; // 模型透明度 0.3~1.0
  bool soundEnabled = false; // 模型动作音效（动作自带的 mp3）开关，默认静音
  double soundVolume = 0.8; // 音效音量 0~1
  double bubbleFontSize = 13.0; // 气泡字号
  int bubbleAutoHideSeconds = 8; // 气泡自动隐藏秒数
  bool darkMode = true; // 设置窗口深浅主题（true=深色）
  double settingsOpacity = 0.96; // 设置窗口整体透明度
  String modelPath =
      ''; // Live2D 模型 json 路径（留空自动扫描 exe 目录/models 与 %APPDATA%/timepet/models）

  // ---- 主动对话 ----
  bool proactiveEnabled = true;
  double minIntervalMinutes = 20; // 两次主动对话最小间隔（分钟）
  int maxPerHour = 2; // 每小时最多主动次数
  bool triggerHourly = true; // 整点触发
  bool triggerLateNight = true; // 深夜（23~5 点）触发
  bool triggerLongSession = true; // 长时间连续使用触发
  bool triggerAppSwitchSpike = true; // 疯狂切窗触发
  bool triggerRandomNudge = true; // 随机搭话
  bool triggerIdleReturn = true; // 空闲后回来触发
  bool triggerFocusReminder = true; // 长时间专注提醒
  bool triggerMemoryNudge = true; // 记忆驱动的关心（重要事主动提起）
  double randomNudgeChance = 0.25; // 随机搭话概率

  // ---- 省电/休眠 ----
  bool sleepEnabled = true; // 连续空闲达到阈值后休眠，停止主动对话与记忆审核（省 token）
  int sleepIdleMinutes = 15; // 连续空闲多少分钟进入休眠
  bool adaptiveFrequency = true; // 忙时自动降低打扰频率
  int longSessionMinutes = 120; // 连续使用多久算「久坐」

  // ---- 聊天 ----
  int chatAutoHideSeconds = 20; // 无操作多少秒后自动收起输入框

  // ---- AI ----
  bool aiEnabled = true;
  String aiAuthMode = 'openai_api_key';
  String aiApiKey = '';
  String aiBaseUrl = 'https://api.openai.com/v1';
  String aiModel = 'gpt-5.6-luna';
  String soulText = '';
  String soulFile =
      ''; // 人格插件 soul.md 路径（留空自动检测 %APPDATA%/timepet/soul.md 或 exe 目录/soul.md）
  double aiTemperature = 0.8;
  int aiMaxTokens = 800; // AI 单次回复最大 token 数（防长回复截断）

  // ---- 日志 ----
  bool logEnabled = true;
  String logLevel = 'INFO'; // INFO / WARN / ERROR

  // ---- 窗口 ----
  bool alwaysOnTop = true;
  bool skipTaskbar = false;
  bool startVisible = true;
  bool autoFitWindow = true; // 启动时按模型比例自动调整窗口大小

  String get path {
    final override = _pathOverride;
    if (override != null) return override;
    final appData =
        Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    return '$appData/timepet/config.json';
  }

  File get file => _file ??= File(path);

  Map<String, dynamic> _defaults() => {
    '_说明':
        'TimeTrace 桌宠动态配置。设置面板修改即时生效；外部编辑后 60 秒内自动热加载（无需重启）。proactive 为主动说话；triggers 为各触发开关；chat 为聊天框行为；sleep 为省电休眠（空闲时停止主动对话/记忆审核，省 token）；appearance 为模型/气泡外观；ai 为对话模型；log 为日志；window 为窗口行为。',
    'appearance': {
      'modelScale': 1.0,
      'displayWidth': 440,
      'displayHeight': 640,
      'hOffset': 0,
      'vOffset': 10,
      'modelOpacity': 1.0,
      'soundEnabled': false,
      'soundVolume': 0.8,
      'bubbleFontSize': 13.0,
      'bubbleAutoHideSeconds': 8,
      'darkMode': true,
      'settingsOpacity': 0.96,
      'modelPath': '',
    },
    'proactive': {
      'enabled': true,
      'minIntervalMinutes': 20.0,
      'maxPerHour': 2,
      'longSessionMinutes': 120,
      'randomNudgeChance': 0.25,
      'triggers': {
        'hourly': true,
        'lateNight': true,
        'longSession': true,
        'appSwitchSpike': true,
        'randomNudge': true,
        'idleReturn': true,
        'focusReminder': true,
        'memoryNudge': true,
      },
    },
    'chat': {'autoHideSeconds': 20},
    'sleep': {'enabled': true, 'idleMinutes': 15, 'adaptiveFrequency': true},
    'ai': {
      'enabled': true,
      'authMode': 'openai_api_key',
      'apiKey': '',
      'baseUrl': 'https://api.openai.com/v1',
      'model': 'gpt-5.6-luna',
      'temperature': 0.8,
      'maxTokens': 800,
      'soulFile': '',
      'soulText': '',
    },
    'log': {'enabled': true, 'level': 'INFO'},
    'window': {
      'alwaysOnTop': true,
      'skipTaskbar': false,
      'startVisible': true,
      'autoFitWindow': true,
    },
  };

  /// 读取配置（文件不存在则写入默认值）。
  void load() {
    try {
      final f = file;
      if (!f.existsSync()) {
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(_defaults()),
        );
      }
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _apply(_defaults());
      _apply(json);
      _lastLoad = f.statSync().modified;
      revision.value++;
    } catch (e) {
      // 配置损坏时保持默认值
    }
  }

  /// 热加载：文件被修改则重新读取，返回是否发生变更。
  /// Restore every setting to the shipped defaults and persist the result.
  /// This intentionally also clears user-selected model/soul paths.
  void resetToDefaults({bool persist = true}) {
    _apply(_defaults());
    if (persist) {
      save();
    } else {
      revision.value++;
    }
  }

  bool reloadIfChanged() {
    try {
      final stat = file.statSync();
      if (_lastLoad == null || stat.modified.isAfter(_lastLoad!)) {
        load();
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// 把当前内存配置写回文件（设置面板调用，即时生效）。
  bool save() {
    try {
      final f = file;
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
      _lastLoad = f.statSync().modified;
      revision.value++;
      return true;
    } catch (_) {}
    return false;
  }

  Map<String, dynamic> toJson() => {
    '_说明': _defaults()['_说明'],
    'appearance': {
      'modelScale': modelScale,
      'displayWidth': displayWidth,
      'displayHeight': displayHeight,
      'hOffset': hOffset,
      'vOffset': vOffset,
      'modelOpacity': modelOpacity,
      'soundEnabled': soundEnabled,
      'soundVolume': soundVolume,
      'bubbleFontSize': bubbleFontSize,
      'bubbleAutoHideSeconds': bubbleAutoHideSeconds,
      'darkMode': darkMode,
      'settingsOpacity': settingsOpacity,
      'modelPath': modelPath,
    },
    'proactive': {
      'enabled': proactiveEnabled,
      'minIntervalMinutes': minIntervalMinutes,
      'maxPerHour': maxPerHour,
      'longSessionMinutes': longSessionMinutes,
      'randomNudgeChance': randomNudgeChance,
      'triggers': {
        'hourly': triggerHourly,
        'lateNight': triggerLateNight,
        'longSession': triggerLongSession,
        'appSwitchSpike': triggerAppSwitchSpike,
        'randomNudge': triggerRandomNudge,
        'idleReturn': triggerIdleReturn,
        'focusReminder': triggerFocusReminder,
        'memoryNudge': triggerMemoryNudge,
      },
    },
    'chat': {'autoHideSeconds': chatAutoHideSeconds},
    'sleep': {
      'enabled': sleepEnabled,
      'idleMinutes': sleepIdleMinutes,
      'adaptiveFrequency': adaptiveFrequency,
    },
    'ai': {
      'enabled': aiEnabled,
      'authMode': aiAuthMode,
      'apiKey': aiApiKey,
      'baseUrl': aiBaseUrl,
      'model': aiModel,
      'temperature': aiTemperature,
      'maxTokens': aiMaxTokens,
      'soulFile': soulFile,
      'soulText': soulText,
    },
    'log': {'enabled': logEnabled, 'level': logLevel},
    'window': {
      'alwaysOnTop': alwaysOnTop,
      'skipTaskbar': skipTaskbar,
      'startVisible': startVisible,
      'autoFitWindow': autoFitWindow,
    },
  };

  num _number(Object? value, num fallback) => value is num ? value : fallback;

  void _apply(Map<String, dynamic> json) {
    final a = json['appearance'];
    if (a is Map<String, dynamic>) {
      modelScale = _number(a['modelScale'], 1.0).clamp(0.1, 3.0).toDouble();
      displayWidth = _number(a['displayWidth'], 440).clamp(180, 1200).toInt();
      displayHeight = _number(a['displayHeight'], 640).clamp(240, 1600).toInt();
      hOffset = _number(a['hOffset'], 0).clamp(-2000, 2000).toInt();
      vOffset = _number(a['vOffset'], 10).clamp(-2000, 2000).toInt();
      modelOpacity = _number(a['modelOpacity'], 1.0).clamp(0.1, 1.0).toDouble();
      soundEnabled = a['soundEnabled'] as bool? ?? false;
      soundVolume = _number(a['soundVolume'], 0.8).clamp(0.0, 1.0).toDouble();
      bubbleFontSize = _number(
        a['bubbleFontSize'],
        13.0,
      ).clamp(8.0, 32.0).toDouble();
      bubbleAutoHideSeconds = _number(
        a['bubbleAutoHideSeconds'],
        8,
      ).clamp(1, 120).toInt();
      darkMode = a['darkMode'] as bool? ?? true;
      settingsOpacity = _number(
        a['settingsOpacity'],
        0.96,
      ).clamp(0.75, 1.0).toDouble();
      modelPath = a['modelPath']?.toString() ?? '';
    }
    final p = json['proactive'];
    if (p is Map<String, dynamic>) {
      proactiveEnabled = p['enabled'] as bool? ?? true;
      minIntervalMinutes = _number(
        p['minIntervalMinutes'],
        20,
      ).clamp(1.0, 1440.0).toDouble();
      maxPerHour = _number(p['maxPerHour'], 2).clamp(0, 24).toInt();
      longSessionMinutes = _number(
        p['longSessionMinutes'],
        120,
      ).clamp(1, 1440).toInt();
      randomNudgeChance = _number(
        p['randomNudgeChance'],
        0.25,
      ).clamp(0.0, 1.0).toDouble();
      final t = p['triggers'];
      if (t is Map<String, dynamic>) {
        triggerHourly = t['hourly'] as bool? ?? true;
        triggerLateNight = t['lateNight'] as bool? ?? true;
        triggerLongSession = t['longSession'] as bool? ?? true;
        triggerAppSwitchSpike = t['appSwitchSpike'] as bool? ?? true;
        triggerRandomNudge = t['randomNudge'] as bool? ?? true;
        triggerIdleReturn = t['idleReturn'] as bool? ?? true;
        triggerFocusReminder = t['focusReminder'] as bool? ?? true;
        triggerMemoryNudge = t['memoryNudge'] as bool? ?? true;
      }
    }
    final c = json['chat'];
    if (c is Map<String, dynamic>) {
      chatAutoHideSeconds = _number(
        c['autoHideSeconds'],
        20,
      ).clamp(1, 600).toInt();
    }
    final sl = json['sleep'];
    if (sl is Map<String, dynamic>) {
      sleepEnabled = sl['enabled'] as bool? ?? true;
      sleepIdleMinutes = _number(sl['idleMinutes'], 15).clamp(1, 1440).toInt();
      adaptiveFrequency = sl['adaptiveFrequency'] as bool? ?? true;
    }
    final ai = json['ai'];
    if (ai is Map<String, dynamic>) {
      aiEnabled = ai['enabled'] as bool? ?? true;
      aiAuthMode = ai['authMode']?.toString() ?? 'openai_api_key';
      aiApiKey = ai['apiKey']?.toString() ?? '';
      aiBaseUrl = ai['baseUrl']?.toString() ?? 'https://api.openai.com/v1';
      aiModel = ai['model']?.toString() ?? 'gpt-5.6-luna';
      aiTemperature = _number(
        ai['temperature'],
        0.8,
      ).clamp(0.0, 2.0).toDouble();
      aiMaxTokens = _number(ai['maxTokens'], 800).clamp(32, 32768).toInt();
      soulFile = ai['soulFile']?.toString() ?? '';
      soulText = ai['soulText']?.toString() ?? '';
    }
    final lg = json['log'];
    if (lg is Map<String, dynamic>) {
      logEnabled = lg['enabled'] as bool? ?? true;
      logLevel = lg['level']?.toString() ?? 'INFO';
    }
    final w = json['window'];
    if (w is Map<String, dynamic>) {
      alwaysOnTop = w['alwaysOnTop'] as bool? ?? true;
      skipTaskbar = w['skipTaskbar'] as bool? ?? false;
      startVisible = w['startVisible'] as bool? ?? true;
      autoFitWindow = w['autoFitWindow'] as bool? ?? true;
    }
  }
}
