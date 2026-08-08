import 'dart:convert';
import 'dart:io';

/// OpenAI 兼容的 AI 对话客户端（默认 DeepSeek，可配置）。
class AiChat {
  AiChat({
    String? apiKey,
    String? baseUrl,
    String? model,
    double temperature = 0.8,
    int maxTokens = 800,
  })  : _apiKey = apiKey ?? Platform.environment['DEEPSEEK_API_KEY'] ?? '',
        _baseUrl = baseUrl ??
            Platform.environment['TIMEPET_BASE_URL'] ??
            'https://api.deepseek.com/v1',
        _model = model ??
            Platform.environment['TIMEPET_MODEL'] ??
            'deepseek-chat',
        _temperature = temperature,
        _maxTokens = maxTokens;

  final String _apiKey;
  final String _baseUrl;
  final String _model;
  final double _temperature;
  final int _maxTokens;
  final List<Map<String, String>> _history = [];

  bool get configured => _apiKey.isNotEmpty;

  /// 追加用户消息，返回 AI 回复（流式到 [onDelta]）。
  Future<String> chat(
    String userText, {
    required String systemPrompt,
    void Function(String delta)? onDelta,
  }) async {
    _history.add({'role': 'user', 'content': userText});
    final messages = [
      {'role': 'system', 'content': systemPrompt},
      ..._history.reversed.take(10).toList().reversed,
    ];

    final resp = await _post(messages, onDelta: onDelta);
    final reply = resp ?? '';
    if (reply.isNotEmpty) {
      _history.add({'role': 'assistant', 'content': reply});
      if (_history.length > 24) {
        _history.removeRange(0, _history.length - 24);
      }
    }
    return reply;
  }

  /// 单次请求结果：retryable=true 表示可重试（429/5xx/网络错误）。
  Future<String?> _post(
    List<Map<String, String>> messages, {
    void Function(String delta)? onDelta,
  }) async {
    // 429 / 5xx / 网络错误最多重试 2 次（指数退避 1s/2s）；流式不重试，避免重复输出
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final result = await _tryPost(messages, onDelta: onDelta);
      if (result.ok) return result.text;
      if (!result.retryable || onDelta != null || attempt >= maxAttempts) {
        return null;
      }
      final delay = attempt == 1 ? 1 : 2;
      stderr.writeln('AI request failed, retry in ${delay}s (attempt=$attempt)');
      await Future<void>.delayed(Duration(seconds: delay));
    }
    return null;
  }

  Future<({bool ok, bool retryable, String? text})> _tryPost(
    List<Map<String, String>> messages, {
    void Function(String delta)? onDelta,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client
          .postUrl(Uri.parse('$_baseUrl/chat/completions'))
          .timeout(const Duration(seconds: 30));
      req.headers.contentType = ContentType.json;
      req.headers.set('Authorization', 'Bearer $_apiKey');
      req.add(utf8.encode(jsonEncode({
        'model': _model,
        'messages': messages,
        'stream': onDelta != null,
        'temperature': _temperature,
        'max_tokens': _maxTokens,
      })));

      final resp = await req.close().timeout(const Duration(seconds: 120));
      if (resp.statusCode == 429 || resp.statusCode >= 500) {
        final body = await resp.transform(utf8.decoder).join();
        stderr.writeln('AI API transient error ${resp.statusCode}: ${body.length > 200 ? body.substring(0, 200) : body}');
        return (ok: false, retryable: true, text: null);
      }
      if (resp.statusCode != 200) {
        final body = await resp.transform(utf8.decoder).join();
        stderr.writeln('AI API error ${resp.statusCode}: $body');
        return (ok: false, retryable: false, text: null);
      }

      if (onDelta == null) {
        final body = await resp.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        final text = (json['choices'] as List).first['message']['content'] as String?;
        return (ok: true, retryable: false, text: text);
      }

      // SSE 流式
      final buffer = StringBuffer();
      await for (final line in resp.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') break;
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final delta = (json['choices'] as List).first['delta'] as Map<String, dynamic>;
          final piece = delta['content'] as String?;
          if (piece != null && piece.isNotEmpty) {
            buffer.write(piece);
            onDelta(piece);
          }
        } catch (_) {}
      }
      return (ok: true, retryable: false, text: buffer.toString());
    } catch (e) {
      stderr.writeln('AI chat error: $e');
      return (ok: false, retryable: true, text: null);
    } finally {
      client.close();
    }
  }

  /// 不写入历史的一次性调用（记忆提取等内部任务用）。
  Future<String> rawChat({required String system, required String user}) async {
    final messages = [
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': user},
    ];
    final resp = await _post(messages);
    return resp ?? '';
  }

  void clearHistory() => _history.clear();
}