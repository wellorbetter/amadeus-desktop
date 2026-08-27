import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'pet_config.dart';
import 'pet_logger.dart';

/// 桌宠窗口：无边框、透明、置顶、固定尺寸、关闭时隐藏到托盘。
class PetWindow {
  static const Size petSize = Size(460, 640);

  /// 托盘「聊两句」等入口请求弹出聊天框时回调。
  static void Function()? onShowChat;

  /// 托盘「设置」入口请求打开设置面板时回调。
  static void Function()? onOpenSettings;

  static final _winListener = _CloseToTrayListener();
  static final _trayListener = _TrayHandler();
  static bool _trayReady = false;

  static Future<void> setup() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(_winListener);

    const opts = WindowOptions(
      size: petSize,
      center: false,
      alwaysOnTop: true,
      backgroundColor: Colors.transparent,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
      skipTaskbar: true,
    );

    windowManager.waitUntilReadyToShow(opts, () async {
      if (PetConfig.instance.startVisible) {
        await placeBottomRight();
        await windowManager.show();
        try {
          final pos = await windowManager.getPosition();
          final size = await windowManager.getSize();
          PetLog.i('window: shown pos=$pos size=$size');
        } catch (_) {}
      } else {
        PetLog.i('window: start hidden (startVisible=false)');
      }
    });

    await windowManager.setPreventClose(true);
    await windowManager.setAlwaysOnTop(PetConfig.instance.alwaysOnTop);
    await windowManager.setResizable(false);
    await windowManager.setMinimizable(false);
    await windowManager.setMaximizable(false);
    try {
      // The pet is a transparent utility window; only the settings window
      // should be discoverable from the taskbar.
      await windowManager.setSkipTaskbar(true);
    } catch (_) {}

    await setupTray();
  }

  /// 打开独立设置窗口（不存在则创建，已存在则前置显示）。
  static Future<void> openSettingsWindow({bool modelSetup = false}) async {
    try {
      final windows = await WindowController.getAll();
      for (final w in windows) {
        final isModelSetup = w.arguments.contains('model-setup');
        if (w.arguments.contains('settings') && isModelSetup == modelSetup) {
          PetLog.i('settings: reuse window id=${w.windowId}');
          await w.show();
          try {
            await w.invokeMethod('focus');
          } catch (_) {}
          return;
        }
      }
      final c = await WindowController.create(
        WindowConfiguration(
          arguments: modelSetup ? 'settings model-setup' : 'settings',
          hiddenAtLaunch: true,
        ),
      );
      PetLog.i('settings: created window id=${c.windowId}');
      // 子窗口引擎启动后由设置页负责定位/显示；这里延迟兜底显示一次。
      // 兜底必须晚于设置页的 setSize+center（约 1s），否则窗口会先出现在默认位置再居中（抖动）。
      await Future.delayed(const Duration(milliseconds: 2500));
      try {
        await c.show();
      } catch (_) {}
    } catch (e) {
      PetLog.e('settings: open window error: $e');
    }
  }

  /// 应用运行时配置（设置面板变更后调用）。
  static Future<void> applyRuntime(PetConfig cfg) async {
    await windowManager.setAlwaysOnTop(cfg.alwaysOnTop);
    try {
      await windowManager.setSkipTaskbar(true);
    } catch (_) {}
  }

  static Future<void> placeBottomRight({Size? size}) async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final pos = display.visiblePosition ?? Offset.zero;
      final area = Size(
        display.visibleSize?.width ?? 1920,
        display.visibleSize?.height ?? 1080,
      );
      // 用窗口实际大小定位（自动贴合模型后窗口会缩小，不能再用 petSize）
      final actual = size ?? await windowManager.getSize();
      final target = Offset(
        pos.dx + area.width - actual.width - 24,
        pos.dy + area.height - actual.height - 24,
      );
      PetLog.i(
        'window: placeBottomRight size=$actual area=$area target=$target',
      );
      await windowManager.setPosition(target);
    } catch (_) {
      await windowManager.center();
    }
  }

  static Future<void> setupTray() async {
    final iconPath = await _extractTrayIcon();
    await trayManager.setIcon(iconPath);
    if (!_trayReady) {
      trayManager.addListener(_trayListener);
      _trayReady = true;
    }
    await refreshTray();
  }

  static Future<void> refreshTray() async {
    final cfg = PetConfig.instance;
    final collecting =
        cfg.activityAwarenessEnabled && !cfg.activityAwarenessPaused;
    await trayManager.setToolTip(
      collecting ? 'Amadeus · 活动感知中' : 'Amadeus · 活动感知已暂停',
    );
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: '显示桌宠'),
          MenuItem(key: 'chat', label: '聊两句'),
          MenuItem(key: 'settings', label: '设置'),
          MenuItem.separator(),
          if (cfg.activityAwarenessEnabled)
            MenuItem(
              key: 'toggle-awareness',
              label: cfg.activityAwarenessPaused ? '恢复活动感知' : '暂停活动感知',
            ),
          if (cfg.activityAwarenessEnabled) MenuItem.separator(),
          MenuItem(key: 'quit', label: '退出'),
        ],
      ),
    );
  }

  static Future<String> _extractTrayIcon() async {
    final usePng = Platform.isMacOS || Platform.isLinux;
    final asset = usePng ? 'assets/tray/tray.png' : 'assets/tray/tray.ico';
    final extension = usePng ? 'png' : 'ico';
    final data = await rootBundle.load(asset);
    final dir = Directory('${Directory.systemTemp.path}/amadeus');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/tray.$extension');
    await file.writeAsBytes(data.buffer.asUint8List());
    return file.path;
  }
}

class _CloseToTrayListener extends WindowListener {
  Timer? _diagTimer;

  @override
  void onWindowClose() {
    windowManager.hide();
  }

  @override
  void onWindowResize() => _logActual();

  @override
  void onWindowMove() => _logActual();

  /// 节流上报窗口真实位置/大小（用于核对每个绘制区域是否与窗口对齐）。
  void _logActual() {
    _diagTimer?.cancel();
    _diagTimer = Timer(const Duration(milliseconds: 250), () async {
      try {
        final pos = await windowManager.getPosition();
        final size = await windowManager.getSize();
        PetLog.i('window: actual pos=$pos size=$size');
      } catch (_) {}
    });
  }
}

class _TrayHandler extends TrayListener {
  @override
  void onTrayIconMouseDown() {
    _toggle();
  }

  @override
  void onTrayIconRightMouseDown() {
    PetLog.i('tray: right-click -> popup context menu');
    // 插件 C++ 侧已强制 SetForegroundWindow：菜单拿到前台，点击其他区域能自动收回
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        windowManager.show();
        break;
      case 'chat':
        windowManager.show();
        PetWindow.onShowChat?.call();
        break;
      case 'settings':
        PetWindow.onOpenSettings?.call();
        break;
      case 'toggle-awareness':
        final cfg = PetConfig.instance;
        cfg.activityAwarenessPaused = !cfg.activityAwarenessPaused;
        cfg.save();
        unawaited(PetWindow.refreshTray());
        PetLog.i(
          'activity: ${cfg.activityAwarenessPaused ? 'paused' : 'resumed'} from tray',
        );
        break;
      case 'quit':
        windowManager.destroy();
        break;
    }
  }

  Future<void> _toggle() async {
    if (await windowManager.isVisible()) {
      await windowManager.hide();
    } else {
      await windowManager.show();
    }
  }
}
