import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/ai_chat.dart';
import 'package:timepet/services/reply_content.dart';

/// U4 自检：本地无 key 语义、可取消生命周期、三元组输出。
///
/// 全部用真的本地 SSE 服务验证 —— 取消是否真的关掉了连接、请求头里到底有没有
/// Authorization，这两件事只有在真实 socket 上才看得出来。
///
/// 对应 Spec §6（无鉴权本地端点）、§7.3（display/speech/completion 三元组）、
/// §7.4（停止立即生效）、INV-04（不把截断当完整）、INV-05（本地失败不切云）。
void main() {
  /// 记录一次请求的观测结果。
  final headers = <HttpHeaders>[];
  final bodies = <String>[];
  var hits = 0;

  setUp(() {
    headers.clear();
    bodies.clear();
    hits = 0;
  });

  /// 起一个 SSE 服务，按 [events] 逐条发送，每条之间等 [gap]。
  Future<Uri> sse(List<String> events, {Duration gap = Duration.zero}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    unawaited(
      server.forEach((req) async {
        hits++;
        bodies.add(await utf8.decoder.bind(req).join());
        headers.add(req.headers);
        // dart:io 默认缓冲响应输出，不关掉的话所有事件会攒到 close 时一次性
        // 送达 —— 那样测的就不是流式，取消也永远赶不上。
        req.response.bufferOutput = false;
        req.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        try {
          for (final event in events) {
            req.response.write(event);
            await req.response.flush();
            if (gap > Duration.zero) await Future<void>.delayed(gap);
          }
          await req.response.close();
        } catch (_) {
          // 客户端断开后继续写会抛错。这一组测的不是取消，忽略即可。
        }
      }),
    );
    return Uri.parse('http://127.0.0.1:${server.port}/v1');
  }

  String delta(String content) =>
      'data: {"choices":[{"delta":{"content":${jsonEncode(content)}}}]}\n\n';
  const stop = 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n';
  const done = 'data: [DONE]\n\n';

  /// 起一个**裸 socket** 的 SSE 服务，[onClientClose] 在对端关闭连接时触发。
  ///
  /// 取消这件事必须用裸 socket 验，`HttpServer` 验不了：SSE 写到一半被对端
  /// reset 时，它既不抛错也不完成 `response.done`，只是永远停在 `flush()` 上 ——
  /// 那样「连接真的断了」和「连接还在、只是本地不读了」两种情况长得一模一样，
  /// 而后者恰恰是要排除的假取消。裸 socket 能直接观测到对端关闭。
  Future<Uri> rawSse(
    List<String> events, {
    Duration gap = Duration.zero,
    bool silentAfter = false,
    required void Function() onClientClose,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    unawaited(
      server.forEach((socket) async {
        // 请求内容本身不重要，这一组测的是连接生命周期。
        // 对端 destroy 后这里收到 RST（onError）或 FIN（onDone），两者都算关闭。
        socket.listen(
          (_) {},
          onError: (_) => onClientClose(),
          onDone: onClientClose,
          cancelOnError: true,
        );
        socket.write(
          'HTTP/1.1 200 OK\r\n'
          'Content-Type: text/event-stream\r\n'
          // 必须是 chunked + keep-alive，照抄真实推理服务的响应头。
          // 若改用 `Connection: close`，dart:io 知道连接不可复用，取消订阅时
          // 顺手就把 socket 收了 —— 那样即使实现里根本没有真正的中断，测试也会
          // 通过（已实测），于是这条断言就完全失去意义。
          'Transfer-Encoding: chunked\r\n'
          'Connection: keep-alive\r\n\r\n',
        );
        for (final event in events) {
          final size = utf8.encode(event).length.toRadixString(16);
          socket.write('$size\r\n$event\r\n');
          try {
            await socket.flush();
          } catch (_) {
            return;
          }
          if (gap > Duration.zero) await Future<void>.delayed(gap);
        }
        // 发完就沉默：不写结束 chunk、不关连接，模拟对端不再产出 token。
        if (silentAfter) return;
        socket.write('0\r\n\r\n');
        await socket.close();
      }),
    );
    return Uri.parse('http://127.0.0.1:${server.port}/v1');
  }

  group('取消：连接真的被关掉', () {
    test('取消后连接被对端观测到关闭，且不再有增量回调', () async {
      var serverSawClose = false;
      final endpoint = await rawSse(
        // 200 条、每条间隔 30ms，且永远不发 [DONE]。
        List.generate(200, (i) => delta('$i ')),
        gap: const Duration(milliseconds: 30),
        onClientClose: () => serverSawClose = true,
      );
      final chat = AiChat(baseUrl: endpoint.toString());
      final token = CancelToken();
      final seen = <String>[];

      final pending = chat.send(
        '讲个长故事',
        systemPrompt: 'p',
        onDelta: seen.add,
        cancelToken: token,
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(seen, isNotEmpty, reason: '取消之前应当已经收到一些增量');
      final countAtCancel = seen.length;

      final stopwatch = Stopwatch()..start();
      token.cancel(reason: 'user pressed stop');
      final r = await pending;
      stopwatch.stop();

      expect(r.status, CompletionStatus.cancelled);
      expect(r.speakable, isFalse);
      expect(r.speechText, isEmpty);
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(500),
        reason: '停止不该等服务端把 200 条发完',
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(seen.length, countAtCancel, reason: '取消之后不得再有增量回调');

      // 服务端观测到连接关闭，说明不是只在本地丢弃结果 —— 只暂停读取的话
      // 连接会一直留在 ESTABLISHED，对端仍在为一个没人要的回答干活。
      final waiting = Stopwatch()..start();
      while (!serverSawClose && waiting.elapsedMilliseconds < 3000) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(serverSawClose, isTrue, reason: '连接必须真的关闭，不能只在本地隔离');
    });

    test('服务端已经沉默时，取消同样立刻生效', () async {
      // 这条才是取消真正要防的情形。上一条里服务端每 30ms 发一个事件，读循环
      // 里那句取消检查顺手就生效了；一旦对端不再产出 token（推理卡住、显存被
      // 别的进程抢走、网关挂了），读取会一直挂着，只靠「下一个事件到达时检查」
      // 的实现会让停止永远不生效。
      var serverSawClose = false;
      final endpoint = await rawSse(
        [delta('嗯'), delta('……')],
        gap: const Duration(milliseconds: 20),
        silentAfter: true,
        onClientClose: () => serverSawClose = true,
      );
      final chat = AiChat(baseUrl: endpoint.toString());
      final token = CancelToken();

      final pending = chat.send(
        '在吗',
        systemPrompt: 'p',
        onDelta: (_) {},
        cancelToken: token,
      );

      // 等到服务端确实闭嘴了再按停止。
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final stopwatch = Stopwatch()..start();
      token.cancel(reason: 'user pressed stop');
      final r = await pending.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('取消没有中断读取：对端沉默后停止不生效'),
      );
      stopwatch.stop();

      expect(r.status, CompletionStatus.cancelled);
      expect(r.speakable, isFalse);
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(500),
        reason: '停止不能等下一个事件到达才生效，对端可能永远不再发数据',
      );

      final waiting = Stopwatch()..start();
      while (!serverSawClose && waiting.elapsedMilliseconds < 3000) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(serverSawClose, isTrue, reason: '沉默的连接也必须被关掉，不能挂着不放');
    });
  });

  group('本地无 key 语义', () {
    test('回环端点无 key 也算配置完成，且不带 Authorization 头', () async {
      final endpoint = await sse([delta('本地跑起来了'), stop, done]);
      final chat = AiChat(baseUrl: endpoint.toString(), model: 'kurisu-4b');

      expect(chat.connectionMode, AiConnectionMode.local);
      expect(chat.configured, isTrue, reason: '本地端点默认无鉴权');
      expect(chat.sendsAuthorization, isFalse);

      final r = await chat.send('喂', systemPrompt: 'p', onPreview: (_) {});

      expect(r.status, CompletionStatus.complete);
      expect(r.displayText, '本地跑起来了');
      expect(headers.single.value('authorization'), isNull,
          reason: '本地进程不该看到任何 key');
    });

    test('本地网关确实要鉴权时，显式配置的 key 仍然会发', () async {
      final endpoint = await sse([delta('ok'), stop, done]);
      final chat = AiChat(
        apiKey: 'gateway-key',
        baseUrl: endpoint.toString(),
        connectionMode: AiConnectionMode.local,
      );

      expect(chat.sendsAuthorization, isTrue);
      await chat.send('喂', systemPrompt: 'p', onPreview: (_) {});
      expect(headers.single.value('authorization'), 'Bearer gateway-key');
    });

    test('云端模式缺 key 时判为未配置，请求一次都不发出去', () async {
      final endpoint = await sse([delta('不该被调用'), stop, done]);
      final chat = AiChat(
        apiKey: '',
        baseUrl: endpoint.toString(),
        connectionMode: AiConnectionMode.cloud,
      );

      expect(chat.configured, isFalse);
      final r = await chat.send('喂', systemPrompt: 'p');

      expect(r.status, CompletionStatus.transportFailed);
      expect(r.detail, 'unconfigured');
      expect(hits, 0);
    });

    test('本地模式端点为空时不借用云端默认地址（INV-05）', () async {
      final chat = AiChat(
        baseUrl: '',
        connectionMode: AiConnectionMode.local,
        apiKey: 'cloud-key',
      );

      expect(chat.baseUrl, isEmpty, reason: '没配就是没配，不回落到 api.openai.com');
      expect(chat.configured, isFalse);

      // 已经连上过本地端点，之后端点被清空，同样不许回落。
      final endpoint = await sse([delta('x'), stop, done]);
      final live = AiChat(baseUrl: endpoint.toString());
      expect(live.configured, isTrue);
      live.updateConfig(baseUrl: '');
      expect(live.baseUrl, isEmpty);
      expect(live.configured, isFalse);
    });

    test('本地端点连不上时如实报失败，不改用云端', () async {
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close(force: true);

      final chat = AiChat(baseUrl: 'http://127.0.0.1:$deadPort/v1');
      final r = await chat.send('喂', systemPrompt: 'p', onPreview: (_) {});

      expect(r.status, CompletionStatus.transportFailed);
      expect(r.speakable, isFalse);
      expect(chat.baseUrl, 'http://127.0.0.1:$deadPort/v1');
      expect(chat.connectionMode, AiConnectionMode.local);
    });
  });

  group('取消：不发多余请求，不留半截轮次', () {
    test('请求前就取消的话，一个字节都不发出去', () async {
      final endpoint = await sse([delta('不该被调用'), stop, done]);
      final chat = AiChat(baseUrl: endpoint.toString());
      final token = CancelToken()..cancel();

      final r = await chat.send('喂', systemPrompt: 'p', cancelToken: token);

      expect(r.status, CompletionStatus.cancelled);
      expect(hits, 0);
    });

    test('取消的轮次不写进对话窗口', () async {
      final endpoint = await sse(
        List.generate(50, (i) => delta('$i ')),
        gap: const Duration(milliseconds: 30),
      );
      final chat = AiChat(baseUrl: endpoint.toString());
      final token = CancelToken();

      final pending = chat.send('喂', systemPrompt: 'p', onDelta: (_) {}, cancelToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      token.cancel();
      await pending;

      expect(chat.historyLength, 0,
          reason: '取消的轮次不该在上下文里留下一句没被回答的用户消息');
    });
  });

  group('三元组与完成判定', () {
    test('完整回复剥离标记后字幕与语音都干净', () async {
      final endpoint = await sse([
        delta('[23:4'),
        delta('1] 又熬夜'),
        delta('[[sticker:sh'),
        delta('ake]]睡吧。'),
        stop,
        done,
      ]);
      final chat = AiChat(baseUrl: endpoint.toString());
      final previews = <String>[];

      final r = await chat.send(
        '还没睡',
        systemPrompt: 'p',
        onPreview: previews.add,
      );

      expect(r.status, CompletionStatus.complete);
      expect(r.displayText, '又熬夜睡吧。');
      expect(r.speechText, '又熬夜睡吧。');
      expect(r.bubbleTime, '23:41');
      expect(r.stickers, ['shake']);
      expect(r.speakable, isTrue);
      // 跨 token 的半个标记不得在预览里闪出来。
      for (final p in previews) {
        expect(p, isNot(contains('[[')));
        expect(p, isNot(contains('sticker')));
        expect(p, isNot(matches(RegExp(r'\[\d'))));
      }
    });

    test('截断的回复可显示但不朗读，且不算完成（INV-04）', () async {
      final endpoint = await sse([
        delta('这个实验的关键在于'),
        'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\n',
        done,
      ]);
      final chat = AiChat(baseUrl: endpoint.toString());

      final r = await chat.send('说说', systemPrompt: 'p', onPreview: (_) {});

      expect(r.status, CompletionStatus.truncated);
      expect(r.detail, 'length');
      expect(r.displayText, '这个实验的关键在于');
      expect(r.speechText, isEmpty);
      expect(r.speakable, isFalse);
      expect(chat.lastRequestCompleted, isFalse);
      expect(chat.historyLength, 0);
    });

    test('malformed 事件不被当作完整正文', () async {
      final endpoint = await sse([delta('half'), 'data: not-json\n\n', done]);
      final chat = AiChat(baseUrl: endpoint.toString());

      final r = await chat.send('喂', systemPrompt: 'p', onPreview: (_) {});

      expect(r.status, CompletionStatus.malformed);
      expect(r.detail, 'malformed_event');
      expect(r.speakable, isFalse);
      expect(chat.lastRequestCompleted, isFalse);
    });

    test('供应商 error 事件判为 malformed', () async {
      final endpoint = await sse([
        'data: {"error":{"message":"context too long"}}\n\n',
        done,
      ]);
      final chat = AiChat(baseUrl: endpoint.toString());

      final r = await chat.send('喂', systemPrompt: 'p', onPreview: (_) {});

      expect(r.status, CompletionStatus.malformed);
      expect(r.detail, 'provider_error');
      expect(r.speakable, isFalse);
    });

    test('独立的 reasoning 字段不进字幕也不进语音', () async {
      final endpoint = await sse([
        'data: {"choices":[{"delta":{"reasoning_content":"用户在试探我"}}]}\n\n',
        delta('怎么了？'),
        stop,
        done,
      ]);
      final chat = AiChat(baseUrl: endpoint.toString());

      final r = await chat.send('喂', systemPrompt: 'p', onPreview: (_) {});

      expect(r.displayText, '怎么了？');
      expect(r.speechText, '怎么了？');
    });

    test('流中断（没有 DONE 也没有 stop）不算完成', () async {
      final endpoint = await sse([delta('说到一半')]);
      final chat = AiChat(baseUrl: endpoint.toString());

      final r = await chat.send('喂', systemPrompt: 'p', onPreview: (_) {});

      expect(r.status, CompletionStatus.transportFailed);
      expect(r.detail, 'network_closed');
      expect(r.speakable, isFalse);
    });
  });

  group('对话窗口与记忆权威不冲突', () {
    test('完成的轮次留下一问一答', () async {
      final endpoint = await sse([delta('嗯。'), stop, done]);
      final chat = AiChat(baseUrl: endpoint.toString());

      await chat.send('在吗', systemPrompt: 'p', onPreview: (_) {});

      expect(chat.historyLength, 2);
      expect(chat.historySnapshot.first['role'], 'user');
      expect(chat.historySnapshot.last['content'], '嗯。');
    });

    test('落进窗口的是剥离标记后的正文，不是原始串', () async {
      final endpoint = await sse([
        delta('[08:30]早啊[[sticker:tap_body]]'),
        stop,
        done,
      ]);
      final chat = AiChat(baseUrl: endpoint.toString());

      await chat.send('早', systemPrompt: 'p', onPreview: (_) {});

      expect(chat.historySnapshot.last['content'], '早啊');
    });

    test('换模型后不沿用旧对话窗口', () async {
      final endpoint = await sse([delta('嗯。'), stop, done]);
      final chat = AiChat(baseUrl: endpoint.toString());
      await chat.send('在吗', systemPrompt: 'p', onPreview: (_) {});
      expect(chat.historyLength, 2);

      chat.updateConfig(model: 'another-model');

      expect(chat.historyLength, 0,
          reason: '换了模型就不该让它接着扮演上一个模型说过的话');
    });
  });
}
