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
  }) : _baseUrl = _normalizeBaseUrl(
         baseUrl ??
             Platform.environment['TIMEPET_BASE_URL'] ??
             'https://api.openai.com/v1',
       ),
       _model =
           model ?? Platform.environment['TIMEPET_MODEL'] ?? 'gpt-5.6-luna',
       _apiKey =
           apiKey ??
           Platform.environment['TIMEPET_API_KEY'] ??
           _keyForBaseUrl(
             baseUrl ??
                 Platform.environment['TIMEPET_BASE_URL'] ??
                 'https://api.openai.com/v1',
           ),
       _temperature = temperature,
       _maxTokens = maxTokens;

  String _apiKey;
  String _baseUrl;
  String _model;
  double _temperature;
  int _maxTokens;
  bool _lastRequestCompleted = true;

  bool get configured => _apiKey.isNotEmpty;
  bool get lastRequestCompleted => _lastRequestCompleted;
  String _lastCompletionReason = 'none';
  String get lastCompletionReason => _lastCompletionReason;

  /// Create an isolated client for background work such as memory auditing.
  /// It prevents auxiliary requests from changing the foreground request state.
  AiChat auxiliaryClient() => AiChat(
    apiKey: _apiKey,
    baseUrl: _baseUrl,
    model: _model,
    temperature: _temperature,
    maxTokens: _maxTokens,
  );

  void updateConfig({
    String? apiKey,
    String? baseUrl,
    String? model,
    double? temperature,
    int? maxTokens,
  }) {
    _baseUrl = _normalizeBaseUrl(baseUrl ?? _baseUrl);
    _model = model ?? _model;
    _temperature = temperature ?? _temperature;
    _maxTokens = maxTokens ?? _maxTokens;
    _apiKey =
        apiKey ??
        Platform.environment['TIMEPET_API_KEY'] ??
        _keyForBaseUrl(_baseUrl);
  }

  static String _normalizeBaseUrl(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');

  static String _keyForBaseUrl(String baseUrl) {
    if (baseUrl.toLowerCase().contains('deepseek')) {
      return Platform.environment['DEEPSEEK_API_KEY'] ?? '';
    }
    return Platform.environment['OPENAI_API_KEY'] ?? '';
  }

  /// Replies to one visible user turn.
  ///
  /// Conversation continuity is deliberately supplied by the caller through
  /// [systemPrompt]. Keeping a second hidden history here would duplicate the
  /// persistent working-memory layer and could turn proactive instructions
  /// into fake user turns.
  Future<String> chat(
    String userText, {
    required String systemPrompt,
    void Function(String delta)? onDelta,
  }) async {
    final messages = [
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userText},
    ];
    return await _post(messages, onDelta: onDelta) ?? '';
  }

  /// Generates a greeting or proactive utterance in an isolated request.
  ///
  /// [instruction] is an internal runtime directive, not something the user
  /// said. This explicit API prevents it from entering conversational history.
  Future<String> generate(
    String instruction, {
    required String systemPrompt,
    void Function(String delta)? onDelta,
  }) async {
    final messages = [
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': instruction},
    ];
    return await _post(messages, onDelta: onDelta) ?? '';
  }

  /// 单次请求结果：retryable=true 表示可重试（429/5xx/网络错误）。
  Future<String?> _post(
    List<Map<String, String>> messages, {
    void Function(String delta)? onDelta,
  }) async {
    _lastRequestCompleted = false;
    _lastCompletionReason = 'pending';
    // 429 / 5xx / 网络错误最多重试 2 次（指数退避 1s/2s）；流式不重试，避免重复输出
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final result = await _tryPost(messages, onDelta: onDelta);
      if (result.ok) {
        _lastRequestCompleted = true;
        return result.text;
      }
      if (!result.retryable || onDelta != null || attempt >= maxAttempts) {
        return null;
      }
      final delay = attempt == 1 ? 1 : 2;
      stderr.writeln(
        'AI request failed, retry in ${delay}s (attempt=$attempt)',
      );
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
      req.add(
        utf8.encode(
          jsonEncode({
            'model': _model,
            'messages': messages,
            'stream': onDelta != null,
            'temperature': _temperature,
            'max_tokens': _maxTokens,
          }),
        ),
      );

      final resp = await req.close().timeout(const Duration(seconds: 120));
      if (resp.statusCode == 429 || resp.statusCode >= 500) {
        _lastCompletionReason = 'http_${resp.statusCode}';
        final body = await resp.transform(utf8.decoder).join();
        stderr.writeln(
          'AI API transient error ${resp.statusCode}: ${body.length > 200 ? body.substring(0, 200) : body}',
        );
        return (ok: false, retryable: true, text: null);
      }
      if (resp.statusCode != 200) {
        _lastCompletionReason = 'http_${resp.statusCode}';
        final body = await resp.transform(utf8.decoder).join();
        stderr.writeln('AI API error ${resp.statusCode}: $body');
        return (ok: false, retryable: false, text: null);
      }

      if (onDelta == null) {
        final body = await resp.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        final text =
            (json['choices'] as List).first['message']['content'] as String?;
        _lastCompletionReason = 'stop';
        return (ok: true, retryable: false, text: text);
      }

      // SSE 流式
      final buffer = StringBuffer();
      var sawDone = false;
      var malformed = false;
      var finishReason = '';
      await for (final line
          in resp.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') {
          sawDone = true;
          break;
        }
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          if (json['error'] != null) {
            malformed = true;
            _lastCompletionReason = 'provider_error';
            continue;
          }
          final choices = json['choices'];
          if (choices is! List || choices.isEmpty) continue;
          final first = choices.first;
          if (first is! Map<String, dynamic>) {
            malformed = true;
            continue;
          }
          final choice = first;
          finishReason = choice['finish_reason']?.toString() ?? finishReason;
          final delta = choice['delta'];
          if (delta is! Map<String, dynamic>) continue;
          final piece = delta['content'] as String?;
          if (piece != null && piece.isNotEmpty) {
            buffer.write(piece);
            onDelta(piece);
          }
        } catch (_) {
          malformed = true;
          _lastCompletionReason = 'malformed_event';
        }
      }
      if (finishReason == 'length') {
        _lastCompletionReason = 'length';
        return (ok: false, retryable: false, text: null);
      }
      if (malformed) {
        return (ok: false, retryable: false, text: null);
      }
      if (!sawDone && finishReason != 'stop') {
        _lastCompletionReason = 'network_closed';
        stderr.writeln('AI stream ended without [DONE] finish=$finishReason');
        return (ok: false, retryable: true, text: null);
      }
      _lastCompletionReason = finishReason.isEmpty ? 'done' : finishReason;
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
}
