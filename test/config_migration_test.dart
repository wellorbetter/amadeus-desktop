import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/pet_config.dart';

/// U1 自检：配置版本与迁移骨架。
/// 对应 Spec §12「新增配置须带版本号」「不存在配置缺失即自动授予的迁移」，
/// 以及 §10「文字主动与主动语音是两个独立开关」「频率是上限」。
void main() {
  Directory tempDir() {
    final dir = Directory.systemTemp.createTempSync('timepet-migrate-');
    addTearDown(() => dir.deleteSync(recursive: true));
    return dir;
  }

  /// 一份真实形状的 v1 配置：没有 configVersion，没有 services/voice/display/privacy，
  /// 且带着旧的默认主动频率（20 分钟 / 每小时 2 次）。
  Map<String, dynamic> v1Config() => {
    '_说明': '旧版本写下的说明',
    'appearance': {
      'modelScale': 1.4,
      'displayWidth': 500,
      'modelPath': 'C:/models/kurisu/kurisu.model3.json',
      'soundEnabled': true,
      'bubbleFontSize': 16.0,
    },
    'proactive': {
      'enabled': true,
      'minIntervalMinutes': 20.0,
      'maxPerHour': 2,
      'longSessionMinutes': 90,
      'triggers': {'hourly': true, 'lateNight': true, 'randomNudge': false},
    },
    'chat': {'autoHideSeconds': 45},
    'sleep': {'enabled': true, 'idleMinutes': 25, 'adaptiveFrequency': false},
    'ai': {
      'enabled': true,
      'authMode': 'deepseek_api_key',
      'apiKey': 'sk-old-user-key',
      'baseUrl': 'https://api.deepseek.com/v1',
      'model': 'deepseek-chat',
      'temperature': 1.1,
      'maxTokens': 1200,
      'soulText': '我是牧濑红莉栖。',
    },
    'log': {'enabled': true, 'level': 'WARN'},
    'window': {'alwaysOnTop': false, 'autoFitWindow': false},
  };

  PetConfig loadFrom(Directory dir, Map<String, dynamic> json) {
    final file = File('${dir.path}/config.json');
    file.writeAsStringSync(jsonEncode(json));
    return PetConfig(pathOverride: file.path)..load();
  }

  group('缺失文件', () {
    test('首次启动写出带版本号的配置，且所有新权限默认关闭', () {
      final dir = tempDir();
      final cfg = PetConfig(pathOverride: '${dir.path}/config.json')..load();

      expect(cfg.fileVersion, PetConfig.currentConfigVersion);
      expect(cfg.schemaTooNew, isFalse);
      expect(cfg.migrationNotes, isEmpty, reason: '新装不该报迁移');

      // 主动默认全关，语音与本地服务管理默认全关。
      expect(cfg.proactiveEnabled, isFalse);
      expect(cfg.proactiveVoiceEnabled, isFalse);
      expect(cfg.voiceInputEnabled, isFalse);
      expect(cfg.micAuthorized, isFalse);
      expect(cfg.voiceOutputEnabled, isFalse);
      expect(cfg.servicesManageEnabled, isFalse);
      expect(cfg.llmOwnership, 'external');
      expect(cfg.asrOwnership, 'external');
      expect(cfg.ttsOwnership, 'external');
      expect(cfg.llmEndpoint, isEmpty);
      expect(cfg.inputDeviceId, isEmpty, reason: '不隐式用系统默认设备收音');
      expect(cfg.displayMode, 'desktop_pet');
      expect(cfg.targetDisplayId, isEmpty);
      expect(cfg.redactContentInLogs, isTrue);

      // 频率默认即为上限合同值。
      expect(cfg.minIntervalMinutes, 60);
      expect(cfg.maxPerHour, 1);
      expect(cfg.maxPerDay, 3);
      expect(cfg.topicsPerDay, 1);
      expect(cfg.dndStartHour, 23);
      expect(cfg.dndEndHour, 8);

      // 落盘的文件本身带版本号。
      final onDisk =
          jsonDecode(File('${dir.path}/config.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(onDisk['configVersion'], PetConfig.currentConfigVersion);
    });
  });

  group('v1 旧文件', () {
    test('既有连接、模型路径、人设、外观与文字主动设置全部保留', () {
      final cfg = loadFrom(tempDir(), v1Config());

      expect(cfg.fileVersion, PetConfig.legacyConfigVersion);

      // 连接与人设
      expect(cfg.aiAuthMode, 'deepseek_api_key');
      expect(cfg.aiApiKey, 'sk-old-user-key');
      expect(cfg.aiBaseUrl, 'https://api.deepseek.com/v1');
      expect(cfg.aiModel, 'deepseek-chat');
      expect(cfg.aiTemperature, 1.1);
      expect(cfg.aiMaxTokens, 1200);
      expect(cfg.soulText, '我是牧濑红莉栖。');
      // 外观与模型路径
      expect(cfg.modelScale, 1.4);
      expect(cfg.displayWidth, 500);
      expect(cfg.modelPath, 'C:/models/kurisu/kurisu.model3.json');
      expect(cfg.soundEnabled, isTrue);
      expect(cfg.bubbleFontSize, 16.0);
      // 文字主动开关不被静默重置
      expect(cfg.proactiveEnabled, isTrue);
      expect(cfg.triggerRandomNudge, isFalse);
      expect(cfg.longSessionMinutes, 90);
      // 其余既有分组
      expect(cfg.chatAutoHideSeconds, 45);
      expect(cfg.sleepIdleMinutes, 25);
      expect(cfg.adaptiveFrequency, isFalse);
      expect(cfg.logLevel, 'WARN');
      expect(cfg.alwaysOnTop, isFalse);
      expect(cfg.autoFitWindow, isFalse);
    });

    test('文字主动开着也不会把主动语音、麦克风或服务管理一起打开', () {
      final cfg = loadFrom(tempDir(), v1Config());

      expect(cfg.proactiveEnabled, isTrue, reason: '前提：旧配置的文字主动是开的');
      expect(cfg.proactiveVoiceEnabled, isFalse);
      expect(cfg.voiceInputEnabled, isFalse);
      expect(cfg.micAuthorized, isFalse);
      expect(cfg.voiceOutputEnabled, isFalse);
      expect(cfg.servicesManageEnabled, isFalse);
      expect(cfg.aiConnectionMode, 'cloud', reason: '不因为新增本地支持就改连接模式');
    });

    test('迁移不是静默的：升级与频率收紧都有显式说明', () {
      final cfg = loadFrom(tempDir(), v1Config());

      expect(cfg.migrationNotes, isNotEmpty);
      expect(cfg.migrationNotes.join('\n'), contains('v1'));
      expect(cfg.migrationNotes.join('\n'), contains('主动频率'));
    });

    test('旧配置的激进频率被收紧到上限合同', () {
      final cfg = loadFrom(tempDir(), v1Config());

      expect(cfg.minIntervalMinutes, 60, reason: '旧值 20 分钟低于最小间隔上限合同');
      expect(cfg.maxPerHour, 1, reason: '旧值每小时 2 次超过上限');
      expect(cfg.maxPerDay, 3);
    });

    test('迁移后保存一次，文件带上版本号且旧值不变', () {
      final dir = tempDir();
      final cfg = loadFrom(dir, v1Config());
      expect(cfg.save(), isTrue);

      final reloaded = PetConfig(pathOverride: '${dir.path}/config.json')
        ..load();
      expect(reloaded.fileVersion, PetConfig.currentConfigVersion);
      expect(reloaded.migrationNotes, isEmpty, reason: '已升级过就不该再报迁移');
      expect(reloaded.aiApiKey, 'sk-old-user-key');
      expect(reloaded.modelPath, 'C:/models/kurisu/kurisu.model3.json');
      expect(reloaded.proactiveEnabled, isTrue);
      expect(reloaded.proactiveVoiceEnabled, isFalse);
    });
  });

  group('损坏与降级', () {
    test('损坏 JSON 不清空用户配置，也不写坏文件', () {
      final dir = tempDir();
      final file = File('${dir.path}/config.json');
      file.writeAsStringSync(jsonEncode(v1Config()));
      final cfg = PetConfig(pathOverride: file.path)..load();
      expect(cfg.aiApiKey, 'sk-old-user-key');

      // 外部编辑把文件写坏后热加载
      file.writeAsStringSync('{ "ai": { "apiKey": "sk-broken"');
      cfg.load();

      expect(cfg.aiApiKey, 'sk-old-user-key', reason: '损坏时保持上一次成功加载的值');
      expect(file.readAsStringSync(), startsWith('{ "ai"'), reason: '不覆盖用户文件');
    });

    test('文件版本高于程序支持版本时只读不写', () {
      final dir = tempDir();
      final future = v1Config()
        ..['configVersion'] = PetConfig.currentConfigVersion + 5
        ..['someFutureGroup'] = {'x': 1};
      final file = File('${dir.path}/config.json');
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(future),
      );
      final before = file.readAsStringSync();

      final cfg = PetConfig(pathOverride: file.path)..load();
      expect(cfg.schemaTooNew, isTrue);
      expect(cfg.aiApiKey, 'sk-old-user-key', reason: '已识别字段仍然读出来');
      expect(cfg.migrationNotes.join('\n'), contains('拒绝写回'));

      expect(cfg.save(), isFalse);
      expect(file.readAsStringSync(), before, reason: '一个字节都不许改');
    });

    test('不认识的顶层键在保存后仍然存在', () {
      final dir = tempDir();
      final withExtra = v1Config()..['futureVoiceCloning'] = {'enabled': true};
      final cfg = loadFrom(dir, withExtra);

      expect(cfg.migrationNotes.join('\n'), contains('futureVoiceCloning'));
      expect(cfg.save(), isTrue);

      final onDisk =
          jsonDecode(File('${dir.path}/config.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(onDisk['futureVoiceCloning'], {'enabled': true});
      expect(onDisk['configVersion'], PetConfig.currentConfigVersion);
    });

    test('枚举字段收到垃圾值时退回最保守的默认', () {
      final dir = tempDir();
      final junk = v1Config()
        ..['services'] = {
          'manageEnabled': true,
          'llm': {'endpoint': 'http://127.0.0.1:8080/v1', 'ownership': 'root'},
        }
        ..['display'] = {'mode': 'fullscreen_kiosk', 'orientation': 'diagonal'}
        ..['ai'] = {...v1Config()['ai']! as Map, 'connectionMode': 'satellite'};
      final cfg = loadFrom(dir, junk);

      expect(cfg.llmOwnership, 'external', reason: '未知 ownership 不代表本应用有权启停');
      expect(cfg.displayMode, 'desktop_pet');
      expect(cfg.screenOrientation, 'landscape');
      expect(cfg.aiConnectionMode, 'cloud');
      // 显式写 true 的开关仍然生效，只有不认识的枚举值被退回。
      expect(cfg.servicesManageEnabled, isTrue);
      expect(cfg.llmEndpoint, 'http://127.0.0.1:8080/v1');
    });
  });
}
