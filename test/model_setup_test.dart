import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timepet/ui/model_setup_page.dart';

void main() {
  testWidgets('model setup explains import requirements', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ModelSetupPage()));

    expect(find.text('让时间记录，变成一次有分寸的陪伴。'), findsOneWidget);
    expect(find.text('感知，但不监视'), findsOneWidget);
    await tester.tap(find.text('了解数据边界'));
    await tester.pumpAndSettle();
    expect(find.text('你控制形象、人格、数据与模型服务。'), findsOneWidget);
    await tester.tap(find.text('选择本地形象'));
    await tester.pumpAndSettle();
    expect(find.text('选择模型包'), findsOneWidget);
    expect(find.text('导入并使用'), findsOneWidget);
    expect(find.textContaining('我确认有权在本机使用'), findsOneWidget);
  });
}
