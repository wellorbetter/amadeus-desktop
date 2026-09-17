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

  // ---- schema 版本与迁移 ----

  /// 本程序支持的配置 schema 版本。
  /// v1 = 语音/显示/隐私/本地服务分组之前的旧配置（文件里没有 configVersion 字段）。
  /// v2 = 增加 services / voice / display / privacy 分组与主动策略字段。
  static const int currentConfigVersion = 2;
  static const int legacyConfigVersion = 1;

  /// 上次读到的文件版本；文件缺少 configVersion 字段时视为 [legacyConfigVersion]。
  int _fileVersion = currentConfigVersion;
  int get fileVersion => _fileVersion;

  /// 文件版本高于本程序支持的版本。此时只读取已识别字段，并拒绝写回，
  /// 避免降级运行时用一半字段覆盖掉新版本配置。
  bool get schemaTooNew => _fileVersion > currentConfigVersion;

  /// 本次 load() 实际执行的迁移与钳制说明，供设置界面显式告知用户。
  /// 不写回文件，每次 load() 重建。
  final List<String> migrationNotes = [];

  /// 不认识的顶层键：原样保留并在 save() 时写回，
  /// 避免降级运行一次就把新版本的配置抹掉。
  final Map<String, dynamic> _unknownKeys = {};

  static const Set<String> _knownTopLevelKeys = {
    '_说明',
    'configVersion',
    'appearance',
    'proactive',
    'chat',
    'sleep',
    'ai',
    'services',
    'voice',
    'display',
    'privacy',
    'log',
    'window',
  };

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
  // 新配置默认关闭主动。「文字主动」与「主动语音」是两个独立开关，
  // 升级绝不能把已有的文字触发自动变成语音。
  bool proactiveEnabled = false; // 文字主动
  bool proactiveVoiceEnabled = false; // 主动语音（独立授权，迁移不自动授予）
  double minIntervalMinutes = 60; // 两次主动最小间隔（分钟），上限合同：不得低于 60
  int maxPerHour = 1; // 每小时最多主动次数，上限合同：不得高于 1
  int maxPerDay = 3; // 每本地日最多主动次数，上限合同：不得高于 3
  int topicsPerDay = 1; // 同一话题每日最多次数，上限合同：不得高于 1
  int dndStartHour = 23; // 勿扰起始（本地时区整点），跨午夜有效
  int dndEndHour = 8; // 勿扰结束（本地时区整点）
  int candidateExpireMinutes = 5; // 主动候选过期时间
  int presenceWindowMinutes = 10; // 判定用户在场所需的最近交互窗口
  bool triggerHourly = true; // 整点触发
  bool triggerLateNight = true; // 深夜关心（受勿扰窗口约束，不在勿扰内发声）
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
  String aiConnectionMode = 'cloud'; // cloud / local；local 表示本地无 key 端点
  String aiApiKey = '';
  String aiBaseUrl = 'https://api.openai.com/v1';
  String aiModel = 'gpt-5.6-luna';
  String soulText = '';
  String soulFile =
      ''; // 人格插件 soul.md 路径（留空自动检测 %APPDATA%/timepet/soul.md 或 exe 目录/soul.md）
  double aiTemperature = 0.8;
  int aiMaxTokens = 800; // AI 单次回复最大 token 数（防长回复截断）

  // ---- 本地服务（ownership 与端点）----
  // 默认不允许本应用启动任何进程，端点留空。迁移不自动授予。
  bool servicesManageEnabled = false; // 允许本应用启动/停止本地服务
  String llmEndpoint = ''; // 仅接受回环地址
  String llmOwnership = 'external'; // managed / external
  String asrEndpoint = '';
  String asrOwnership = 'external';
  String ttsEndpoint = '';
  String ttsOwnership = 'external';

  // ---- 语音输入输出、语言与音色 ----
  // 采集与播放默认关闭；micAuthorized 必须由用户显式引导完成，不存在缺失即授予。
  bool voiceInputEnabled = false; // 语音采集总开关
  bool micAuthorized = false; // 用户是否已完成麦克风授权引导
  bool voiceOutputEnabled = false; // TTS 播放总开关
  String inputDeviceId = ''; // 留空表示未选择，不隐式用系统默认设备收音
  String outputDeviceId = '';
  String speechLanguage = 'zh-CN'; // 中文文本配中文声音，不隐式走日文朗读
  String voiceProfile = ''; // 音色配置标识
  double outputVolume = 0.8;
  bool outputMuted = false;

  // ---- 目标显示器与小屏画布 ----
  String displayMode = 'desktop_pet'; // desktop_pet / desk_display
  String targetDisplayId = ''; // 稳定标识，不存易变的数组序号
  String targetDisplayName = ''; // 仅供用户人工辨识
  String screenOrientation = 'landscape'; // landscape 1024x600 / portrait 600x1024
  int canvasWidth = 1024;
  int canvasHeight = 600;
  double uiScale = 1.0; // 至少覆盖 1.0 与 1.5

  // ---- 隐私与留存 ----
  bool redactContentInLogs = true; // 普通日志不落记忆内容与完整 prompt
  int retentionMessages = 60; // 工作记忆保留条数
  int retentionDays = 30; // 工作记忆保留天数
  int candidateRetentionDays = 7; // 记忆候选保留天数
  int logRetentionDays = 7; // 日志保留天数

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
        'TimeTrace 桌宠动态配置。设置面板修改即时生效；外部编辑后 60 秒内自动热加载（无需重启）。configVersion 为 schema 版本，不要手改。proactive 为主动说话（文字与语音是两个独立开关，默认全关）；triggers 为各触发开关；chat 为聊天框行为；sleep 为省电休眠（空闲时停止主动对话/记忆审核，省 token）；appearance 为模型/气泡外观；ai 为对话模型；services 为本地 ASR/LLM/TTS 端点与 ownership；voice 为语音输入输出与音色；display 为目标显示器与小屏画布；privacy 为脱敏与留存策略；log 为日志；window 为窗口行为。',
    'configVersion': currentConfigVersion,
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
      'enabled': false,
      'voiceEnabled': false,
      'minIntervalMinutes': 60.0,
      'maxPerHour': 1,
      'maxPerDay': 3,
      'topicsPerDay': 1,
      'dndStartHour': 23,
      'dndEndHour': 8,
      'candidateExpireMinutes': 5,
      'presenceWindowMinutes': 10,
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
      'connectionMode': 'cloud',
      'apiKey': '',
      'baseUrl': 'https://api.openai.com/v1',
      'model': 'gpt-5.6-luna',
      'temperature': 0.8,
      'maxTokens': 800,
      'soulFile': '',
      'soulText': '',
    },
    'services': {
      'manageEnabled': false,
      'llm': {'endpoint': '', 'ownership': 'external'},
      'asr': {'endpoint': '', 'ownership': 'external'},
      'tts': {'endpoint': '', 'ownership': 'external'},
    },
    'voice': {
      'inputEnabled': false,
      'micAuthorized': false,
      'outputEnabled': false,
      'inputDeviceId': '',
      'outputDeviceId': '',
      'language': 'zh-CN',
      'voiceProfile': '',
      'outputVolume': 0.8,
      'outputMuted': false,
    },
    'display': {
      'mode': 'desktop_pet',
      'targetDisplayId': '',
      'targetDisplayName': '',
      'orientation': 'landscape',
      'canvasWidth': 1024,
      'canvasHeight': 600,
      'uiScale': 1.0,
    },
    'privacy': {
      'redactContentInLogs': true,
      'retentionMessages': 60,
      'retentionDays': 30,
      'candidateRetentionDays': 7,
      'logRetentionDays': 7,
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
      migrationNotes.clear();
      _unknownKeys.clear();
      _readVersion(json);
      for (final entry in json.entries) {
        if (!_knownTopLevelKeys.contains(entry.key)) {
          _unknownKeys[entry.key] = entry.value;
        }
      }
      if (_unknownKeys.isNotEmpty) {
        migrationNotes.add(
          '配置里有 ${_unknownKeys.length} 个本程序不认识的顶层键，已原样保留：'
          '${_unknownKeys.keys.join('、')}。',
        );
      }
      _apply(_defaults());
      _apply(json);
      _lastLoad = f.statSync().modified;
      revision.value++;
    } catch (e) {
      // 配置损坏时保持默认值
    }
  }

  /// 读版本并记录迁移说明。缺少 configVersion 字段的旧文件视为 v1。
  ///
  /// v1 -> v2 不搬运任何字段：新增分组由 `_apply(_defaults())` 填入最保守值，
  /// 旧字段由随后的 `_apply(json)` 覆盖回用户原值。这里只负责**显式告知**，
  /// 因为「静默升级」和「配置缺失即自动授予」都是不允许的。
  void _readVersion(Map<String, dynamic> json) {
    final raw = json['configVersion'];
    _fileVersion = raw is num ? raw.toInt() : legacyConfigVersion;
    if (_fileVersion > currentConfigVersion) {
      migrationNotes.add(
        '配置文件版本 v$_fileVersion 高于本程序支持的 v$currentConfigVersion：'
        '只读取已识别字段，且拒绝写回，避免用旧字段覆盖新版本配置。'
        '请用新版本程序修改设置。',
      );
      return;
    }
    if (_fileVersion < currentConfigVersion) {
      migrationNotes.add(
        '配置已从 v$_fileVersion 升级到 v$currentConfigVersion：'
        '新增语音采集、主动语音、本地服务管理、目标显示器与留存策略设置，'
        '全部保持关闭或留空，需要你在设置里逐项开启。'
        '原有连接、模型路径、人设、外观与文字主动设置未改动。',
      );
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
  ///
  /// 文件版本高于本程序支持的版本时**拒绝写入**并返回 false：
  /// 降级运行只写自己认识的字段，会静默丢掉新版本的配置。
  bool save() {
    if (schemaTooNew) return false;
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
    'configVersion': currentConfigVersion,
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
      'voiceEnabled': proactiveVoiceEnabled,
      'minIntervalMinutes': minIntervalMinutes,
      'maxPerHour': maxPerHour,
      'maxPerDay': maxPerDay,
      'topicsPerDay': topicsPerDay,
      'dndStartHour': dndStartHour,
      'dndEndHour': dndEndHour,
      'candidateExpireMinutes': candidateExpireMinutes,
      'presenceWindowMinutes': presenceWindowMinutes,
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
      'connectionMode': aiConnectionMode,
      'apiKey': aiApiKey,
      'baseUrl': aiBaseUrl,
      'model': aiModel,
      'temperature': aiTemperature,
      'maxTokens': aiMaxTokens,
      'soulFile': soulFile,
      'soulText': soulText,
    },
    'services': {
      'manageEnabled': servicesManageEnabled,
      'llm': {'endpoint': llmEndpoint, 'ownership': llmOwnership},
      'asr': {'endpoint': asrEndpoint, 'ownership': asrOwnership},
      'tts': {'endpoint': ttsEndpoint, 'ownership': ttsOwnership},
    },
    'voice': {
      'inputEnabled': voiceInputEnabled,
      'micAuthorized': micAuthorized,
      'outputEnabled': voiceOutputEnabled,
      'inputDeviceId': inputDeviceId,
      'outputDeviceId': outputDeviceId,
      'language': speechLanguage,
      'voiceProfile': voiceProfile,
      'outputVolume': outputVolume,
      'outputMuted': outputMuted,
    },
    'display': {
      'mode': displayMode,
      'targetDisplayId': targetDisplayId,
      'targetDisplayName': targetDisplayName,
      'orientation': screenOrientation,
      'canvasWidth': canvasWidth,
      'canvasHeight': canvasHeight,
      'uiScale': uiScale,
    },
    'privacy': {
      'redactContentInLogs': redactContentInLogs,
      'retentionMessages': retentionMessages,
      'retentionDays': retentionDays,
      'candidateRetentionDays': candidateRetentionDays,
      'logRetentionDays': logRetentionDays,
    },
    'log': {'enabled': logEnabled, 'level': logLevel},
    'window': {
      'alwaysOnTop': alwaysOnTop,
      'skipTaskbar': skipTaskbar,
      'startVisible': startVisible,
      'autoFitWindow': autoFitWindow,
    },
    // 不认识的顶层键原样回写，放在最后避免覆盖已知分组。
    ..._unknownKeys,
  };

  num _number(Object? value, num fallback) => value is num ? value : fallback;

  /// 枚举字段：不认识的值退回默认，不接受任意字符串。
  String _oneOf(Object? value, Set<String> allowed, String fallback) {
    final s = value?.toString();
    return s != null && allowed.contains(s) ? s : fallback;
  }

  /// ownership 只有两种。未知值退回 external —— 更保守：不代表本应用有权启停它。
  String _ownership(Object? value) =>
      _oneOf(value, const {'managed', 'external'}, 'external');

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
      proactiveEnabled = p['enabled'] as bool? ?? false;
      // 主动语音必须显式授予。旧配置没有这个键，绝不能因为文字主动开着就跟着开。
      proactiveVoiceEnabled = p['voiceEnabled'] as bool? ?? false;
      // 频率是上限合同：最小间隔不低于 60 分钟、每小时不超过 1 次、每日不超过 3 次、
      // 同一话题每日不超过 1 次。用户可以更保守，不能更激进。
      final rawInterval = _number(p['minIntervalMinutes'], 60);
      minIntervalMinutes = rawInterval.clamp(60.0, 1440.0).toDouble();
      final rawPerHour = _number(p['maxPerHour'], 1);
      maxPerHour = rawPerHour.clamp(0, 1).toInt();
      final rawPerDay = _number(p['maxPerDay'], 3);
      maxPerDay = rawPerDay.clamp(0, 3).toInt();
      topicsPerDay = _number(p['topicsPerDay'], 1).clamp(0, 1).toInt();
      if (rawInterval < 60 || rawPerHour > 1 || rawPerDay > 3) {
        migrationNotes.add(
          '主动频率已按上限合同收紧：最小间隔 '
          '${rawInterval.toStringAsFixed(0)} -> ${minIntervalMinutes.toStringAsFixed(0)} 分钟，'
          '每小时 $rawPerHour -> $maxPerHour 次，每日上限 $maxPerDay 次。',
        );
      }
      dndStartHour = _number(p['dndStartHour'], 23).clamp(0, 23).toInt();
      dndEndHour = _number(p['dndEndHour'], 8).clamp(0, 23).toInt();
      candidateExpireMinutes = _number(
        p['candidateExpireMinutes'],
        5,
      ).clamp(1, 60).toInt();
      presenceWindowMinutes = _number(
        p['presenceWindowMinutes'],
        10,
      ).clamp(1, 120).toInt();
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
      aiConnectionMode = _oneOf(ai['connectionMode'], const {
        'cloud',
        'local',
      }, 'cloud');
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
    final sv = json['services'];
    if (sv is Map<String, dynamic>) {
      servicesManageEnabled = sv['manageEnabled'] as bool? ?? false;
      final llm = sv['llm'];
      if (llm is Map<String, dynamic>) {
        llmEndpoint = llm['endpoint']?.toString() ?? '';
        llmOwnership = _ownership(llm['ownership']);
      }
      final asr = sv['asr'];
      if (asr is Map<String, dynamic>) {
        asrEndpoint = asr['endpoint']?.toString() ?? '';
        asrOwnership = _ownership(asr['ownership']);
      }
      final tts = sv['tts'];
      if (tts is Map<String, dynamic>) {
        ttsEndpoint = tts['endpoint']?.toString() ?? '';
        ttsOwnership = _ownership(tts['ownership']);
      }
    }
    final vo = json['voice'];
    if (vo is Map<String, dynamic>) {
      voiceInputEnabled = vo['inputEnabled'] as bool? ?? false;
      micAuthorized = vo['micAuthorized'] as bool? ?? false;
      voiceOutputEnabled = vo['outputEnabled'] as bool? ?? false;
      inputDeviceId = vo['inputDeviceId']?.toString() ?? '';
      outputDeviceId = vo['outputDeviceId']?.toString() ?? '';
      speechLanguage = vo['language']?.toString() ?? 'zh-CN';
      voiceProfile = vo['voiceProfile']?.toString() ?? '';
      outputVolume = _number(vo['outputVolume'], 0.8).clamp(0.0, 1.0).toDouble();
      outputMuted = vo['outputMuted'] as bool? ?? false;
    }
    final dp = json['display'];
    if (dp is Map<String, dynamic>) {
      displayMode = _oneOf(dp['mode'], const {
        'desktop_pet',
        'desk_display',
      }, 'desktop_pet');
      targetDisplayId = dp['targetDisplayId']?.toString() ?? '';
      targetDisplayName = dp['targetDisplayName']?.toString() ?? '';
      screenOrientation = _oneOf(dp['orientation'], const {
        'landscape',
        'portrait',
      }, 'landscape');
      canvasWidth = _number(dp['canvasWidth'], 1024).clamp(320, 4096).toInt();
      canvasHeight = _number(dp['canvasHeight'], 600).clamp(240, 4096).toInt();
      uiScale = _number(dp['uiScale'], 1.0).clamp(1.0, 3.0).toDouble();
    }
    final pv = json['privacy'];
    if (pv is Map<String, dynamic>) {
      redactContentInLogs = pv['redactContentInLogs'] as bool? ?? true;
      retentionMessages = _number(
        pv['retentionMessages'],
        60,
      ).clamp(1, 10000).toInt();
      retentionDays = _number(pv['retentionDays'], 30).clamp(1, 3650).toInt();
      candidateRetentionDays = _number(
        pv['candidateRetentionDays'],
        7,
      ).clamp(1, 365).toInt();
      logRetentionDays = _number(
        pv['logRetentionDays'],
        7,
      ).clamp(1, 365).toInt();
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
