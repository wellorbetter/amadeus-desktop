import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:window_manager/window_manager.dart';

import 'pet_config.dart';
import 'pet_model.dart';
import 'pet_logger.dart';

/// Kurisu Live2D 渲染层（WebView2 纹理合成，透明背景）。
class KurisuController {
  /// 底部固定预留的聊天输入区高度（窗口贴合模型时算入窗口高度）。
  static const double inputReserve = 84.0;

  final WebviewController controller = WebviewController();

  bool _initialized = false;
  int _navCount = 0;

  // 当前模型（虚拟主机 model.local 映射到模型目录）
  String? _modelFile;
  String? _modelDir;
  String? get modelFile => _modelFile;

  /// 用户在桌宠上点击/触摸时回调（用于显示聊天框）。
  /// 用户在桌宠上右键时回调（参数为页面内坐标 CSS px）。
  void Function(int x, int y)? onUserMenu;
  void Function()? onUserTap;

  /// 模型渲染完成后上报实际绘制范围（画布内 CSS 坐标），用于窗口贴合模型。
  void Function(int x, int y, int w, int h)? onModelFit;

  DateTime? _lastDragAt;

  Future<void> initialize() async {
    if (_initialized) return;
    PetLog.i('kurisu: initialize start');
    try {
      await WebviewController.initializeEnvironment(
        additionalArguments:
            '--ignore-gpu-blocklist --enable-webgl --enable-unsafe-swiftshader',
      );
      PetLog.i('kurisu: initializeEnvironment ok');
    } catch (e) {
      PetLog.e('kurisu: initializeEnvironment error: $e');
    }
    await controller.initialize();
    // 本地资产映射：https://pet.local/ -> <exe>/data/flutter_assets/assets/web
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final webDir = '$exeDir/data/flutter_assets/assets/web';
    PetLog.i('kurisu: webDir=$webDir exists=${Directory(webDir).existsSync()}');
    await controller.addVirtualHostNameMapping(
      'pet.local',
      webDir,
      WebviewHostResourceAccessKind.allow,
    );
    PetLog.i('kurisu: virtual host mapped');

    // 模型插件：映射外部模型目录（model.local），并通过 query 传入模型文件名
    final model = PetModel.resolve();
    if (model != null) {
      _modelFile = model.file;
      _modelDir = model.dir;
      await controller.addVirtualHostNameMapping(
        'model.local',
        model.dir,
        WebviewHostResourceAccessKind.allow,
      );
      PetLog.i('kurisu: model mapped file=${model.file} dir=${model.dir}');
    } else {
      PetLog.w('kurisu: no model resolved, fallback hint will show');
    }
    await controller.setBackgroundColor(Colors.transparent);
    await controller.setFpsLimit(30);
    _wireLogging();
    final modelParam = _modelFile == null
        ? ''
        : '?model=${Uri.encodeComponent(_modelFile!)}';
    await controller.loadUrl('https://pet.local/kurisu.html$modelParam');
    PetLog.i('kurisu: loadUrl done');
    _initialized = true;
    _pollStatus();
  }

  void _wireLogging() {
    controller.onLoadError.listen((err) {
      PetLog.e('kurisu: onLoadError=$err');
    });
    controller.loadingState.listen((state) {
      PetLog.i('kurisu: loadingState=$state');
      if (state == LoadingState.navigationCompleted) {
        _navCount++;
        // 首次加载由 bootstrap 推送外观；location.reload() 后页面 JS 状态
        // 会重置为默认值，这里兜底核对一次配置，不一致则重新推送。
        if (_navCount > 1) _afterReloadCheck();
      }
    });
    controller.webMessage.listen((msg) {
      final text = msg?.toString() ?? '';
      if (text.contains('drag')) {
        // 节流：拖动期间 JS 可能重复上报，避免连续触发系统 move 循环
        final now = DateTime.now();
        if (_lastDragAt == null ||
            now.difference(_lastDragAt!) > const Duration(milliseconds: 800)) {
          _lastDragAt = now;
          PetLog.i('kurisu: drag -> startDragging');
          windowManager.startDragging();
        }
      } else if (text.contains('user-tap')) {
        PetLog.i('kurisu: user-tap');
        onUserTap?.call();
      } else if (text.contains('user-menu')) {
        final m = RegExp(r'user-menu (-?\d+) (-?\d+)').firstMatch(text);
        if (m != null) {
          PetLog.i('kurisu: user-menu x=${m.group(1)} y=${m.group(2)}');
          onUserMenu?.call(
            int.parse(m.group(1)!),
            int.parse(m.group(2)!),
          );
        }
      } else if (text.contains('model-fit')) {
        PetLog.i('kurisu: $text');
        final m = RegExp(r'model-fit x=(-?\d+) y=(-?\d+) w=(\d+) h=(\d+)')
            .firstMatch(text);
        if (m != null) {
          onModelFit?.call(
            int.parse(m.group(1)!),
            int.parse(m.group(2)!),
            int.parse(m.group(3)!),
            int.parse(m.group(4)!),
          );
        }
      } else {
        PetLog.i('kurisu: webMessage=$text');
      }
    });
  }

  /// 页面被 location.reload() 重载后核对外观配置（localStorage 恢复失效时的兜底）。
  Future<void> _afterReloadCheck() async {
    await Future.delayed(const Duration(milliseconds: 1500));
    try {
      final r = await controller.executeScript(
          'window.pet && window.pet.getAppearance ? JSON.stringify(window.pet.getAppearance()) : "NO_PET"');
      if (r is String && r.startsWith('{')) {
        final map = jsonDecode(r) as Map<String, dynamic>;
        final cfg = PetConfig.instance;
        final scale = (map['modelScale'] as num?)?.toDouble() ?? -1;
        final vOff = (map['vOffset'] as num?)?.toDouble() ?? -1;
        final op = (map['modelOpacity'] as num?)?.toDouble() ?? -1;
        final ok = (scale - cfg.modelScale).abs() < 0.001 &&
            (vOff - cfg.vOffset).abs() < 0.001 &&
            (op - cfg.modelOpacity).abs() < 0.001;
        if (ok) {
          PetLog.i('kurisu: appearance ok after reload scale=$scale');
        } else {
          PetLog.i('kurisu: appearance mismatch after reload scale=$scale vOff=$vOff op=$op, re-push');
          await applyAppearance();
        }
      } else {
        PetLog.w('kurisu: getAppearance unavailable after reload ($r)');
      }
    } catch (e) {
      PetLog.e('kurisu: after-reload appearance check error: $e');
    }
  }

  /// 轮询页面状态，确认 Live2D 是否成功创建 canvas。
  Future<void> _pollStatus() async {
    for (var i = 1; i <= 15; i++) {
      await Future.delayed(const Duration(seconds: 1));
      if (!_initialized) return;
      try {
        final log = await controller.executeScript(
            'window.__petLog ? JSON.stringify(window.__petLog) : "NO_PET_LOG"');
        final canvas = await controller.executeScript(
            '!!document.querySelector("canvas")');
        PetLog.i('kurisu: poll#$i canvas=$canvas log=$log');
        if (canvas == true || canvas == 'true') {
          PetLog.i('kurisu: canvas ready');
          try {
            final diag = await controller.executeScript(
                'window.pet && window.pet.diag ? window.pet.diag() : "NO_DIAG"');
            PetLog.i('kurisu: diag=$diag');
          } catch (e) {
            PetLog.e('kurisu: diag error: $e');
          }
          break;
        }
      } catch (e) {
        PetLog.e('kurisu: poll error: $e');
      }
    }
  }

  /// 重新解析并切换模型（模型路径配置变化后调用；无变化则跳过）。
  Future<void> setModel() async {
    final model = PetModel.resolve();
    final file = model?.file;
    final dir = model?.dir;
    if (file == _modelFile && dir == _modelDir) return;
    if (model != null) {
      _modelFile = file;
      _modelDir = dir;
      await controller.addVirtualHostNameMapping(
        'model.local',
        dir!,
        WebviewHostResourceAccessKind.allow,
      );
      PetLog.i('kurisu: model remapped file=$file dir=$dir');
    } else {
      _modelFile = null;
      _modelDir = null;
      PetLog.w('kurisu: model removed');
    }
    final jsFile = _modelFile == null ? 'null' : "'$_modelFile'";
    await _exec('window.pet && window.pet.setModel($jsFile)');
  }

  /// 应用设置面板里的外观配置（位置/尺寸/透明度即时生效）。
  Future<void> applyAppearance() async {
    final cfg = PetConfig.instance;
    await _exec(
      'window.pet && window.pet.applyAppearance({'
      'displayWidth: ${cfg.displayWidth},'
      'displayHeight: ${cfg.displayHeight},'
      'hOffset: ${cfg.hOffset},'
      'vOffset: ${cfg.vOffset},'
      'modelScale: ${cfg.modelScale},'
      'modelOpacity: ${cfg.modelOpacity},'
      'soundEnabled: ${cfg.soundEnabled},'
      'soundVolume: ${cfg.soundVolume},'
      'inputReserve: $inputReserve'
      '})',
    );
    PetLog.i(
        'kurisu: applyAppearance w=${cfg.displayWidth} h=${cfg.displayHeight} '
        'v=${cfg.vOffset} op=${cfg.modelOpacity}');
  }

  /// 窗口贴合模型：告诉页面模型的画布内绘制范围（CSS px）。
  Future<void> fitToModel(int x, int y, int w, int h) async {
    await _exec('window.pet && window.pet.fitToModel({x: $x, y: $y, w: $w, h: $h})');
    PetLog.i('kurisu: fitToModel x=$x y=$y w=$w h=$h');
  }

  /// 重跑一次布局（窗口尺寸变化后调用）。
  Future<void> layout() async {
    await _exec('window.pet && window.pet.layout()');
  }

  /// 请求页面重新扫描模型范围并上报（模型大小被调整后调用）。
  Future<void> requestFit() async {
    await _exec('window.pet && window.pet.requestFit()');
  }

  /// 显示模型（首帧贴合完成后调用，避免启动时先大后小的变形）。
  Future<void> reveal() async {
    await _exec('window.pet && window.pet.reveal()');
  }

  /// 播放动作：tap_body / flick_head / shake / pinch_in / pinch_out
  Future<void> motion(String name) async {
    await _exec('window.pet && window.pet.motion("$name")');
  }

  /// 切换表情（随机）
  /// 随机互动：随机动作 + 概率表情（点击 / 空闲 / 右键菜单触发）。
  Future<void> randomReact() async {
    await _exec('window.pet && window.pet.randomReact()');
  }

  /// 重新加载模型页面（右键菜单「重新加载模型」）。
  Future<void> reload() async {
    await _exec('location.reload()');
  }
  Future<void> expression() async {
    await _exec('window.pet && window.pet.expression()');
  }

  Future<void> _exec(String script) async {
    if (!_initialized) return;
    try {
      await controller.executeScript(script);
    } catch (_) {
      // WebView 未就绪时静默忽略
    }
  }

  void dispose() {
    controller.dispose();
  }
}
