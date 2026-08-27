import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/ui/acceptance_demo.dart';

void main() {
  testWidgets('exports deterministic acceptance tour frames when requested', (
    tester,
  ) async {
    final outputPath = Platform.environment['AMADEUS_ACCEPTANCE_FRAMES_DIR'];
    if (outputPath == null || outputPath.isEmpty) return;
    const frameIndexKey = 'AMADEUS_ACCEPTANCE_FRAME_INDEX';
    final frameText = Platform.environment[frameIndexKey] ?? '';
    final frameIndex = int.tryParse(frameText) ?? 0;
    if (frameIndex < 0 || frameIndex > 6) {
      throw ArgumentError.value(frameIndex, 'frameIndex', 'must be 0–6');
    }

    final platformName = Platform.environment['AMADEUS_ACCEPTANCE_PLATFORM']
        ?.toLowerCase();
    final TargetPlatform? platform;
    if (platformName == 'windows') {
      platform = TargetPlatform.windows;
    } else if (platformName == 'macos') {
      platform = TargetPlatform.macOS;
    } else if (platformName == 'linux') {
      platform = TargetPlatform.linux;
    } else {
      platform = null;
    }
    final output = Directory(outputPath)..createSync(recursive: true);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(AcceptanceDemoApp(targetPlatform: platform));
    await tester.pumpAndSettle();

    for (var index = 0; index < frameIndex; index++) {
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 100));
    }

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(AcceptanceDemoApp.surfaceKey),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) {
      throw StateError('Could not encode acceptance frame');
    }
    final name = frameIndex.toString().padLeft(2, '0');
    final frame = File('${output.path}/frame-$name.png');
    frame.writeAsBytesSync(bytes.buffer.asUint8List());

    await tester.pumpWidget(const SizedBox());
  });
}
