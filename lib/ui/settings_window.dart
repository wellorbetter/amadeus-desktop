import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../services/pet_config.dart';
import '../services/pet_logger.dart';
import '../services/pet_memory.dart';
import 'amadeus_theme.dart';
import 'settings_panel.dart';
import 'model_setup_page.dart';

/// 独立设置窗口（大窗口）：桌宠托盘「设置」打开。
/// 通过 desktop_multi_window 在子引擎中运行，配置写入共享 config.json，
/// 再通过 WindowMethodChannel('pet') 通知桌宠窗口热生效。
/// 深浅主题跟随配置 appearance.darkMode，切换即时生效。
class SettingsWindowApp extends StatefulWidget {
  const SettingsWindowApp({super.key, this.modelSetup = false});

  final bool modelSetup;

  @override
  State<SettingsWindowApp> createState() => _SettingsWindowAppState();
}

class _SettingsWindowAppState extends State<SettingsWindowApp> {
  @override
  void initState() {
    super.initState();
    PetConfig.instance.load();
    PetMemory.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: PetConfig.instance.revision,
      builder: (context, _, _) {
        final dark = PetConfig.instance.darkMode;
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: '设置',
          theme: AmadeusTheme.light(),
          darkTheme: AmadeusTheme.dark(),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: SettingsWindowPage(modelSetup: widget.modelSetup),
        );
      },
    );
  }
}

class SettingsWindowPage extends StatefulWidget {
  const SettingsWindowPage({super.key, this.modelSetup = false});

  final bool modelSetup;

  @override
  State<SettingsWindowPage> createState() => _SettingsWindowPageState();
}

class _SettingsWindowPageState extends State<SettingsWindowPage> {
  @override
  void initState() {
    super.initState();
    _setupWindow();
  }

  Future<void> _setupWindow() async {
    try {
      await windowManager.ensureInitialized();
      await windowManager.setOpacity(PetConfig.instance.settingsOpacity);
      final controller = await WindowController.fromCurrentEngine();
      await controller.setWindowMethodHandler((call) async {
        if (call.method == 'focus') {
          await windowManager.show();
          await windowManager.focus();
        }
      });
      await windowManager.setTitle(
        widget.modelSetup ? '欢迎使用 Amadeus' : 'Amadeus 设置',
      );
      await windowManager.setSize(
        widget.modelSetup ? const Size(900, 720) : const Size(980, 700),
      );
      await windowManager.setMinimumSize(
        widget.modelSetup ? const Size(760, 620) : const Size(760, 560),
      );
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();
      PetLog.i('settings: window ready');
    } catch (e) {
      PetLog.e('settings: window setup error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.modelSetup ? const ModelSetupPage() : const SettingsPage();
  }
}
