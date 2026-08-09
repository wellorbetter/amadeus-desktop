import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;

import 'app.dart';
import 'services/pet_logger.dart';
import 'services/pet_window.dart';
import 'ui/settings_window.dart';

void main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        PetLog.e('FlutterError: ${details.exception}\n${details.stack}');
      };
      PetLog.i('main: boot');

      // 区分主窗口（桌宠）与独立设置窗口
      String windowId = '';
      String windowArgs = '';
      try {
        final ctrl = await WindowController.fromCurrentEngine();
        windowId = ctrl.windowId;
        windowArgs = ctrl.arguments;
      } catch (e) {
        PetLog.i('main: multiWindow query skipped: $e');
      }
      PetLog.i('main: windowId=$windowId args=$windowArgs');

      if (windowArgs.contains('settings')) {
        // 设置窗口：普通不透明大窗口，独立运行
        runApp(
          SettingsWindowApp(modelSetup: windowArgs.contains('model-setup')),
        );
        return;
      }

      // 桌宠窗口：透明 + 托盘 + 右下角贴合
      await acrylic.Window.initialize();
      await acrylic.Window.setEffect(effect: acrylic.WindowEffect.disabled);
      PetLog.i('main: acrylic ready');

      await PetWindow.setup();
      PetLog.i('main: PetWindow.setup done');

      runApp(const KurisuPetApp());
    },
    (error, stack) {
      PetLog.e('zone error: $error\n$stack');
    },
  );
}
