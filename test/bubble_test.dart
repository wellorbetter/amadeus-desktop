import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/ui/bubble.dart';

void main() {
  testWidgets('long streaming reply stays mounted and exposes scrolling', (
    tester,
  ) async {
    final text = List.filled(200, 'Amadeus').join();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: PetBubble(text: 'placeholder', visible: true, typing: true),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PetBubble(text: text, visible: true, typing: true),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(PetBubble), findsOneWidget);
    expect(find.byType(Scrollbar), findsOneWidget);
    expect(find.text(text), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
