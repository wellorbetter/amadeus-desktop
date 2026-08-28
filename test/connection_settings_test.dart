import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timepet/services/pet_config.dart';
import 'package:timepet/services/activity_history.dart';
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

    expect(find.text('Agent Runtime'), findsOneWidget);
    expect(find.text('Computer History'), findsOneWidget);
    expect(find.text('Skill · MCP · Evolve'), findsOneWidget);
    await tester.tap(find.text('记忆与隐私'));
    await tester.pumpAndSettle();
    expect(find.text('数据边界'), findsOneWidget);
    expect(find.text('本地记忆'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('trigger settings expose lanes and orchestration policy', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('timepet-trigger-ui-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final config = PetConfig(pathOverride: '${dir.path}/config.json');
    await tester.pumpWidget(MaterialApp(home: SettingsPage(config: config)));

    await tester.tap(find.text('主动性'));
    await tester.pumpAndSettle();

    expect(find.text('健康关心'), findsOneWidget);
    expect(find.text('状态转场'), findsOneWidget);
    expect(find.text('关系与轻互动'), findsOneWidget);
    expect(find.text('编排规则'), findsOneWidget);
    expect(find.text('安静时段'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('activity workspace exposes stream state and source controls', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('amadeus-activity-ui-');
    final config = PetConfig(pathOverride: '${dir.path}/config.json');
    final history = ActivityHistory(pathOverride: '${dir.path}/activity.db');
    final now = DateTime.now();
    final started = DateTime(now.year, now.month, now.day, 9);
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Android Studio',
        appId: 'com.google.android.studio',
        idleSeconds: 0,
        capturedAt: started,
      ),
    );
    history.recordSnapshot(
      ActivitySnapshot(
        appName: 'Android Studio',
        appId: 'com.google.android.studio',
        idleSeconds: 0,
        capturedAt: started.add(const Duration(minutes: 2)),
      ),
    );
    addTearDown(() {
      history.close();
      dir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(config: config, activityHistory: history),
      ),
    );
    await tester.tap(find.text('活动工作台'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Rust Core v1'), findsOneWidget);
    expect(find.text('事件管线'), findsOneWidget);
    expect(find.text('采集与保留'), findsOneWidget);
    expect(find.text('排除应用'), findsOneWidget);
    expect(find.text('7 天'), findsOneWidget);
    expect(find.text('30 天'), findsOneWidget);

    final episode = find.byKey(const ValueKey('activity-episode-1'));
    await tester.ensureVisible(episode);
    await tester.pumpAndSettle();
    await tester.tap(episode);
    await tester.pumpAndSettle();
    expect(find.text('活动片段详情'), findsOneWidget);
    expect(find.textContaining('没有窗口标题或输入内容'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
