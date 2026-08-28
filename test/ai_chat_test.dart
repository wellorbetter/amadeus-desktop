import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/ai_chat.dart';

Future<HttpServer> _server(
  String body, {
  bool stream = true,
  void Function(Map<String, dynamic> payload)? onPayload,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final request in server) {
      final requestBody = await utf8.decoder.bind(request).join();
      if (onPayload != null) {
        onPayload(jsonDecode(requestBody) as Map<String, dynamic>);
      }
      request.response.headers.contentType = stream
          ? ContentType('text', 'event-stream', charset: 'utf-8')
          : ContentType.json;
      if (stream) {
        request.response.write(body);
      } else {
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': body},
              },
            ],
          }),
        );
      }
      await request.response.close();
    }
  }());
  return server;
}

void main() {
  test(
    'streaming chat joins deltas including emoji and ignores empty choices',
    () async {
      final server = await _server(
        'data: {"choices":[]}\n\n'
        'data: {"choices":[{"delta":{"content":"你好🌙"},"finish_reason":null}]}\n\n'
        'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
        'data: [DONE]\n\n',
      );
      addTearDown(server.close);
      final chat = AiChat(
        apiKey: 'test',
        baseUrl: 'http://127.0.0.1:${server.port}/',
        model: 'gpt-test',
      );
      final deltas = StringBuffer();

      final result = await chat.chat(
        'hello',
        systemPrompt: 'test',
        onDelta: deltas.write,
      );

      expect(result, '你好🌙');
      expect(deltas.toString(), result);
      expect(chat.lastRequestCompleted, isTrue);
    },
  );

  test('stream without DONE is not reported as a completed reply', () async {
    final server = await _server(
      'data: {"choices":[{"delta":{"content":"partial"},"finish_reason":"length"}]}\n\n',
    );
    addTearDown(server.close);
    final chat = AiChat(
      apiKey: 'test',
      baseUrl: 'http://127.0.0.1:${server.port}',
      model: 'gpt-test',
    );

    final result = await chat.chat(
      'hello',
      systemPrompt: 'test',
      onDelta: (_) {},
    );

    expect(result, isEmpty);
    expect(chat.lastRequestCompleted, isFalse);
  });

  test('finish stop can complete without a DONE sentinel', () async {
    final server = await _server(
      'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n',
    );
    addTearDown(server.close);
    final chat = AiChat(
      apiKey: 'test',
      baseUrl: 'http://127.0.0.1:${server.port}',
      model: 'gpt-test',
    );

    expect(
      await chat.chat('hello', systemPrompt: 'test', onDelta: (_) {}),
      'ok',
    );
    expect(chat.lastCompletionReason, 'stop');
  });

  test('malformed SSE is not silently accepted as a full reply', () async {
    final server = await _server(
      'data: {"choices":[{"delta":{"content":"half"}}]}\n\n'
      'data: not-json\n\n'
      'data: [DONE]\n\n',
    );
    addTearDown(server.close);
    final chat = AiChat(
      apiKey: 'test',
      baseUrl: 'http://127.0.0.1:${server.port}',
      model: 'gpt-test',
    );

    expect(
      await chat.chat('hello', systemPrompt: 'test', onDelta: (_) {}),
      isEmpty,
    );
    expect(chat.lastRequestCompleted, isFalse);
    expect(chat.lastCompletionReason, 'malformed_event');
  });

  test(
    'visible chat and internal generation never retain hidden history',
    () async {
      final payloads = <Map<String, dynamic>>[];
      final server = await _server(
        'ok',
        stream: false,
        onPayload: payloads.add,
      );
      addTearDown(server.close);
      final chat = AiChat(
        apiKey: 'test',
        baseUrl: 'http://127.0.0.1:${server.port}',
        model: 'gpt-test',
      );

      await chat.chat('first visible turn', systemPrompt: 'context one');
      await chat.generate(
        'internal trigger directive',
        systemPrompt: 'context two',
      );
      await chat.chat('second visible turn', systemPrompt: 'context three');

      expect(payloads, hasLength(3));
      final lastMessages = payloads.last['messages'] as List<dynamic>;
      expect(lastMessages, hasLength(2));
      expect(lastMessages[0], {'role': 'system', 'content': 'context three'});
      expect(lastMessages[1], {
        'role': 'user',
        'content': 'second visible turn',
      });
      expect(jsonEncode(payloads.last), isNot(contains('first visible turn')));
      expect(
        jsonEncode(payloads.last),
        isNot(contains('internal trigger directive')),
      );
    },
  );
}
