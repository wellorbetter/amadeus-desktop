import 'dart:async';
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

  /// 最近一次由 Flutter 推送到页面的贴合范围（reload 后按它重新定位）。
  ({int x, int y, int w, int h})? lastFit;

  // 当前模型（虚拟主机 model.local 映射到模型目录）
  String? _modelFile;
  String? _modelDir;
  String? get modelFile => _modelFile;

  /// 用户在桌宠上点击/触摸时回调（用于显示聊天框）。
  /// 用户在桌宠上右键时回调（参数为页面内坐标 CSS px）。
  void Function(int x, int y)? onUserMenu;
  void Function()? onUserTap;

  /// 模型渲染完成后上报实际绘制范围（画布内 CSS 坐标），用于窗口贴合模型。
  void Function(int x, int y, int w, int h, bool shrink)? onModelFit;

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
        // 每次导航完成（首次加载 + location.reload()）都兜底执行：
        // 重推外观（修复 localStorage 恢复失效）、按上次贴合重新定位、
        // 重新测量上报。避免 reload 后「先偏右再回正/尺寸跳变」。
        unawaited(_afterNavigation());
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
        final shrink = text.contains('model-fit-shrink');
        final m = RegExp(r'model-fit(?:-shrink)? x=(-?\d+) y=(-?\d+) w=(\d+) h=(\d+)')
            .firstMatch(text);
        if (m != null) {
          onModelFit?.call(
            int.parse(m.group(1)!),
            int.parse(m.group(2)!),
            int.parse(m.group(3)!),
            int.parse(m.group(4)!),
            shrink,
          );
        }
      } else {
        PetLog.i('kurisu: webMessage=$text');
      }
    });
  }

  /// 每次页面导航完成后兜底：重推外观 + 按上次贴合重新定位 + 重新测量。
  /// 解决 location.reload() 后页面 JS 状态重置导致的：外观漂移（localStorage 恢复失效）、
  /// 预贴合阶段画布居中导致模型偏右/裁剪、以及贴合尺寸被重新上报导致的窗口缩放跳变。
  Future<void> _afterNavigation() async {
    final n = _navCount;
    PetLog.i('kurisu: after-navigation #$n start');
    await Future.delayed(const Duration(milliseconds: 600));
    if (!_initialized) return;
    try {
      // 1) 外观兜底：与配置不一致时重新推送（scale 变化会触发页面 reinit）
      await applyAppearance();
      PetLog.i('kurisu: after-navigation #$n appearance pushed');
      // 2) 尺寸兜底：按上次贴合范围重新定位（页面恢复失败时也保持正确位置）
      final fit = lastFit;
      if (fit != null) {
        await _exec(
            'window.pet && window.pet.fitToModel({x: ${fit.x}, y: ${fit.y}, w: ${fit.w}, h: ${fit.h}})');
        await _exec('window.pet && window.pet.layout()');
        PetLog.i('kurisu: after-navigation #$n refit ${fit.w}x${fit.h}@${fit.x},${fit.y}');
      }
      // 3) 重新测量上报（增长才改窗口；force 用于按当前测量重定位）
      await requestFit();
      // 4) 非首次导航：等外观确认后再兜底显示（避免恢复失效时先显示错的比例）
      if (n > 1) {
        var ok = false;
        for (var i = 0; i < 6 && !ok; i++) {
          await Future.delayed(const Duration(milliseconds: 500));
          ok = await _appearanceMatches();
          if (!ok) PetLog.i('kurisu: after-navigation #$n waiting appearance i=$i');
        }
        await reveal();
        PetLog.i('kurisu: after-navigation #$n fallback reveal ok=$ok');
      }
    } catch (e) {
      PetLog.e('kurisu: after-navigation error: $e');
    }
  }

  /// 核对页面当前外观（scale/vOffset/opacity）是否与配置一致。
  Future<bool> _appearanceMatches() async {
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
        PetLog.i('kurisu: appearance check scale=$scale vOff=$vOff op=$op ok=$ok');
        return ok;
      }
    } catch (e) {
      PetLog.e('kurisu: appearance check error: $e');
    }
    return false;
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
    lastFit = (x: x, y: y, w: w, h: h);
    await _exec('window.pet && window.pet.fitToModel({x: $x, y: $y, w: $w, h: $h})');
    PetLog.i('kurisu: fitToModel x=$x y=$y w=$w h=$h');
  }

  /// 重跑一次布局（窗口尺寸变化后调用）。
  Future<void> layout() async {
    await _exec('window.pet && window.pet.layout()');
  }

  /// 请求页面重新扫描模型范围并上报（模型大小被调整后调用）。
  Future<void> requestFit({bool allowShrink = false}) async {
    await _exec('window.pet && window.pet.requestFit($allowShrink)');
    PetLog.i('kurisu: requestFit allowShrink=$allowShrink');
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
