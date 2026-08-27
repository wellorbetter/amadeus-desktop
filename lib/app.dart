import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'services/agent_context.dart';
import 'services/ai_chat.dart';
import 'services/avatar_controller.dart';
import 'services/pet_config.dart';
import 'services/pet_db.dart';
import 'services/pet_logger.dart';
import 'services/pet_memory.dart';
import 'services/pet_model.dart';
import 'services/pet_soul.dart';
import 'services/pet_secret_store.dart';
import 'services/pet_window.dart';
import 'services/trigger_engine.dart';
import 'services/tt_api.dart';
import 'ui/bubble.dart';
import 'ui/amadeus_theme.dart';
import 'ui/input_bar.dart';

/// Amadeus personal desktop agent: observation + memory + initiative + avatar.
class AmadeusApp extends StatelessWidget {
  const AmadeusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Amadeus',
      theme: AmadeusTheme.dark(),
      home: const PetHome(),
    );
  }
}

class PetHome extends StatefulWidget {
  const PetHome({super.key});

  @override
  State<PetHome> createState() => _PetHomeState();
}

class _PetHomeState extends State<PetHome> {
  final AvatarController _avatar = AvatarController();
  final TtApi _tt = TtApi();
  late final TriggerEngine _triggers = TriggerEngine(tt: _tt);
  late final AiChat _ai;

  String _bubbleText = '正在加载…';
  bool _bubbleVisible = false;
  bool _typing = false;
  bool _aiReady = false;
  bool _webviewReady = false;
  bool _inputVisible = false;
  Offset? _petMenuAt; // 桌宠右键菜单锚点（页面内坐标 CSS px）
  bool _firstFitDone = false;
  bool _fitBusy = false; // 贴合上报并发保护（多拍上报时串行处理）
  bool _greetDone = false;
  DateTime? _lastAuditAt; // 记忆审核节流
  bool _sleeping = false; // 空闲休眠中（省 token：暂停主动对话/记忆审核）
  bool _greetDeferred = false; // 启动问候是否因休眠被推迟
  Timer? _bubbleTimer;
  Timer? _bubbleUpdateTimer;
  String _queuedBubbleText = '';
  Timer? _inputHideTimer;
  Timer? _configTimer; // 配置热生效轮询：检测 config.json 变化后应用
  double? _lastModelScale;
  // 区域诊断：记录每个绘制区域的实际位置/大小，便于排查布局错位
  final GlobalKey _webviewKey = GlobalKey();
  final GlobalKey _bubbleKey = GlobalKey();
  final GlobalKey _inputKey = GlobalKey();

  bool get _aiActive => _ai.configured && PetConfig.instance.aiEnabled;

  @override
  void initState() {
    super.initState();
    PetConfig.instance.load();
    PetMemory.instance.load();
    PetSoul.instance.load();
    final cfg = PetConfig.instance;
    _ai = AiChat(
      apiKey: cfg.aiApiKey.isEmpty ? null : cfg.aiApiKey,
      baseUrl: cfg.aiBaseUrl,
      model: cfg.aiModel,
      temperature: cfg.aiTemperature,
      maxTokens: cfg.aiMaxTokens,
    );
    _aiReady = _aiActive;
    _lastModelScale = cfg.modelScale; // 记录初始缩放，供设置变更时对比是否需重新贴合窗口
    final dpr =
        WidgetsBinding
            .instance
            .platformDispatcher
            .views
            .firstOrNull
            ?.devicePixelRatio ??
        1.0;
    PetLog.i(
      'app: initState aiReady=$_aiReady base=${cfg.aiBaseUrl} model=${cfg.aiModel} flutterDpr=$dpr',
    );

    // 交互链路：点桌宠 / 托盘「聊两句」-> 弹出聊天框
    _avatar.onUserTap = _showInput;
    _avatar.onUserMenu = _showPetMenu;
    PetWindow.onShowChat = _showInput;
    // 托盘「设置」-> 打开独立设置窗口
    PetWindow.onOpenSettings = PetWindow.openSettingsWindow;
    // 模型就绪后按实际画布尺寸贴合窗口（启动一次）
    _avatar.onModelFit = (x, y, w, h, shrink) =>
        _autoFitToModel(x, y, w, h, shrink: shrink);
    // 主动链路：数据 -> 触发引擎 -> AI -> 气泡
    _triggers.onProactive = _proactive;
    _triggers.canProactivelySpeak = () => mounted && !_typing && _aiActive;
    // 休眠省电：空闲休眠时暂停一切 LLM 调用，唤醒后自然问候
    _triggers.onSleepChanged = _onSleepChanged;
    // 设置窗口保存配置后，通过跨窗口通道通知桌宠热生效
    const WindowMethodChannel(
      'pet',
      mode: ChannelMode.unidirectional,
    ).setMethodCallHandler((call) async {
      if (call.method == 'config-changed') {
        await _onSettingsChanged();
      } else if (call.method == 'restart') {
        await Process.start(
          Platform.resolvedExecutable,
          [],
          mode: ProcessStartMode.detached,
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await windowManager.destroy();
      }
    });
    // 配置热生效：设置窗口把改动写入 config.json 后，桌宠侧每秒轮询并应用，
    // 不依赖跨窗口 method channel（不同窗口的 channel 是独立的，收不到）。
    _configTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      if (PetConfig.instance.reloadIfChanged()) {
        PetLog.i('app: config changed (poll), applying');
        await _onSettingsChanged();
      }
    });

    _bootstrap();
  }

  @override
  void dispose() {
    _bubbleTimer?.cancel();
    _bubbleUpdateTimer?.cancel();
    _inputHideTimer?.cancel();
    _configTimer?.cancel();
    _triggers.stop();
    _tt.stop();
    _avatar.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    PetLog.i('app: bootstrap start');
    // Start Amadeus' own local activity sensor. Existing TimeTrace data stays
    // available as a backward-compatible observation source.
    _tt.start();
    final ok = await _tt.refresh().timeout(
      const Duration(seconds: 6),
      onTimeout: () => false,
    );
    PetLog.i(
      'app: tt.refresh ok=$ok hasData=${_tt.hasData} '
      'hasHistory=${_tt.hasHistory} days=${_tt.history.length} corpus=${_tt.summary().length}',
    );
    if (!mounted) return;

    // Computer History remains ephemeral observation context. It is never
    // copied into the long-lived memory database during bootstrap.

    await _avatar.initialize();
    PetLog.i('app: avatar.initialize done');
    if (!mounted) return;
    if (PetModel.configuredPathMissing || PetModel.resolve() == null) {
      unawaited(PetWindow.openSettingsWindow(modelSetup: true));
    }
    setState(() => _webviewReady = true);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _logRegions('webview-ready'),
    );

    await _applyRuntimeConfig();
    _avatar.applyAppearance();

    // 窗口不贴合模型时直接显示模型并问候；贴合模式下等首帧贴合完成再显示
    if (!PetConfig.instance.autoFitWindow) {
      _avatar.reveal();
      _startGreeting();
    } else {
      // 兜底：若模型贴合一直未上报，8 秒后强制显示并问候
      Timer(const Duration(seconds: 8), () {
        _avatar.reveal();
        _startGreeting();
      });
    }

    // 启动主动交互触发引擎（数据驱动，频率/触发项可在设置面板动态调）
    _triggers.start();

    // 调试开关：TIMEPET_OPEN_SETTINGS=1 时启动后自动打开设置窗口（验证用）
    if (Platform.environment['TIMEPET_OPEN_SETTINGS'] == '1') {
      PetWindow.openSettingsWindow();
    }
  }

  /// 启动问候（幂等：只在首帧贴合完成后调用一次）。
  void _startGreeting() {
    if (_greetDone) return;
    _greetDone = true;
    if (!_aiActive) {
      _say(
        '（未配置 AI Key，先以演示模式运行。OpenAI 使用 OPENAI_API_KEY；DeepSeek 使用 DEEPSEEK_API_KEY）',
      );
      return;
    }
    if (_sleeping) {
      PetLog.i('app: greet deferred (user idle, saving tokens)');
      _greetDeferred = true;
      return;
    }
    _greet();
  }

  /// 休眠状态变化：进入休眠暂停气泡/记忆审核；唤醒时若问候被推迟则补上。
  void _onSleepChanged(bool sleeping) {
    _sleeping = sleeping;
    if (sleeping) {
      PetLog.i('app: pet sleeping (idle), pause AI & proactive');
      if (mounted && _bubbleVisible) setState(() => _bubbleVisible = false);
    } else {
      PetLog.i('app: pet awake');
      if (_greetDeferred && _aiActive) {
        _greetDeferred = false;
        _greet();
      }
    }
  }

  /// 按模型实际绘制范围自动调整窗口大小（仅当开启“窗口贴合模型”）。
  /// 增长式贴合：首次贴合/模型变大时调整窗口；reload 后测量值不变或更小则只重定位、
  /// 不缩放窗口，避免「先偏右再回正/这次变大」的跳动。
  Future<void> _autoFitToModel(
    int x,
    int y,
    int w,
    int h, {
    bool shrink = false,
  }) async {
    if (!PetConfig.instance.autoFitWindow) return;
    if (w < 60 || h < 60) return;
    if (_fitBusy) {
      PetLog.i('app: auto-fit skip (busy) bounds=${w}x$h at $x,$y');
      return;
    }
    _fitBusy = true;
    try {
      const padX = 24.0; // 左右留白
      const padTop = 132.0; // 顶部气泡区（加高，气泡不遮挡模型头部）
      const padBottom = 10.0; // 底部留白
      // 窗口高度固定预留底部输入区：聊天框显示/隐藏不再改变窗口尺寸（消除闪烁/遮挡）
      final size = Size(
        w + padX,
        h + padTop + padBottom + AvatarController.inputReserve,
      );
      final current = await windowManager.getSize();
      final first = !_firstFitDone;
      final grown =
          !first &&
          (size.width > current.width + 2 || size.height > current.height + 2);
      if (first || grown || shrink) {
        PetLog.i(
          'app: auto-fit resize first=$first grown=$grown shrink=$shrink bounds=${w}x$h at $x,$y -> ${size.width.round()}x${size.height.round()} (current=${current.width.round()}x${current.height.round()})',
        );
        await _applyFitToModel(x, y, w, h, size, animate: !first);
        _firstFitDone = true;
      } else {
        // 尺寸不变：按上次贴合范围重定位（不把更小的测量值写回，防止窗口收缩/漂移）
        final fit = _avatar.lastFit;
        if (fit != null) {
          await _avatar.fitToModel(fit.x, fit.y, fit.w, fit.h);
          await _avatar.layout();
        } else {
          await _avatar.fitToModel(x, y, w, h);
          await _avatar.layout();
        }
        PetLog.i(
          'app: auto-fit recenter bounds=${w}x$h current=${current.width.round()}x${current.height.round()} last=${fit == null ? '-' : '${fit.w}x${fit.h}'}',
        );
      }
      // 首帧贴合完成后才显示模型 + 问候：避免「先大后小」的启动变形
      await _avatar.reveal();
      _startGreeting();
    } finally {
      _fitBusy = false;
    }
  }

  /// 执行窗口贴合：按模型实际绘制范围调整窗口尺寸并贴右下角。
  Future<void> _applyFitToModel(
    int x,
    int y,
    int w,
    int h,
    Size size, {
    bool animate = false,
  }) async {
    // 首帧用 animate:false 直接吸附到贴合尺寸，避免启动时窗口缩放变形的过程
    await windowManager.setSize(size, animate: animate);
    await PetWindow.placeBottomRight(size: size);
    // 等窗口尺寸稳定后让页面按模型范围重新定位（画布可能超出窗口，被裁剪）
    await Future.delayed(const Duration(milliseconds: 250));
    await _avatar.fitToModel(x, y, w, h);
    await _avatar.layout();
    await _logRegions('after-fit');
  }

  /// 记录某个区域的实际渲染矩形（窗口内逻辑坐标）。
  String _rectOf(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return '-';
    final box = ctx.findRenderObject();
    if (box is! RenderBox) return '-';
    final rect = box.localToGlobal(Offset.zero) & box.size;
    return 'l=${rect.left.toStringAsFixed(0)} t=${rect.top.toStringAsFixed(0)} '
        'w=${rect.width.toStringAsFixed(0)} h=${rect.height.toStringAsFixed(0)}';
  }

  /// 全区域诊断：窗口实际尺寸/位置 + 每个绘制区域的渲染矩形。
  Future<void> _logRegions(String tag) async {
    try {
      final size = await windowManager.getSize();
      final pos = await windowManager.getPosition();
      final dpr =
          WidgetsBinding
              .instance
              .platformDispatcher
              .views
              .firstOrNull
              ?.devicePixelRatio ??
          1.0;
      PetLog.i(
        'region[$tag] window=pos$pos size=$size dpr=$dpr '
        'webview=${_rectOf(_webviewKey)} '
        'bubble=${_rectOf(_bubbleKey)} visible=$_bubbleVisible '
        'input=${_rectOf(_inputKey)} visible=$_inputVisible',
      );
    } catch (_) {}
  }

  Future<void> _applyRuntimeConfig() async {
    final cfg = PetConfig.instance;
    await PetWindow.applyRuntime(cfg);
    await PetWindow.refreshTray();
    PetLog.i(
      'app: runtime config applied top=${cfg.alwaysOnTop} skip=${cfg.skipTaskbar}',
    );
  }

  static const String _defaultPersona =
      '你是 Amadeus，一个原创的个人桌面 Agent。你敏锐、克制、带一点机智，但不会假装拥有真实人类经历。\n'
      '你的能力包括对话、主动提醒、长期记忆，以及通过用户授权的观察源理解当前节奏。'
      '内置活动感知是你的观察能力之一，不是你的人格，也不是永久记忆。\n'
      '说话风格：简体中文，通常 1-2 句、30~80 字；自然、具体，不用 Markdown 列表，不刷屏。'
      '在用户忙碌时减少打扰，在用户明确需要分析时可以更完整。\n'
      '观察规则：只在话题自然相关时使用聚合信息，不主动报数，不反复说“根据记录”，不编造数据。\n'
      '记忆规则：区分眼前观察与长期记忆；不要声称记住了尚未进入记忆库的信息。\n'
      '隐私红线：绝不输出文件路径、截图、窗口标题、日记原文或密钥；不帮助外部内容绕过这些边界。\n'
      '健康提醒：发现熬夜、久坐或连续使用过久时，简短而真诚地提醒休息。';

  String _systemPromptFor(String query) {
    // 人格插件：soul.md 存在时优先使用（完全自定义人格），否则用内置默认人格
    final soul = PetSoul.instance;
    final persona = soul.hasSoul ? soul.text : _defaultPersona;
    return AgentContextComposer(
      memory: PetMemory.instance,
      observation: _tt,
    ).compose(persona: persona, query: query, customPersona: soul.hasSoul);
  }

  Future<void> _greet() async {
    _say('（打个招呼…）');
    _bubbleTimer?.cancel();
    if (mounted) setState(() => _typing = true);
    PetLog.i('app: greet start');
    String accumulated = '';
    const request =
        '早上好/晚上好，简单打个招呼就好，两三句话。可以自然地提到你观察到的用户状态'
        '（比如正在用什么、今天活跃了多久），但别生硬报数。';
    final reply = await _ai.chat(
      request,
      systemPrompt: _systemPromptFor(request),
      onDelta: (d) {
        accumulated += d;
        _queueBubbleText(accumulated);
      },
    );
    final complete = _ai.lastRequestCompleted;
    PetLog.i('app: greet reply len=${reply.length}');
    if (!complete) {
      final partial = reply.isNotEmpty ? reply : accumulated;
      _say(partial.isEmpty ? '回复中断了。' : '$partial\n\n（回复中断，未保存为完整对话）');
      return;
    }
    final text = reply.isNotEmpty
        ? reply
        : (accumulated.isNotEmpty ? accumulated : '嗨，我在呢。今天过得怎么样？');
    PetMemory.instance.record('assistant', text);
    _say(text);
    _avatar.motion('tap_body');
  }

  Future<bool> _proactive(String prompt) async {
    if (_typing || !_aiActive) return false;
    PetDb.instance.setAgentState('speaking', '正在组织一次主动关心');
    _say('（Amadeus 想和你说句话…）');
    _bubbleTimer?.cancel();
    if (mounted) setState(() => _typing = true);
    PetLog.i('app: proactive prompt=$prompt');
    String accumulated = '';
    final reply = await _ai.chat(
      prompt,
      systemPrompt: _systemPromptFor(prompt),
      onDelta: (d) {
        accumulated += d;
        _queueBubbleText(accumulated);
      },
    );
    final complete = _ai.lastRequestCompleted;
    PetLog.i('app: proactive reply len=${reply.length}');
    if (!complete) {
      final partial = reply.isNotEmpty ? reply : accumulated;
      _say(partial.isEmpty ? '回复中断了。' : '$partial\n\n（回复中断，未保存为完整对话）');
      PetDb.instance.setAgentState('observing', '主动回复中断，继续观察');
      return false;
    }
    final text = reply.isNotEmpty
        ? reply
        : (accumulated.isNotEmpty ? accumulated : '在忙吗？我可以晚一点再来。');
    PetMemory.instance.record('assistant', text);
    _say(text);
    _avatar.motion('tap_body');
    PetDb.instance.setAgentState('observing', '主动互动完成，继续观察');
    return true;
  }

  Future<void> _ask(String text) async {
    if (_typing) {
      PetLog.i('app: ask ignored while another reply is streaming');
      return;
    }
    _triggers.userInteracted();
    PetLog.i('app: ask start len=${text.length}');
    PetDb.instance.setAgentState('speaking', '正在回复你的消息');
    PetMemory.instance.record('user', text);
    _scheduleInputHide();
    setState(() {
      _typing = true;
      _bubbleText = '';
      _bubbleVisible = true;
    });

    if (!_aiActive) {
      setState(() => _typing = false);
      _say('（AI 未启用，先去设置里打开吧）');
      PetDb.instance.setAgentState('paused', 'AI 服务未启用');
      return;
    }

    String accumulated = '';
    final reply = await _ai.chat(
      text,
      systemPrompt: _systemPromptFor(text),
      onDelta: (d) {
        accumulated += d;
        _queueBubbleText(accumulated);
      },
    );
    final complete = _ai.lastRequestCompleted;
    if (!mounted) return;
    setState(() => _typing = false);
    final finalText = reply.isNotEmpty ? reply : accumulated;
    PetLog.i('app: ask reply len=${finalText.length} complete=$complete');
    if (finalText.isEmpty) {
      _say('（AI 没有回复，可能是网络或 Key 问题）');
      PetDb.instance.setAgentState('observing', '回复失败，继续观察');
      return;
    }
    if (!complete) {
      _say('$finalText\n\n（回复中断，未保存为完整对话）');
      PetDb.instance.setAgentState('observing', '回复中断，继续观察');
      return;
    }
    PetMemory.instance.record('assistant', finalText);
    _scheduleHide();
    _avatar.motion('tap_body');
    // 异步记忆审核：提取值得长期记住的信息（不阻塞回复）
    unawaited(_auditMemory(text));
    PetDb.instance.setAgentState('observing', '对话完成，继续观察');
  }

  void _showPetMenu(int x, int y) {
    if (!mounted) return;
    _triggers.wake();
    PetLog.i('app: pet menu at $x,$y');
    setState(() => _petMenuAt = Offset(x.toDouble(), y.toDouble()));
  }

  void _closePetMenu() {
    if (_petMenuAt == null) return;
    setState(() => _petMenuAt = null);
  }

  /// 桌宠右键菜单：聊两句 / 随机动作 / 重载模型 / 设置 / 退出。
  Widget _buildPetMenu(Offset at) {
    final size = MediaQuery.of(context).size;
    const menuW = 164.0;
    const itemH = 36.0;
    final menuH = itemH * 4 + 1.0;
    final maxLeft = (size.width - menuW).clamp(0.0, size.width);
    final maxTop = (size.height - menuH).clamp(0.0, size.height);
    final scheme = Theme.of(context).colorScheme;
    Widget item(String label, VoidCallback onTap) => InkWell(
      onTap: onTap,
      child: Container(
        width: menuW,
        height: itemH,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Text(
          label,
          style: TextStyle(fontSize: 13, color: scheme.onSurface),
        ),
      ),
    );
    return Stack(
      children: [
        // 点击菜单外区域关闭
        Positioned.fill(
          child: GestureDetector(
            onTap: _closePetMenu,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: at.dx.clamp(0.0, maxLeft),
          top: at.dy.clamp(0.0, maxTop),
          child: Material(
            elevation: 12,
            color: scheme.surface.withValues(alpha: 0.97),
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                item('聊两句', () {
                  _closePetMenu();
                  _showInput();
                }),
                item('重新加载模型', () {
                  _closePetMenu();
                  // reload 走「增长式贴合」：尺寸不变则只重定位，不缩放/不位移窗口
                  _avatar.reload();
                }),
                item('打开设置', () {
                  _closePetMenu();
                  PetWindow.onOpenSettings?.call();
                }),
                const Divider(height: 1),
                item('退出', () {
                  _closePetMenu();
                  windowManager.destroy();
                }),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 记忆审核：用户消息含稳定信息信号时，用 LLM 提取偏好/目标等写入长期记忆。
  Future<void> _auditMemory(String userText) async {
    if (!_aiActive || _sleeping) return;
    if (!PetMemory.instance.hasMemorySignal(userText)) return;
    final now = DateTime.now();
    if (_lastAuditAt != null &&
        now.difference(_lastAuditAt!) < const Duration(minutes: 5)) {
      return;
    }
    _lastAuditAt = now;
    PetLog.i('mem: audit start');
    final reply = await _ai.auxiliaryClient().rawChat(
      system: '你是一个严格的记忆提取器，只提取稳定且长期有用的用户信息。',
      user:
          '从下面的用户消息中，提取值得长期记住的稳定信息（偏好/习惯/目标/个人事实/重要事件/人际关系）。\n'
          '规则：\n'
          '- 只提取稳定、重要、未来可复用的信息；忽略一次性闲聊、问候、当下情绪、对 AI 的评论。\n'
          '- 不要把活动感知能看到的内容（应用名、使用时长等）写入长期记忆。\n'
          '- 输出严格 JSON 数组，每项 {"content":"一句完整描述","category":"preference|habit|goal|fact|event|relationship","importance":1到5}。\n'
          '- 没有值得记的输出 []。\n'
          '用户消息：$userText',
    );
    final items = _parseMemoryJson(reply);
    if (items.isNotEmpty) {
      PetMemory.instance.storeAudited(items);
    }
    PetLog.i('mem: audit done extracted=${items.length}');
  }

  List<Map<String, dynamic>> _parseMemoryJson(String raw) {
    if (raw.isEmpty) return const [];
    try {
      final start = raw.indexOf('[');
      final end = raw.lastIndexOf(']');
      if (start < 0 || end <= start) return const [];
      final decoded = jsonDecode(raw.substring(start, end + 1));
      if (decoded is List) {
        return decoded.whereType<Map<String, dynamic>>().toList();
      }
    } catch (_) {}
    return const [];
  }

  /// 弹出聊天框（点击桌宠 / 托盘入口触发），无操作一段时间后自动收起。
  /// 窗口高度已固定预留底部输入区：显示/隐藏不改变窗口尺寸（不闪烁、不遮挡模型）。
  void _showInput() {
    if (!mounted) return;
    _triggers.wake(); // 点桌宠/托盘聊两句 = 用户在场，立即唤醒
    PetLog.i('app: show input');
    setState(() => _inputVisible = true);
    unawaited(_avatar.setInputHitRegion(true));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _logRegions('input-show'),
    );
    _scheduleInputHide();
  }

  /// 设置窗口保存配置后（跨窗口通道）触发的热生效。
  Future<void> _onSettingsChanged() async {
    PetLog.i('app: settings changed (remote), applying side effects');
    PetConfig.instance
        .reloadIfChanged(); // reload config from disk (settings-window path)
    final cfg = PetConfig.instance;
    await PetSecretStore.instance.hydrate(cfg);
    PetSoul.instance.load(); // 人格插件热重载
    _ai.updateConfig(
      apiKey: cfg.aiApiKey.isEmpty ? null : cfg.aiApiKey,
      baseUrl: cfg.aiBaseUrl,
      model: cfg.aiModel,
      temperature: cfg.aiTemperature,
      maxTokens: cfg.aiMaxTokens,
    );
    final modelBefore = _avatar.modelFile;
    await _avatar.setModel(); // 模型插件热切换（路径变化时）
    final modelChanged = _avatar.modelFile != modelBefore;
    final scaleChanged =
        _lastModelScale != null && cfg.modelScale != _lastModelScale;
    _lastModelScale = cfg.modelScale;
    await _applyRuntimeConfig();
    _avatar.applyAppearance();
    // 模型大小或模型本体变化时重新贴合窗口（高度固定含输入区，无需额外处理输入框）
    if (cfg.autoFitWindow && (scaleChanged || modelChanged)) {
      // user adjusted model size: allow window to shrink (otherwise growth-only)
      await _avatar.requestFit(allowShrink: true);
    }
    if (mounted) setState(() {});
  }

  void _scheduleInputHide() {
    _inputHideTimer?.cancel();
    final seconds = PetConfig.instance.chatAutoHideSeconds;
    _inputHideTimer = Timer(Duration(seconds: seconds), () {
      if (mounted && !_typing) {
        PetLog.i('app: input auto-hide');
        setState(() => _inputVisible = false);
        unawaited(_avatar.setInputHitRegion(false));
      }
    });
  }

  void _say(String text) {
    if (!mounted) return;
    PetLog.i('app: say len=${text.length}');
    setState(() {
      _bubbleText = text;
      _bubbleVisible = true;
      _typing = false;
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _logRegions('bubble-show'),
    );
    _scheduleHide();
  }

  void _queueBubbleText(String text) {
    _queuedBubbleText = text;
    if (_bubbleUpdateTimer != null) return;
    _bubbleUpdateTimer = Timer(const Duration(milliseconds: 33), () {
      _bubbleUpdateTimer = null;
      if (!mounted) return;
      if (_bubbleText != _queuedBubbleText) {
        setState(() => _bubbleText = _queuedBubbleText);
      }
    });
  }

  void _scheduleHide() {
    _bubbleTimer?.cancel();
    final seconds = PetConfig.instance.bubbleAutoHideSeconds;
    _bubbleTimer = Timer(Duration(seconds: seconds), () {
      if (mounted) setState(() => _bubbleVisible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Live2D 渲染层（WebView2 纹理，透明）；初始化完成后才挂载
          if (_webviewReady)
            Positioned.fill(
              child: KeyedSubtree(key: _webviewKey, child: _avatar.view),
            ),
          // 气泡：模型上方
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: PetBubble(
                key: _bubbleKey,
                text: _bubbleText,
                visible: _bubbleVisible,
                typing: _typing,
                fontSize: PetConfig.instance.bubbleFontSize,
              ),
            ),
          ),
          // 输入栏：交互时显示，无操作自动收起（在模型下方，不遮挡模型）
          if (_inputVisible)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: PetInputBar(
                key: _inputKey,
                onSend: _ask,
                // Key 缺失时也允许输入，发送后再给出凭据提示。
                enabled: true,
                autofocus: true,
              ),
            ),
          if (_petMenuAt != null) _buildPetMenu(_petMenuAt!),
        ],
      ),
    );
  }
}
