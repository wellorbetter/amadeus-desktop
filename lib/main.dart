import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;

import 'app.dart';
import 'services/pet_config.dart';
import 'services/pet_logger.dart';
import 'services/pet_secret_store.dart';
import 'services/pet_window.dart';
import 'ui/settings_window.dart';
import 'ui/acceptance_demo.dart';

void main(List<String> args) async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        PetLog.e('FlutterError: ${details.exception}\n${details.stack}');
      };
      PetLog.i('main: boot');

      final acceptanceDemo =
          args.contains('--acceptance-demo') ||
          Platform.environment['AMADEUS_ACCEPTANCE_DEMO'] == '1';
      if (acceptanceDemo) {
        PetLog.i('main: isolated acceptance demo');
        runApp(const AcceptanceDemoApp());
        return;
      }

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

      PetConfig.instance.load();
      await PetSecretStore.instance.hydrate(PetConfig.instance);

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

      runApp(const AmadeusApp());
    },
    (error, stack) {
      PetLog.e('zone error: $error\n$stack');
    },
  );
}
