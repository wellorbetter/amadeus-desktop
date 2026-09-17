import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/local_service_registry.dart';
import 'package:timepet/services/pet_config.dart';

/// U2 自检：本地服务注册表。
///
/// 用真的 HttpServer 绑在 127.0.0.1 上验证，不用 mock —— 端点校验、重定向、
/// 端口占用这几件事的缺陷只会在真实 socket 行为里暴露。
///
/// 对应 Spec §5.2（六态健康、ownership、回环约束、不按端口杀进程）、
/// INV-05（本地失败不切云；端点必须是回环）、INV-08（降级要显式）。
void main() {
  setUpAll(() {
    // 避免测试往 flutter_tester 所在目录写 timepet.log。
    PetConfig.instance.logEnabled = false;
  });

  /// 起一个本地服务，返回它的 base 端点。
  Future<Uri> serve(
    Future<void> Function(HttpRequest req) handler, {
    String host = '127.0.0.1',
  }) async {
    final server = await HttpServer.bind(host, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      try {
        await handler(req);
      } finally {
        await req.response.close().catchError((_) {});
      }
    });
    return Uri.parse('http://$host:${server.port}/v1');
  }

  /// 一个 OpenAI 兼容的假服务。[onBody] 收到探测请求的原始 body。
  Future<Uri> serveOpenAi({
    void Function(String body)? onBody,
    int status = 200,
    String? rawBody,
  }) => serve((req) async {
    final body = await utf8.decoder.bind(req).join();
    onBody?.call(body);
    req.response.statusCode = status;
    if (rawBody != null) {
      req.response.write(rawBody);
      return;
    }
    req.response.headers.contentType = ContentType.json;
    req.response.write(
      jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'pong'},
            'finish_reason': 'stop',
          },
        ],
      }),
    );
  });

  /// 找一个确定没人监听的端口：绑上再立刻放掉。
  Future<Uri> freePort() async {
    final probe = await HttpServer.bind('127.0.0.1', 0);
    final port = probe.port;
    await probe.close(force: true);
    return Uri.parse('http://127.0.0.1:$port/v1');
  }

  group('端点校验：只认回环', () {
    Future<String?> reject(String raw) async =>
        (await LocalServiceRegistry.validateEndpoint(raw)).reason;

    test('回环字面量通过', () async {
      for (final ok in [
        'http://127.0.0.1:8080/v1',
        'http://127.0.0.1:8080',
        'https://127.0.0.2:9000/v1',
        'http://[::1]:8080/v1',
      ]) {
        final check = await LocalServiceRegistry.validateEndpoint(ok);
        expect(check.ok, isTrue, reason: '$ok 应当通过：${check.reason}');
      }
    });

    test('localhost 通过，但依据是解析结果而不是这个名字', () async {
      expect((await LocalServiceRegistry.validateEndpoint(
        'http://localhost:8080/v1',
      )).ok, isTrue);
      // 带 localhost 字样但主机名不是回环的，必须拒绝。
      expect(await reject('http://localhost.evil.com:8080/v1'), isNotNull);
      expect(await reject('http://my-localhost:8080/v1'), isNotNull);
    });

    test('0.0.0.0 被单独指出：那是监听所有网卡，不是回环', () async {
      final reason = await reject('http://0.0.0.0:8080/v1');
      expect(reason, contains('所有网卡'));
      expect(await reject('http://[::]:8080/v1'), isNotNull);
    });

    test('局域网地址、公网域名、非 http 协议一律拒绝', () async {
      expect(await reject('http://192.168.1.5:8080/v1'), contains('回环'));
      expect(await reject('http://10.0.0.3:8080/v1'), contains('回环'));
      expect(await reject('https://api.deepseek.com/v1'), contains('回环'));
      expect(await reject('ftp://127.0.0.1/v1'), contains('http'));
      expect(await reject('not a url at all'), isNotNull);
      expect(await reject('   '), '未配置端点');
    });
  });

  group('健康探测六态', () {
    late LocalServiceRegistry reg;
    setUp(() => reg = LocalServiceRegistry());

    Future<ServiceStatus> check(Uri endpoint) => reg.refresh(
      ServiceKind.llm,
      endpoint: endpoint.toString(),
      ownership: ServiceOwnership.external,
    );

    test('端口空闲 -> unavailable', () async {
      final s = await check(await freePort());
      expect(s.health, ServiceHealth.unavailable);
      expect(s.canSendConversation, isFalse);
    });

    test('未配置端点 -> unconfigured', () async {
      final s = await reg.refresh(
        ServiceKind.llm,
        endpoint: '',
        ownership: ServiceOwnership.external,
      );
      expect(s.health, ServiceHealth.unconfigured);
      expect(s.canSendConversation, isFalse);
    });

    test('本应用的服务 -> ready，并记录探测耗时', () async {
      final s = await check(await serveOpenAi());
      expect(s.health, ServiceHealth.ready);
      expect(s.canSendConversation, isTrue);
      expect(s.latency, isNotNull);
    });

    test('探测样本不含任何个人信息', () async {
      String? captured;
      await check(await serveOpenAi(onBody: (b) => captured = b));

      expect(captured, isNotNull);
      final sent = jsonDecode(captured!) as Map<String, dynamic>;
      final messages = (sent['messages'] as List).cast<Map>();
      expect(messages.single['content'], LocalServiceRegistry.probeSample);
      expect(messages.single['role'], 'user');
      // 探测不是对话：不带系统人设、不带历史、不带记忆。
      expect(messages, hasLength(1));
      expect(sent.containsKey('system'), isFalse);
      expect(sent['max_tokens'], 1);
      expect(sent['stream'], isFalse);
    });

    test('端口被未知服务占用 -> unavailable，且拒绝发送真实对话内容', () async {
      final html = await serve((req) async {
        req.response.headers.contentType = ContentType.html;
        req.response.write('<html><body>某个无关的本地服务</body></html>');
      });
      final s = await check(html);

      expect(s.health, ServiceHealth.unavailable);
      expect(s.detail, contains('未知服务'));
      expect(s.canSendConversation, isFalse,
          reason: '不知道对面是什么，就不能把用户的话发过去');
      expect(reg.canSendConversation(ServiceKind.llm), isFalse);
    });

    test('返回 200 JSON 但不是对话补全格式 -> unavailable', () async {
      final s = await check(
        await serveOpenAi(rawBody: jsonEncode({'status': 'ok'})),
      );
      expect(s.health, ServiceHealth.unavailable);
      expect(s.detail, contains('对话补全'));
    });

    test('服务在线但权重未加载 -> starting，不是 ready', () async {
      final s = await check(await serveOpenAi(status: 503));
      expect(s.health, ServiceHealth.starting);
      expect(s.canSendConversation, isFalse);
      expect(s.detail, contains('权重未就绪'));
    });

    test('限流 -> busy', () async {
      final s = await check(await serveOpenAi(status: 429));
      expect(s.health, ServiceHealth.busy);
      expect(s.canSendConversation, isFalse);
    });

    test('探测超时 -> degraded，而不是一直挂着', () async {
      final slow = await serve((req) async {
        await Future<void>.delayed(const Duration(seconds: 30));
      });
      final quick = LocalServiceRegistry(
        probeTimeout: const Duration(milliseconds: 300),
      );
      final s = await quick.refresh(
        ServiceKind.llm,
        endpoint: slow.toString(),
        ownership: ServiceOwnership.external,
      );
      expect(s.health, ServiceHealth.degraded);
      expect(s.detail, contains('超时'));
    });

    test('不跟随重定向：重定向目标一次都不会被访问', () async {
      var redirectTargetHit = 0;
      final target = await serve((req) async {
        redirectTargetHit++;
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'choices': [
              {'message': {'content': 'x'}},
            ],
          }),
        );
      });
      final redirector = await serve((req) async {
        req.response.statusCode = 302;
        req.response.headers.set(HttpHeaders.locationHeader, target.toString());
      });

      final s = await check(redirector);
      expect(s.health, ServiceHealth.unavailable);
      expect(s.detail, contains('不跟随'));
      expect(redirectTargetHit, 0);
    });

    test('ASR/TTS 没有最小能力探测时只能是 degraded，不许自称 ready', () async {
      final endpoint = await serveOpenAi();
      for (final kind in [ServiceKind.asr, ServiceKind.tts]) {
        final s = await reg.refresh(
          kind,
          endpoint: endpoint.toString(),
          ownership: ServiceOwnership.external,
        );
        expect(s.health, ServiceHealth.degraded,
            reason: '${kind.name}：端口连得上不等于能干活');
        expect(s.detail, contains('最小能力探测'));
      }
    });

    test('注入了能力探测后才能到 ready', () async {
      reg.setProber(
        ServiceKind.tts,
        (uri) async => const ProbeOutcome(
          ServiceHealth.ready,
          '合成了一段 100ms 静音',
          latency: Duration(milliseconds: 42),
        ),
      );
      final s = await reg.refresh(
        ServiceKind.tts,
        endpoint: 'http://127.0.0.1:9880',
        ownership: ServiceOwnership.external,
      );
      expect(s.health, ServiceHealth.ready);
      expect(s.latency, const Duration(milliseconds: 42));
    });
  });

  group('ownership：只停自己启动的进程', () {
    test('external 服务拒绝停止，且进程照样活着', () async {
      final reg = LocalServiceRegistry();
      var stillServing = 0;
      final endpoint = await serveOpenAi(onBody: (_) => stillServing++);

      await reg.refresh(
        ServiceKind.llm,
        endpoint: endpoint.toString(),
        ownership: ServiceOwnership.external,
      );
      expect(await reg.stop(ServiceKind.llm), isFalse);
      expect(reg.statusOf(ServiceKind.llm).detail, contains('不由本应用启停'));

      // 停止被拒绝之后，服务仍然可用。
      final after = await reg.refresh(
        ServiceKind.llm,
        endpoint: endpoint.toString(),
        ownership: ServiceOwnership.external,
      );
      expect(after.health, ServiceHealth.ready);
      expect(stillServing, 2);
    });

    test('managed 但没有句柄时拒绝停止，不按端口找进程', () async {
      final reg = LocalServiceRegistry();
      await reg.refresh(
        ServiceKind.llm,
        endpoint: 'http://127.0.0.1:8080',
        ownership: ServiceOwnership.managed,
      );
      expect(await reg.stop(ServiceKind.llm), isFalse);
      expect(reg.statusOf(ServiceKind.llm).detail, contains('不按端口杀进程'));
    });

    test(
      '登记过句柄的进程可以被停止，且退出后状态变为 unavailable',
      () async {
        final reg = LocalServiceRegistry();
        final proc = await Process.start('sleep', ['30']);
        reg.registerManaged(ServiceKind.dataBridge, proc);

        expect(
          reg.statusOf(ServiceKind.dataBridge).ownership,
          ServiceOwnership.managed,
        );
        expect(
          reg.statusOf(ServiceKind.dataBridge).health,
          ServiceHealth.starting,
        );

        expect(await reg.stop(ServiceKind.dataBridge), isTrue);
        expect(
          reg.statusOf(ServiceKind.dataBridge).health,
          ServiceHealth.unavailable,
        );
        // 再停一次是拒绝，不是重复杀。
        expect(await reg.stop(ServiceKind.dataBridge), isFalse);
      },
      skip: Platform.isWindows ? '进程停止在类 Unix 上验证（sleep 命令）' : null,
    );

    test('加载耗时与单次探测耗时分开记录', () async {
      final reg = LocalServiceRegistry();
      final proc = await Process.start('sleep', ['30']);
      addTearDown(proc.kill);
      reg.registerManaged(ServiceKind.llm, proc);

      // 模拟权重加载：先 503，稍后才 ready。
      var loaded = false;
      reg.setProber(ServiceKind.llm, (uri) async {
        if (!loaded) {
          return const ProbeOutcome(ServiceHealth.starting, '权重未就绪');
        }
        return const ProbeOutcome(
          ServiceHealth.ready,
          '最小推理探测通过',
          latency: Duration(milliseconds: 12),
        );
      });

      var s = await reg.refresh(
        ServiceKind.llm,
        endpoint: 'http://127.0.0.1:8080',
        ownership: ServiceOwnership.managed,
      );
      expect(s.health, ServiceHealth.starting);
      expect(s.loadElapsed, isNull);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      loaded = true;
      s = await reg.refresh(
        ServiceKind.llm,
        endpoint: 'http://127.0.0.1:8080',
        ownership: ServiceOwnership.managed,
      );
      expect(s.health, ServiceHealth.ready);
      expect(s.latency, const Duration(milliseconds: 12));
      expect(s.loadElapsed, isNotNull);
      expect(
        s.loadElapsed!.inMilliseconds,
        greaterThan(s.latency!.inMilliseconds),
        reason: '一次 60ms 的加载不该被说成一次 12ms 的推理',
      );
    }, skip: Platform.isWindows ? '进程句柄在类 Unix 上验证（sleep 命令）' : null);

    test('已登记的服务即使配置写着 external，也按 managed 处理', () async {
      final reg = LocalServiceRegistry();
      final proc = await Process.start('sleep', ['30']);
      addTearDown(proc.kill);
      reg.registerManaged(ServiceKind.llm, proc);

      final s = await reg.refresh(
        ServiceKind.llm,
        endpoint: await freePort().then((u) => u.toString()),
        ownership: ServiceOwnership.external,
      );
      expect(s.ownership, ServiceOwnership.managed,
          reason: '句柄在我们手里，就得由我们负责停止');
    }, skip: Platform.isWindows ? '进程句柄在类 Unix 上验证（sleep 命令）' : null);

    test(
      '输出量大的服务不会因为管道写满而卡死',
      () async {
        final reg = LocalServiceRegistry();
        // 保留句柄意味着 stdout/stderr 是真管道（约 64KB 缓冲）。
        // 没人读的话，这个进程写到一半就永久阻塞，永远等不到 exitCode。
        final proc = await Process.start('sh', [
          '-c',
          'i=0; while [ \$i -lt 4000 ]; do '
              'echo "bridge line \$i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; '
              'i=\$((i+1)); done; exit 0',
        ]);
        addTearDown(proc.kill);
        reg.registerManaged(ServiceKind.dataBridge, proc);

        final code = await proc.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw StateError('进程被管道堵死了：输出没有被读走'),
        );
        expect(code, 0);
        // 进程退出后状态如实反映，而不是停留在 starting。
        expect(
          reg.statusOf(ServiceKind.dataBridge).health,
          ServiceHealth.unavailable,
        );
      },
      skip: Platform.isWindows ? '管道行为在类 Unix 上验证（sh 脚本）' : null,
    );
  });
}
