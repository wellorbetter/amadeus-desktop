import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart' as mac;
import 'package:webview_windows/webview_windows.dart' as win;

class PetWebViewSurface {
  win.WebviewController? _windows;
  mac.WebViewController? _macOS;

  late final void Function(String message) _onMessage;
  late final VoidCallback _onNavigationCompleted;
  late final void Function(Object error) _onError;

  Widget get widget {
    final windows = _windows;
    if (windows != null) return win.Webview(windows);
    final macOS = _macOS;
    if (macOS != null) return mac.WebViewWidget(controller: macOS);
    return const SizedBox.expand();
  }

  Future<void> initialize({
    required String initialUrl,
    required void Function(String message) onMessage,
    required VoidCallback onNavigationCompleted,
    required void Function(Object error) onError,
  }) async {
    _onMessage = onMessage;
    _onNavigationCompleted = onNavigationCompleted;
    _onError = onError;

    if (Platform.isWindows) {
      await _initializeWindows(initialUrl);
      return;
    }
    if (Platform.isMacOS) {
      await _initializeMacOS(initialUrl);
      return;
    }
    throw UnsupportedError('Amadeus currently supports Windows and macOS');
  }

  Future<void> _initializeWindows(String initialUrl) async {
    await win.WebviewController.initializeEnvironment(
      additionalArguments:
          '--ignore-gpu-blocklist --enable-webgl --enable-unsafe-swiftshader',
    );
    final controller = win.WebviewController();
    _windows = controller;
    await controller.initialize();
    await controller.setBackgroundColor(Colors.transparent);
    await controller.setFpsLimit(30);
    controller.onLoadError.listen(_onError);
    controller.loadingState.listen((state) {
      if (state == win.LoadingState.navigationCompleted) {
        _onNavigationCompleted();
      }
    });
    controller.webMessage.listen((message) {
      _onMessage(message?.toString() ?? '');
    });
    await controller.loadUrl(initialUrl);
  }

  Future<void> _initializeMacOS(String initialUrl) async {
    final controller = mac.WebViewController();
    _macOS = controller;
    await controller.setJavaScriptMode(mac.JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(Colors.transparent);
    await controller.addJavaScriptChannel(
      'AmadeusHost',
      onMessageReceived: (message) => _onMessage(message.message),
    );
    await controller.setNavigationDelegate(
      mac.NavigationDelegate(
        onPageFinished: (_) => _onNavigationCompleted(),
        onWebResourceError: _onError,
      ),
    );
    await controller.loadRequest(Uri.parse(initialUrl));
  }

  Future<void> loadUrl(String url) async {
    final windows = _windows;
    if (windows != null) {
      await windows.loadUrl(url);
      return;
    }
    await _macOS?.loadRequest(Uri.parse(url));
  }

  Future<Object?> executeScript(String script) async {
    final windows = _windows;
    if (windows != null) return windows.executeScript(script);
    return _macOS?.runJavaScriptReturningResult(script);
  }

  void dispose() {
    _windows?.dispose();
    _windows = null;
    _macOS = null;
  }
}
