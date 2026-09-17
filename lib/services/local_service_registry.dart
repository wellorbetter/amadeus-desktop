import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'pet_logger.dart';

/// 本地推理服务的种类。
enum ServiceKind {
  /// 对话模型。
  llm,

  /// 语音识别。
  asr,

  /// 语音合成。
  tts,

  /// TimeTrace 数据桥（只读 time.db，提供聚合数据）。
  dataBridge,
}

/// 服务由谁负责启停。
///
/// 这不是显示用的标签，而是权限：本应用只允许停止自己启动的进程。
enum ServiceOwnership {
  /// 本应用启动、持有进程句柄、可以停止。
  managed,

  /// 用户自己起的。本应用只连接与观察，绝不启停。
  external,
}

/// 服务健康状态（Spec §5.2 六态）。
enum ServiceHealth {
  /// 没配端点。
  unconfigured,

  /// 进程在起、或权重在加载。
  starting,

  /// 连得上，且**最小推理探测成功**。只有这个状态允许发送真实对话内容。
  ready,

  /// 在忙（限流/队列满）。
  busy,

  /// 连得上但不能正常干活（权重未加载、返回异常、能力探测缺失）。
  degraded,

  /// 连不上，或端口被未知服务占用。
  unavailable,
}

/// 端点校验结果。
class EndpointCheck {
  const EndpointCheck._(this.uri, this.reason);

  const EndpointCheck.ok(Uri uri) : this._(uri, null);
  const EndpointCheck.rejected(String reason) : this._(null, reason);

  final Uri? uri;
  final String? reason;

  bool get ok => uri != null;
}

/// 一次健康探测的结果。
class ProbeOutcome {
  const ProbeOutcome(this.health, this.detail, {this.latency});

  final ServiceHealth health;
  final String detail;

  /// 探测往返耗时。加载/预热耗时单独记在 [ServiceStatus.loadElapsed]。
  final Duration? latency;
}

typedef ServiceProber = Future<ProbeOutcome> Function(Uri endpoint);

/// 一个服务当前的可用性快照。
class ServiceStatus {
  ServiceStatus({
    required this.kind,
    required this.ownership,
    this.endpoint,
    this.health = ServiceHealth.unconfigured,
    this.detail = '未探测',
    this.latency,
    this.loadElapsed,
    this.checkedAt,
  });

  final ServiceKind kind;
  ServiceOwnership ownership;
  Uri? endpoint;
  ServiceHealth health;
  String detail;
  Duration? latency;

  /// 从「开始启动」到「探测成功」的耗时。与单次探测往返分开显示，
  /// 否则会把一次 40 秒的权重加载说成一次 40 秒的推理。
  Duration? loadElapsed;
  DateTime? checkedAt;

  /// 是否允许把真实对话内容发给它。
  ///
  /// 只有 `ready` 允许。端口被未知服务占用时必须是 false ——
  /// 否则用户的对话内容会被发给一个不知道是什么的进程。
  bool get canSendConversation => health == ServiceHealth.ready;

  @override
  String toString() =>
      '${kind.name}[${ownership.name}] ${health.name} '
      '${endpoint ?? '-'} $detail'
      '${latency == null ? '' : ' probe=${latency!.inMilliseconds}ms'}'
      '${loadElapsed == null ? '' : ' load=${loadElapsed!.inMilliseconds}ms'}';
}

/// 本地服务注册表。
///
/// 三件事：校验端点只指向回环、探测健康、只停止自己启动的进程。
/// 明确**不做**的事：不按端口查找并杀进程 —— 那会杀掉用户自己起的、
/// 甚至完全无关的程序。停止只能通过本应用持有的进程句柄进行。
class LocalServiceRegistry {
  LocalServiceRegistry({
    Map<ServiceKind, ServiceProber>? probers,
    this.probeTimeout = const Duration(seconds: 5),
  }) : _probers = {...?probers};

  final Map<ServiceKind, ServiceProber> _probers;
  final Duration probeTimeout;

  final Map<ServiceKind, ServiceStatus> _status = {};
  final Map<ServiceKind, Process> _managed = {};
  final Map<ServiceKind, DateTime> _startedAt = {};

  /// 探测用的中性样本。**不含任何个人信息**：探测不是对话，
  /// 不能拿用户的真实输入或记忆去试一个还不知道是什么的服务。
  static const String probeSample = 'ping';

  ServiceStatus statusOf(ServiceKind kind) =>
      _status[kind] ??
      ServiceStatus(kind: kind, ownership: ServiceOwnership.external);

  List<ServiceStatus> get all =>
      ServiceKind.values.map(statusOf).toList(growable: false);

  bool canSendConversation(ServiceKind kind) =>
      statusOf(kind).canSendConversation;

  void setProber(ServiceKind kind, ServiceProber prober) =>
      _probers[kind] = prober;

  /// 登记一个由本应用启动的进程，使它可被停止。
  ///
  /// 不登记就等于放任：原来的数据桥用 detached 方式启动、不保留句柄，
  /// 之后既不能确认身份也不能停止（只能按端口杀，而那是禁止的）。
  ///
  /// 同时**必须**把 stdout/stderr 读干。保留句柄意味着这两条是真管道：
  /// 没人读，管道满了子进程下一次写日志就会永久阻塞 —— 表现为服务莫名卡死，
  /// 而且看起来完全不像是我们造成的。
  void registerManaged(ServiceKind kind, Process process) {
    _managed[kind] = process;
    _startedAt[kind] = DateTime.now();
    _drain(kind, process);
    final s = statusOf(kind);
    s.ownership = ServiceOwnership.managed;
    s.health = ServiceHealth.starting;
    s.detail = '已启动，等待就绪';
    _status[kind] = s;
    PetLog.i('svc: ${kind.name} managed pid=${process.pid}');
    unawaited(
      process.exitCode.then((code) {
        if (_managed[kind] != process) return;
        _managed.remove(kind);
        final cur = statusOf(kind);
        cur.health = ServiceHealth.unavailable;
        cur.detail = '进程已退出（code=$code）';
        _status[kind] = cur;
        PetLog.w('svc: ${kind.name} exited code=$code');
      }),
    );
  }

  /// 读干子进程的两条输出管道，并把内容记入日志。
  ///
  /// 只记服务自己的启动/错误输出，不含对话内容；单行截断，避免一个刷屏的
  /// 服务把日志文件写爆。
  void _drain(ServiceKind kind, Process process) {
    void pump(Stream<List<int>> src, void Function(String) sink) {
      src
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              final text = line.trimRight();
              if (text.isEmpty) return;
              sink(
                'svc: ${kind.name} '
                '${text.length > 200 ? '${text.substring(0, 200)}…' : text}',
              );
            },
            onError: (Object e) => PetLog.w('svc: ${kind.name} 输出读取失败：$e'),
            cancelOnError: true,
          );
    }

    pump(process.stdout, PetLog.i);
    pump(process.stderr, PetLog.w);
  }

  /// 停止服务。
  ///
  /// 只能停 `managed` 且句柄仍在的服务。`external` 一律拒绝：
  /// 用户自己起的进程不由本应用生杀。返回 false 时 [ServiceStatus.detail]
  /// 说明原因。
  Future<bool> stop(ServiceKind kind) async {
    final s = statusOf(kind);
    if (s.ownership != ServiceOwnership.managed) {
      s.detail = '外部服务不由本应用启停';
      _status[kind] = s;
      PetLog.i('svc: ${kind.name} stop refused (external)');
      return false;
    }
    final proc = _managed.remove(kind);
    if (proc == null) {
      s.detail = '没有本应用持有的进程句柄，不按端口杀进程';
      _status[kind] = s;
      PetLog.w('svc: ${kind.name} stop refused (no handle)');
      return false;
    }
    proc.kill();
    await proc.exitCode;
    s.health = ServiceHealth.unavailable;
    s.detail = '已停止';
    _status[kind] = s;
    PetLog.i('svc: ${kind.name} stopped pid=${proc.pid}');
    return true;
  }

  /// 刷新一个服务的健康状态。
  Future<ServiceStatus> refresh(
    ServiceKind kind, {
    required String endpoint,
    required ServiceOwnership ownership,
  }) async {
    final s = statusOf(kind);
    s.ownership = _managed.containsKey(kind)
        ? ServiceOwnership.managed
        : ownership;
    s.checkedAt = DateTime.now();

    final check = await validateEndpoint(endpoint);
    if (!check.ok) {
      s.endpoint = null;
      s.latency = null;
      s.health = endpoint.trim().isEmpty
          ? ServiceHealth.unconfigured
          : ServiceHealth.unavailable;
      s.detail = check.reason!;
      _status[kind] = s;
      PetLog.i('svc: ${kind.name} endpoint rejected: ${check.reason}');
      return s;
    }

    s.endpoint = check.uri;
    final prober = _probers[kind] ?? _defaultProber(kind);
    ProbeOutcome outcome;
    try {
      outcome = await prober(check.uri!).timeout(
        probeTimeout,
        onTimeout: () => ProbeOutcome(
          ServiceHealth.degraded,
          '探测超时（>${probeTimeout.inSeconds}s）',
        ),
      );
    } catch (e) {
      outcome = ProbeOutcome(ServiceHealth.unavailable, '探测失败：$e');
    }
    s.health = outcome.health;
    s.detail = outcome.detail;
    s.latency = outcome.latency;
    if (outcome.health == ServiceHealth.ready) {
      final started = _startedAt[kind];
      if (started != null) {
        s.loadElapsed = DateTime.now().difference(started);
        _startedAt.remove(kind);
      }
    }
    _status[kind] = s;
    PetLog.i('svc: $s');
    return s;
  }

  /// 校验端点。
  ///
  /// 只接受回环。判定依据是**解析出的地址**，不是 URL 里有没有 `localhost`
  /// 字样 —— 那种检查可以用 `localhost.evil.com` 之类的名字绕过。
  /// 除回环字面量与 `localhost` 之外的主机名一律拒绝，即使它恰好解析到回环
  /// （避免 DNS 重绑定把「本地服务」指向外部控制的地址）。
  static Future<EndpointCheck> validateEndpoint(String raw) async {
    final text = raw.trim();
    if (text.isEmpty) return const EndpointCheck.rejected('未配置端点');
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return const EndpointCheck.rejected('端点不是合法 URL');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return EndpointCheck.rejected('端点协议必须是 http/https，收到 ${uri.scheme}');
    }
    final host = uri.host;
    final literal = InternetAddress.tryParse(host);
    if (literal != null) {
      if (literal.isLoopback) return EndpointCheck.ok(uri);
      // 0.0.0.0 / :: 是「监听所有网卡」的地址：既不是回环，
      // 也意味着服务对局域网敞开。明确单列，因为它最容易被误当成本地。
      if (host == '0.0.0.0' || host == '::') {
        return EndpointCheck.rejected('$host 是监听所有网卡的地址，不是回环');
      }
      return EndpointCheck.rejected('$host 不是回环地址');
    }
    if (host != 'localhost') {
      return EndpointCheck.rejected('$host 不是回环地址');
    }
    // localhost 也要实际解析确认，而不是认这个名字。
    try {
      final addrs = await InternetAddress.lookup(host);
      if (addrs.isEmpty) {
        return const EndpointCheck.rejected('localhost 无法解析');
      }
      if (addrs.any((a) => !a.isLoopback)) {
        return const EndpointCheck.rejected('localhost 解析到了非回环地址');
      }
      return EndpointCheck.ok(uri);
    } catch (e) {
      return EndpointCheck.rejected('localhost 解析失败：$e');
    }
  }

  ServiceProber _defaultProber(ServiceKind kind) {
    if (kind == ServiceKind.llm) return probeOpenAiCompatible;
    // ASR / TTS / 数据桥的最小能力探测属于各自的单元。
    // 在那之前不允许判定 ready：Spec §5.2 要求 ready 必须包含一次最小推理探测，
    // 「端口连得上」不等于「能干活」。
    return (uri) async => ProbeOutcome(
      ServiceHealth.degraded,
      '缺少最小能力探测，不判定为 ready',
    );
  }

  /// OpenAI 兼容端点的最小推理探测。
  ///
  /// 用固定中性样本发一次极短的非流式请求，据响应形状判断这到底是不是
  /// 我们要的服务。不跟随重定向。
  static Future<ProbeOutcome> probeOpenAiCompatible(Uri endpoint) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    final started = DateTime.now();
    try {
      final req = await client.postUrl(
        endpoint.replace(
          path: '${endpoint.path.replaceFirst(RegExp(r'/+$'), '')}'
              '/chat/completions',
        ),
      );
      // 本地服务默认无鉴权：不带 Authorization 头。
      req.followRedirects = false;
      req.headers.contentType = ContentType.json;
      req.add(
        utf8.encode(
          jsonEncode({
            'messages': [
              {'role': 'user', 'content': probeSample},
            ],
            'max_tokens': 1,
            'stream': false,
          }),
        ),
      );
      final resp = await req.close();
      final latency = DateTime.now().difference(started);
      final body = await resp.transform(utf8.decoder).join();

      // 不能用 resp.isRedirect 判断：dart:io 只对 GET/HEAD 认重定向状态码，
      // 对 POST 恒为 false，302 会被误当成普通 HTTP 错误。
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        return ProbeOutcome(
          ServiceHealth.unavailable,
          '端点返回重定向到 ${resp.headers.value(HttpHeaders.locationHeader)}，不跟随',
          latency: latency,
        );
      }
      if (resp.statusCode == 429) {
        return ProbeOutcome(ServiceHealth.busy, '服务限流中', latency: latency);
      }
      if (resp.statusCode == 503) {
        return ProbeOutcome(
          ServiceHealth.starting,
          '服务在线，权重未就绪',
          latency: latency,
        );
      }
      if (resp.statusCode != 200) {
        return ProbeOutcome(
          ServiceHealth.degraded,
          'HTTP ${resp.statusCode}',
          latency: latency,
        );
      }
      // 200 不代表就是我们要的服务：端口可能被完全无关的程序占用。
      Object? decoded;
      try {
        decoded = jsonDecode(body);
      } catch (_) {
        return ProbeOutcome(
          ServiceHealth.unavailable,
          '端口被未知服务占用（响应不是 JSON）',
          latency: latency,
        );
      }
      if (decoded is! Map<String, dynamic> || decoded['choices'] is! List) {
        return ProbeOutcome(
          ServiceHealth.unavailable,
          '端口被未知服务占用（响应不是对话补全格式）',
          latency: latency,
        );
      }
      return ProbeOutcome(ServiceHealth.ready, '最小推理探测通过', latency: latency);
    } on SocketException catch (e) {
      return ProbeOutcome(ServiceHealth.unavailable, '连不上：${e.osError?.message ?? e.message}');
    } catch (e) {
      return ProbeOutcome(ServiceHealth.unavailable, '探测失败：$e');
    } finally {
      client.close(force: true);
    }
  }
}
