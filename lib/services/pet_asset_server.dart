import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Loopback-only origin shared by WebView2 and WKWebView.
///
/// Serving bundled web assets and the selected local model from one origin
/// avoids platform-specific virtual-host APIs and WKWebView file-access
/// restrictions. Requests are constrained to known bundled assets or a
/// validated relative path inside the selected model directory.
class PetAssetServer {
  HttpServer? _server;
  String? modelDirectory;

  String get origin {
    final server = _server;
    if (server == null) throw StateError('Pet asset server is not running');
    return 'http://127.0.0.1:${server.port}';
  }

  Future<void> start({String? modelDirectory}) async {
    if (_server != null) {
      this.modelDirectory = modelDirectory;
      return;
    }
    this.modelDirectory = modelDirectory;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve(_server!));
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      try {
        await _handle(request);
      } catch (_) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final segments = request.uri.pathSegments
        .map(Uri.decodeComponent)
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty || segments.any((segment) => segment == '..')) {
      await _notFound(request);
      return;
    }

    Uint8List? bytes;
    var name = segments.last;
    if (segments.first == 'web') {
      final asset = 'assets/web/${segments.skip(1).join('/')}';
      try {
        final data = await rootBundle.load(asset);
        bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } catch (_) {
        await _notFound(request);
        return;
      }
    } else if (segments.first == 'model') {
      final root = modelDirectory;
      if (root == null) {
        await _notFound(request);
        return;
      }
      final relative = segments.skip(1).join(Platform.pathSeparator);
      final file = File('$root${Platform.pathSeparator}$relative');
      try {
        final rootPath = Directory(root).absolute.path;
        final filePath = file.absolute.path;
        final prefix = '$rootPath${Platform.pathSeparator}';
        if (filePath != rootPath && !filePath.startsWith(prefix)) {
          await _notFound(request);
          return;
        }
        bytes = await file.readAsBytes();
      } catch (_) {
        await _notFound(request);
        return;
      }
    } else {
      await _notFound(request);
      return;
    }

    final body = bytes;
    if (body == null) {
      await _notFound(request);
      return;
    }
    request.response.headers
      ..set(HttpHeaders.contentTypeHeader, _contentType(name))
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    request.response.add(body);
    await request.response.close();
  }

  Future<void> _notFound(HttpRequest request) async {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  String _contentType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.html')) return 'text/html; charset=utf-8';
    if (lower.endsWith('.js') || lower.endsWith('.mjs')) {
      return 'text/javascript; charset=utf-8';
    }
    if (lower.endsWith('.json')) return 'application/json; charset=utf-8';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.moc')) return 'application/octet-stream';
    return 'application/octet-stream';
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}
