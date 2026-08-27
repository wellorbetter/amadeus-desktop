import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timepet/services/pet_config.dart';
import 'package:timepet/ui/settings_panel.dart';

void main() {
  testWidgets('conversation connection is explicit and local-first', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('timepet-settings-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final config = PetConfig(pathOverride: '${dir.path}/config.json');
    await tester.pumpWidget(MaterialApp(home: SettingsPage(config: config)));
    await tester.tap(find.text('能力与人格'));
    await tester.pumpAndSettle();
    expect(find.text('对话服务'), findsOneWidget);
    expect(find.text('OpenAI API Key'), findsOneWidget);
    expect(find.text('API Key'), findsOneWidget);
    expect(find.textContaining('订阅登录不能直接'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('agent capabilities keep observation separate from memory', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('timepet-settings-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final config = PetConfig(pathOverride: '${dir.path}/config.json');
    await tester.pumpWidget(MaterialApp(home: SettingsPage(config: config)));

    expect(find.text('Amadeus 桌面端'), findsOneWidget);
    expect(find.text('内置活动感知'), findsOneWidget);
    await tester.tap(find.text('记忆与隐私'));
    await tester.pumpAndSettle();
    expect(find.text('数据边界'), findsOneWidget);
    expect(find.text('本地记忆'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
