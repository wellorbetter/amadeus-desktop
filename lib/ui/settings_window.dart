import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../services/pet_config.dart';
import '../services/pet_logger.dart';
import '../services/pet_memory.dart';
import 'settings_panel.dart';

/// 独立设置窗口（大窗口）：桌宠托盘「设置」打开。
/// 通过 desktop_multi_window 在子引擎中运行，配置写入共享 config.json，
/// 再通过 WindowMethodChannel('pet') 通知桌宠窗口热生效。
/// 深浅主题跟随配置 appearance.darkMode，切换即时生效。
class SettingsWindowApp extends StatefulWidget {
  const SettingsWindowApp({super.key});

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

  ThemeData _theme(Brightness brightness) {
    return ThemeData(
      brightness: brightness,
      fontFamily: 'Microsoft YaHei',
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF7C8CFF),
        brightness: brightness,
      ),
    );
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
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: const SettingsWindowPage(),
        );
      },
    );
  }
}

class SettingsWindowPage extends StatefulWidget {
  const SettingsWindowPage({super.key});

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
      await windowManager.setTitle('设置');
      await windowManager.setSize(const Size(820, 620));
      await windowManager.setMinimumSize(const Size(640, 480));
      await windowManager.center();
      await windowManager.show();
      PetLog.i('settings: window ready');
    } catch (e) {
      PetLog.e('settings: window setup error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return const SettingsPage();
  }
}
