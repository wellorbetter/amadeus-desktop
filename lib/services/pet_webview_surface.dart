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
    if (Platform.isLinux) return const _LinuxAvatarFallback();
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
    if (Platform.isLinux) {
      // Linux does not yet have an embedded Live2D WebView backend. Keep the
      // Agent usable with an explicit original fallback instead of failing at
      // startup or pretending that the imported model is being rendered.
      onNavigationCompleted();
      return;
    }
    throw UnsupportedError('Unsupported desktop platform');
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

class _LinuxAvatarFallback extends StatelessWidget {
  const _LinuxAvatarFallback();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        width: 176,
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 26,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [scheme.primary, scheme.secondary],
                ),
              ),
              child: const Icon(
                Icons.graphic_eq_rounded,
                color: Colors.white,
                size: 38,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Amadeus',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
            ),
            const SizedBox(height: 5),
            Text(
              'Linux Agent 预览',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
