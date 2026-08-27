import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/ui/acceptance_demo.dart';

void main() {
  testWidgets('acceptance demo renders real settings and cycles sections', (
    tester,
  ) async {
    await tester.pumpWidget(const AcceptanceDemoApp());
    await tester.pumpAndSettle();

    expect(find.text('Agent 概览'), findsWidgets);
    expect(find.text('Computer History'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('形象与外观'), findsWidgets);

    await tester.pumpWidget(const SizedBox());
  });
}
