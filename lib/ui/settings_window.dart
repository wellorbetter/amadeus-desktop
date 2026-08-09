import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../services/pet_config.dart';
import '../services/pet_logger.dart';
import '../services/pet_memory.dart';
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

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: dark ? const Color(0xFFB86F80) : const Color(0xFF8D4454),
          brightness: brightness,
        ).copyWith(
          surface: dark ? const Color(0xFF121116) : const Color(0xFFF9F6F7),
          surfaceContainerLowest: dark
              ? const Color(0xFF0D0C10)
              : const Color(0xFFFFFFFF),
          surfaceContainerLow: dark
              ? const Color(0xFF19171E)
              : const Color(0xFFF5EFF1),
          surfaceContainer: dark
              ? const Color(0xFF211E27)
              : const Color(0xFFF0E7EA),
          primary: dark ? const Color(0xFFE5A3B1) : const Color(0xFF8D4454),
          secondary: dark ? const Color(0xFFB8C3D9) : const Color(0xFF526079),
          outline: dark ? const Color(0xFF8F8997) : const Color(0xFF7B7377),
        );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: 'Microsoft YaHei',
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.transparent,
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow.withValues(alpha: 0.9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer.withValues(alpha: 0.82),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
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
      await windowManager.setTitle(widget.modelSetup ? 'TimePet 模型设置' : '设置');
      await windowManager.setSize(
        widget.modelSetup ? const Size(720, 760) : const Size(820, 620),
      );
      await windowManager.setMinimumSize(
        widget.modelSetup ? const Size(620, 560) : const Size(640, 480),
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
