import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timepet/ui/model_setup_page.dart';

void main() {
  testWidgets('model setup explains import requirements', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ModelSetupPage()));

    expect(find.text('先让她来到桌面上'), findsOneWidget);
    expect(find.text('选择模型包'), findsOneWidget);
    expect(find.text('导入并使用'), findsOneWidget);
    expect(find.textContaining('完整模型包'), findsOneWidget);
  });
}
