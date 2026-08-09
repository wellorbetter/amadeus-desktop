import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timepet/services/pet_config.dart';
import 'package:timepet/ui/settings_panel.dart';

void main() {
  testWidgets('conversation connection opens a secondary setup page', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('timepet-settings-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final config = PetConfig(pathOverride: '${dir.path}/config.json');
    await tester.pumpWidget(MaterialApp(home: SettingsPage(config: config)));
    await tester.tap(find.text('系统'));
    await tester.pumpAndSettle();
    expect(find.text('对话接入方式'), findsOneWidget);
    expect(find.text('Conversation connection'), findsNothing);

    await tester.tap(find.text('对话接入方式'));
    await tester.pumpAndSettle();

    expect(find.text('对话接入方式'), findsOneWidget);
    expect(find.text('OpenAI API Key'), findsOneWidget);
    expect(find.text('API Key'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('setting descriptions use progressive disclosure', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('timepet-settings-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final config = PetConfig(pathOverride: '${dir.path}/config.json');
    await tester.pumpWidget(MaterialApp(home: SettingsPage(config: config)));

    await tester.tap(find.text('对话'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.help_outline_rounded), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
}
