import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'reply_content.dart';

/// 连接方式。
///
/// 这不是显示标签，而是鉴权与失败处理的口径：本地端点默认不带 Bearer，
/// 且本地失败**绝不**回落到云端（INV-05）。
enum AiConnectionMode {
  /// 云端服务，需要 API key。
  cloud,

  /// 本地回环端点，默认无鉴权。
  local,
}

/// 取消令牌。
///
/// 取消必须能真正中断在途请求：只把结果丢掉不算取消，连接还在读、
/// token 还在算，用户按下停止之后机器仍在为一个没人要的回答工作。
class CancelToken {
  bool _cancelled = false;
  String _reason = '';
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;
  String get reason => _reason;

  void cancel({String reason = 'user'}) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    final pending = List.of(_listeners);
    _listeners.clear();
    for (final listener in pending) {
      listener();
    }
  }

  void _listen(void Function() onCancel) {
    if (_cancelled) {
      onCancel();
      return;
    }
    _listeners.add(onCancel);
  }

  void _unlisten(void Function() onCancel) => _listeners.remove(onCancel);
}

/// OpenAI 兼容的 AI 对话客户端（云端或本地回环端点）。
class AiChat {
  AiChat({
    String? apiKey,
    String? baseUrl,
    String? model,
    double temperature = 0.8,
    int maxTokens = 800,
    AiConnectionMode? connectionMode,
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
       _explicitKey = apiKey != null && apiKey.isNotEmpty,
       _temperature = temperature,
       _maxTokens = maxTokens {
    _mode = connectionMode ?? _inferMode(_baseUrl);
    _guardLocalEndpoint(baseUrl);
  }

  String _apiKey;
  String _baseUrl;
  String _model;
  double _temperature;
  int _maxTokens;
  late AiConnectionMode _mode;

  /// key 是调用方明确配置的，而不是从环境变量兜底来的。
  ///
  /// 区分这两者是为了不把云端 key 发给回环端点：环境里的 `OPENAI_API_KEY`
  /// 是给云端用的，本地那个进程不该看到它。
  bool _explicitKey;

  /// 供模型使用的短期对话窗口。
  ///
  /// **不是记忆权威**（INV-01 的权威是 PetMemory）。这里只保留最近若干轮，
  /// 且只有真正完成的轮次才留下 —— 被取消或截断的轮次会连同用户消息一起移除，
  /// 否则模型会看到一句用户说过、但会话记录里状态完全不同的话。
  final List<Map<String, String>> _history = [];
  bool _lastRequestCompleted = true;

  AiConnectionMode get connectionMode => _mode;
  String get baseUrl => _baseUrl;
  String get model => _model;

  /// 配置是否足以发起请求。
  ///
  /// 不再等同于「key 非空」：本地端点默认无鉴权，有端点就算配好了。
  bool get configured => switch (_mode) {
    AiConnectionMode.cloud => _apiKey.isNotEmpty,
    AiConnectionMode.local => _baseUrl.isNotEmpty,
  };

  /// 本次请求是否会带 Authorization 头。
  ///
  /// 本地模式只在调用方显式配了 key 时才带（有些本地网关要求鉴权）；
  /// 环境变量里的云端 key 一律不发给回环地址。
  bool get sendsAuthorization => switch (_mode) {
    AiConnectionMode.cloud => _apiKey.isNotEmpty,
    AiConnectionMode.local => _explicitKey && _apiKey.isNotEmpty,
  };

  bool get lastRequestCompleted => _lastRequestCompleted;
  String _lastCompletionReason = 'none';
  String get lastCompletionReason => _lastCompletionReason;

  int get historyLength => _history.length;
  List<Map<String, String>> get historySnapshot =>
      List.unmodifiable(_history.map(Map<String, String>.from));

  /// Create an isolated client for background work such as memory auditing.
  /// It prevents auxiliary requests from changing the foreground request state.
  AiChat auxiliaryClient() => AiChat(
    apiKey: _explicitKey ? _apiKey : null,
    baseUrl: _baseUrl,
    model: _model,
    temperature: _temperature,
    maxTokens: _maxTokens,
    connectionMode: _mode,
  );

  void updateConfig({
    String? apiKey,
    String? baseUrl,
    String? model,
    double? temperature,
    int? maxTokens,
    AiConnectionMode? connectionMode,
  }) {
    final previousBase = _baseUrl;
    final previousModel = _model;
    _baseUrl = _normalizeBaseUrl(baseUrl ?? _baseUrl);
    _model = model ?? _model;
    _temperature = temperature ?? _temperature;
    _maxTokens = maxTokens ?? _maxTokens;
    if (apiKey != null && apiKey.isNotEmpty) {
      _apiKey = apiKey;
      _explicitKey = true;
    } else {
      _apiKey =
          Platform.environment['TIMEPET_API_KEY'] ?? _keyForBaseUrl(_baseUrl);
      _explicitKey = false;
    }
    _mode = connectionMode ?? _inferMode(_baseUrl);
    // 本地模式下端点被清空时不回落到云端默认值。
    if (baseUrl != null) _guardLocalEndpoint(baseUrl);
    // 换端点或换模型后不沿用旧对话窗口：那段历史是另一个模型按另一套
    // chat template 生成的，混着用会让新模型接着扮演它没说过的话。
    if (_baseUrl != previousBase || _model != previousModel) {
      _history.clear();
    }
  }

  /// 本地模式下没配端点就是没配，不借用云端默认值。
  ///
  /// 构造函数的默认 base 是云端地址。若调用方声明了本地模式却传了空端点，
  /// 沿用那个默认值就等于把本地会话静默发去云端 —— 正是 INV-05 禁止的回落。
  void _guardLocalEndpoint(String? requested) {
    if (_mode != AiConnectionMode.local) return;
    if (requested == null || requested.trim().isEmpty) _baseUrl = '';
  }

  static AiConnectionMode _inferMode(String baseUrl) {
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    if (host.isEmpty) return AiConnectionMode.cloud;
    final literal = InternetAddress.tryParse(host);
    if (literal != null && literal.isLoopback) return AiConnectionMode.local;
    return host == 'localhost'
        ? AiConnectionMode.local
        : AiConnectionMode.cloud;
  }

  static String _normalizeBaseUrl(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');

  static String _keyForBaseUrl(String baseUrl) {
    if (baseUrl.toLowerCase().contains('deepseek')) {
      return Platform.environment['DEEPSEEK_API_KEY'] ?? '';
    }
    return Platform.environment['OPENAI_API_KEY'] ?? '';
  }

  /// 追加用户消息，返回 AI 回复（流式到 [onDelta]）。
  ///
  /// [onDelta] 收到的是**供应商原样的增量**，调用方自行累积。需要已剥离标记的
  /// 文本请用 [send]：标记可能跨 token 到达，只有在累积文本上解析才安全。
  Future<String> chat(
    String userText, {
    required String systemPrompt,
    void Function(String delta)? onDelta,
    CancelToken? cancelToken,
  }) async {
    final content = await send(
      userText,
      systemPrompt: systemPrompt,
      onDelta: onDelta,
      cancelToken: cancelToken,
    );
    return content.status == CompletionStatus.complete
        ? content.displayText
        : '';
  }

  /// 发起一轮对话，返回 Spec §7.3 的三元组。
  ///
  /// [onPreview] 收到的是**已剥离标记的累积文本**，可直接显示；
  /// [onDelta] 收到原样增量，供沿用旧接口的调用方累积。
  Future<ReplyContent> send(
    String userText, {
    required String systemPrompt,
    void Function(String delta)? onDelta,
    void Function(String preview)? onPreview,
    CancelToken? cancelToken,
  }) async {
    if (!configured) {
      _lastRequestCompleted = false;
      _lastCompletionReason = 'unconfigured';
      return const ReplyContent(
        displayText: '',
        speechText: '',
        status: CompletionStatus.transportFailed,
        detail: 'unconfigured',
      );
    }

    _history.add({'role': 'user', 'content': userText});
    final userEntry = _history.last;
    final messages = [
      {'role': 'system', 'content': systemPrompt},
      ..._history.reversed.take(10).toList().reversed,
    ];

    final result = await _post(
      messages,
      onDelta: onDelta,
      onPreview: onPreview,
      cancelToken: cancelToken,
    );
    final content = ReplyContent.parse(
      result.text,
      status: result.status,
      detail: _lastCompletionReason,
    );

    if (content.status == CompletionStatus.complete) {
      _history.add({'role': 'assistant', 'content': content.displayText});
      if (_history.length > 24) {
        _history.removeRange(0, _history.length - 24);
      }
    } else {
      // 这一轮不算数：把刚加进去的用户消息也撤掉，避免下一轮的上下文里
      // 出现一句「用户说过、但从来没有得到回答」的悬空消息。
      _history.remove(userEntry);
    }
    return content;
  }

  Future<({CompletionStatus status, String text})> _post(
    List<Map<String, String>> messages, {
    void Function(String delta)? onDelta,
    void Function(String preview)? onPreview,
    CancelToken? cancelToken,
  }) async {
    _lastRequestCompleted = false;
    _lastCompletionReason = 'pending';
    // 429 / 5xx / 网络错误最多重试 2 次（指数退避 1s/2s）；流式不重试，避免重复输出
    const maxAttempts = 3;
    final streaming = onDelta != null || onPreview != null;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (cancelToken?.isCancelled ?? false) {
        _lastCompletionReason = 'cancelled';
        return (status: CompletionStatus.cancelled, text: '');
      }
      final result = await _tryPost(
        messages,
        onDelta: onDelta,
        onPreview: onPreview,
        cancelToken: cancelToken,
      );
      if (result.status == CompletionStatus.complete) {
        _lastRequestCompleted = true;
        return (status: result.status, text: result.text);
      }
      if (!result.retryable ||
          streaming ||
          attempt >= maxAttempts ||
          (cancelToken?.isCancelled ?? false)) {
        return (status: result.status, text: result.text);
      }
      final delay = attempt == 1 ? 1 : 2;
      stderr.writeln(
        'AI request failed, retry in ${delay}s (attempt=$attempt)',
      );
      await Future<void>.delayed(Duration(seconds: delay));
    }
    return (status: CompletionStatus.transportFailed, text: '');
  }

  Future<({CompletionStatus status, bool retryable, String text})> _tryPost(
    List<Map<String, String>> messages, {
    void Function(String delta)? onDelta,
    void Function(String preview)? onPreview,
    CancelToken? cancelToken,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    var aborted = false;
    // 取消的关键是**取消响应流的订阅**，不是关 client。
    //
    // 实测过的三件事：只在读循环里检查取消标志不够（对端不发数据时读取一直挂着）；
    // `HttpClientRequest.abort()` 在响应头到达之后是空操作；而
    // `HttpClient.close(force: true)` 虽然确实会关掉 socket，却不会让已经建立的
    // 响应流完成 —— `await for` 就此永远停住。取消订阅两件事都做到了：
    // 本地立刻停止回调，socket 也随之关闭（对端观测到 FIN）。
    void Function()? stopReader;
    void abort() {
      aborted = true;
      stopReader?.call();
      client.close(force: true);
    }

    cancelToken?._listen(abort);
    try {
      final req = await client
          .postUrl(Uri.parse('$_baseUrl/chat/completions'))
          .timeout(const Duration(seconds: 30));
      req.headers.contentType = ContentType.json;
      if (sendsAuthorization) {
        req.headers.set('Authorization', 'Bearer $_apiKey');
      }
      req.add(
        utf8.encode(
          jsonEncode({
            'model': _model,
            'messages': messages,
            'stream': onDelta != null || onPreview != null,
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
        return (
          status: CompletionStatus.transportFailed,
          retryable: true,
          text: '',
        );
      }
      if (resp.statusCode != 200) {
        _lastCompletionReason = 'http_${resp.statusCode}';
        final body = await resp.transform(utf8.decoder).join();
        stderr.writeln('AI API error ${resp.statusCode}: $body');
        return (
          status: CompletionStatus.transportFailed,
          retryable: false,
          text: '',
        );
      }

      if (onDelta == null && onPreview == null) {
        final body = await resp.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        final text =
            (json['choices'] as List).first['message']['content'] as String?;
        _lastCompletionReason = 'stop';
        return (
          status: CompletionStatus.complete,
          retryable: false,
          text: text ?? '',
        );
      }

      // SSE 流式
      final buffer = StringBuffer();
      var sawDone = false;
      var malformed = false;
      var finishReason = '';
      // 用显式订阅而不是 await for：只有 cancel() 才能立刻停下读取。
      final finished = Completer<void>();
      Object? readError;
      StreamSubscription<String>? sub;
      void stop() {
        final current = sub;
        sub = null;
        if (current != null) unawaited(current.cancel());
        if (!finished.isCompleted) finished.complete();
      }

      stopReader = stop;
      sub = resp
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (cancelToken?.isCancelled ?? false) {
                stop();
                return;
              }
              if (!line.startsWith('data:')) return;
              final data = line.substring(5).trim();
              if (data == '[DONE]') {
                sawDone = true;
                stop();
                return;
              }
              try {
                final json = jsonDecode(data) as Map<String, dynamic>;
                if (json['error'] != null) {
                  malformed = true;
                  _lastCompletionReason = 'provider_error';
                  return;
                }
                final choices = json['choices'];
                if (choices is! List || choices.isEmpty) return;
                final first = choices.first;
                if (first is! Map<String, dynamic>) {
                  malformed = true;
                  return;
                }
                final choice = first;
                finishReason =
                    choice['finish_reason']?.toString() ?? finishReason;
                final delta = choice['delta'];
                if (delta is! Map<String, dynamic>) return;
                // 只消费用户可见答案字段，独立的 reasoning 内容忽略（Spec §7.3）。
                final piece = delta['content'] as String?;
                if (piece != null && piece.isNotEmpty) {
                  buffer.write(piece);
                  onDelta?.call(piece);
                  if (onPreview != null) {
                    onPreview(ReplyContent.previewOf(buffer.toString()));
                  }
                }
              } catch (_) {
                malformed = true;
                _lastCompletionReason = 'malformed_event';
              }
            },
            onError: (Object e) {
              readError = e;
              stop();
            },
            onDone: stop,
            cancelOnError: true,
          );
      await finished.future;
      stopReader = null;

      if (cancelToken?.isCancelled ?? false) {
        _lastCompletionReason = 'cancelled';
        return (
          status: CompletionStatus.cancelled,
          retryable: false,
          text: buffer.toString(),
        );
      }
      if (readError != null) throw readError!;
      if (finishReason == 'length') {
        _lastCompletionReason = 'length';
        return (
          status: CompletionStatus.truncated,
          retryable: false,
          text: buffer.toString(),
        );
      }
      if (malformed) {
        return (
          status: CompletionStatus.malformed,
          retryable: false,
          text: buffer.toString(),
        );
      }
      if (!sawDone && finishReason != 'stop') {
        _lastCompletionReason = 'network_closed';
        stderr.writeln('AI stream ended without [DONE] finish=$finishReason');
        return (
          status: CompletionStatus.transportFailed,
          retryable: true,
          text: buffer.toString(),
        );
      }
      _lastCompletionReason = finishReason.isEmpty ? 'done' : finishReason;
      return (
        status: CompletionStatus.complete,
        retryable: false,
        text: buffer.toString(),
      );
    } catch (e) {
      if (aborted || (cancelToken?.isCancelled ?? false)) {
        _lastCompletionReason = 'cancelled';
        return (status: CompletionStatus.cancelled, retryable: false, text: '');
      }
      stderr.writeln('AI chat error: $e');
      return (
        status: CompletionStatus.transportFailed,
        retryable: true,
        text: '',
      );
    } finally {
      cancelToken?._unlisten(abort);
      client.close(force: aborted);
    }
  }

  /// 不写入历史的一次性调用（记忆提取等内部任务用）。
  Future<String> rawChat({
    required String system,
    required String user,
    CancelToken? cancelToken,
  }) async {
    if (!configured) {
      _lastRequestCompleted = false;
      _lastCompletionReason = 'unconfigured';
      return '';
    }
    final messages = [
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': user},
    ];
    final result = await _post(messages, cancelToken: cancelToken);
    return result.status == CompletionStatus.complete ? result.text : '';
  }

  void clearHistory() => _history.clear();
}
