import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/pet_config.dart';

void main() {
  test('config reset restores every shipped default and persists it', () {
    final dir = Directory.systemTemp.createTempSync('timepet-config-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cfg = PetConfig(pathOverride: '${dir.path}/config.json');

    cfg.load();
    cfg.modelScale = 1.8;
    cfg.settingsOpacity = 0.8;
    cfg.aiBaseUrl = 'https://example.invalid/v1';
    cfg.aiModel = 'broken-model';
    cfg.modelPath = 'C:/old/model.json';
    cfg.timeTraceEnabled = false;
    cfg.save();
    cfg.resetToDefaults();

    expect(cfg.modelScale, 1.0);
    expect(cfg.settingsOpacity, 0.96);
    expect(cfg.aiBaseUrl, 'https://api.openai.com/v1');
    expect(cfg.aiModel, 'gpt-5.6-luna');
    expect(cfg.modelPath, isEmpty);
    expect(cfg.soulText, isEmpty);
    expect(cfg.timeTraceEnabled, isTrue);

    final reloaded = PetConfig(pathOverride: '${dir.path}/config.json')..load();
    expect(reloaded.aiBaseUrl, 'https://api.openai.com/v1');
    expect(reloaded.aiModel, 'gpt-5.6-luna');
    expect(reloaded.modelPath, isEmpty);
    expect(reloaded.settingsOpacity, 0.96);
  });

  test('invalid numeric settings are clamped instead of poisoning layout', () {
    final dir = Directory.systemTemp.createTempSync('timepet-config-invalid-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/config.json');
    file.writeAsStringSync('''{
      "appearance": {"modelScale": -100, "modelOpacity": 99, "bubbleAutoHideSeconds": -1, "settingsOpacity": 0.1},
      "ai": {"temperature": 99, "maxTokens": 0}
    }''');
    final cfg = PetConfig(pathOverride: file.path)..load();

    expect(cfg.modelScale, 0.1);
    expect(cfg.modelOpacity, 1.0);
    expect(cfg.bubbleAutoHideSeconds, 1);
    expect(cfg.settingsOpacity, 0.75);
    expect(cfg.aiTemperature, 2.0);
    expect(cfg.aiMaxTokens, 32);
  });
}
