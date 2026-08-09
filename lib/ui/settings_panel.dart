import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../services/pet_config.dart';
import '../services/pet_db.dart';
import '../services/pet_logger.dart';
import '../services/pet_memory.dart';

/// 设置页（独立设置窗口内容，Material3 简洁风格）：
/// - 三个 Tab：外观 / 对话 / 系统
/// - 所有修改即时写入 config.json，并通过跨窗口通道通知桌宠热生效
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.onClose, this.config});

  /// 关闭回调（桌面窗口用系统关闭按钮即可，可空）。
  final VoidCallback? onClose;
  final PetConfig? config;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  PetConfig get cfg => widget.config ?? PetConfig.instance;
  static const _modelOptions = <String>[
    'gpt-5.6-luna',
    'gpt-5.6-sol',
    'gpt-4.1-mini',
    'deepseek-chat',
    'custom',
  ];

  Timer? _textDebounce;
  bool _disposing = false;
  final TextEditingController _baseUrlCtrl = TextEditingController();
  final TextEditingController _modelCtrl = TextEditingController();
  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _modelPathCtrl = TextEditingController();
  final TextEditingController _soulFileCtrl = TextEditingController();
  final TextEditingController _soulTextCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _syncControllersFromConfig();
  }

  void _syncControllersFromConfig() {
    _baseUrlCtrl.text = cfg.aiBaseUrl;
    _modelCtrl.text = cfg.aiModel;
    _apiKeyCtrl.text = cfg.aiApiKey;
    _modelPathCtrl.text = cfg.modelPath;
    _soulFileCtrl.text = cfg.soulFile;
    _soulTextCtrl.text = cfg.soulText;
  }

  @override
  void dispose() {
    _disposing = true;
    _commitNow();
    _textDebounce?.cancel();
    _baseUrlCtrl.dispose();
    _modelCtrl.dispose();
    _apiKeyCtrl.dispose();
    _modelPathCtrl.dispose();
    _soulFileCtrl.dispose();
    _soulTextCtrl.dispose();
    super.dispose();
  }

  /// 保存配置并通知桌宠窗口热生效（跨窗口通道）。
  void _commit() => _debouncedCommit();

  void _commitNow() {
    cfg.save();
    PetLog.i('settings: committed');
    _notifyPet();
    if (mounted && !_disposing) setState(() {});
  }

  void _debouncedCommit() {
    _textDebounce?.cancel();
    _textDebounce = Timer(const Duration(milliseconds: 400), _commitNow);
  }

  void _notifyPet() {
    try {
      const WindowMethodChannel(
        'pet',
        mode: ChannelMode.unidirectional,
      ).invokeMethod('config-changed').catchError((_) {});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.surface,
              Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.055),
                scheme.surface,
              ),
              scheme.surfaceContainerLowest,
            ],
          ),
        ),
        child: DefaultTabController(
          length: 3,
          child: Column(
            children: [
              _header(scheme),
              TabBar(
                tabs: const [
                  Tab(text: '外观', height: 40),
                  Tab(text: '对话', height: 40),
                  Tab(text: '系统', height: 40),
                ],
                labelStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                unselectedLabelStyle: const TextStyle(fontSize: 13),
                indicatorSize: TabBarIndicatorSize.label,
              ),
              const Divider(height: 1),
              Expanded(
                child: TabBarView(
                  children: [_buildAppearance(), _buildChat(), _buildSystem()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Icon(Icons.tune_rounded, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Text(
            '设置',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const Spacer(),
          if (widget.onClose != null)
            IconButton(
              onPressed: widget.onClose,
              icon: const Icon(Icons.close_rounded, size: 20),
              tooltip: '关闭',
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Widget _buildAppearance() {
    return _list([
      _switch('深色模式', '设置窗口使用深色还是浅色主题。', cfg.darkMode, (v) {
        cfg.darkMode = v;
        _commit();
      }),
      _slider(
        '设置窗口透明度',
        '调整整个设置窗口与桌面背景的融合程度；文字也会一起变淡。',
        cfg.settingsOpacity,
        0.75,
        1.0,
        (v) {
          cfg.settingsOpacity = v;
          windowManager.setOpacity(v);
          _commit();
        },
        (v) => '${(v * 100).round()}%',
      ),
      _slider(
        '模型大小',
        'Live2D 模型相对画布的缩放。',
        cfg.modelScale,
        0.7,
        3.0,
        (v) {
          cfg.modelScale = v;
          _commit();
        },
        (v) => '${(v * 100).round()}%',
      ),
      _slider(
        '模型垂直偏移',
        '0 是聊天输入区上方的基准位置；负值继续向下，正值向上。底部聊天区预留不会由此滑块移除。',
        cfg.vOffset.toDouble(),
        -160,
        160,
        (v) {
          cfg.vOffset = v.round();
          _commit();
        },
        (v) => '${v.round()}px',
      ),
      _slider('模型透明度', '模型整体透明度。', cfg.modelOpacity, 0.3, 1.0, (v) {
        cfg.modelOpacity = v;
        _commit();
      }, (v) => '${(v * 100).round()}%'),
      _slider('气泡字号', '对话气泡文字大小。', cfg.bubbleFontSize, 10, 18, (v) {
        cfg.bubbleFontSize = v;
        _commit();
      }, (v) => v.toStringAsFixed(1)),
      _slider(
        '气泡显示时长',
        '气泡出现后多少秒自动隐藏。',
        cfg.bubbleAutoHideSeconds.toDouble(),
        3,
        30,
        (v) {
          cfg.bubbleAutoHideSeconds = v.round();
          _commit();
        },
        (v) => '${v.round()}s',
      ),
      _textField(
        '模型路径',
        _modelPathCtrl,
        (v) {
          cfg.modelPath = v.trim();
          _debouncedCommit();
        },
        hint: '留空自动扫描 exe 目录/models 与 %APPDATA%/timepet/models',
        help:
            '插件化模型：指向 Live2D 模型的 *.model.json（Cubism 2.1，绝对路径）。模型文件不入库、不入安装包，版权由你自行确认。',
      ),
    ]);
  }

  Widget _buildChat() {
    return _list([
      _switch('主动聊天', '关闭后红莉栖不会主动找你。', cfg.proactiveEnabled, (v) {
        cfg.proactiveEnabled = v;
        _commit();
      }),
      _slider(
        '最小间隔',
        '两次主动聊天的最小间隔（分钟）。',
        cfg.minIntervalMinutes,
        5,
        120,
        (v) {
          cfg.minIntervalMinutes = v;
          _commit();
        },
        (v) => '${v.round()} 分钟',
      ),
      _slider('每小时上限', '每小时最多主动聊天次数。', cfg.maxPerHour.toDouble(), 1, 10, (v) {
        cfg.maxPerHour = v.round();
        _commit();
      }, (v) => '${v.round()} 次'),
      _slider(
        '随机搭话概率',
        '每分钟评估时的随机搭话概率。',
        cfg.randomNudgeChance,
        0,
        1,
        (v) {
          cfg.randomNudgeChance = v;
          _commit();
        },
        (v) => '${(v * 100).round()}%',
      ),
      _slider(
        '久坐阈值',
        '连续使用多少分钟算「久坐」。',
        cfg.longSessionMinutes.toDouble(),
        30,
        300,
        (v) {
          cfg.longSessionMinutes = v.round();
          _commit();
        },
        (v) => '${v.round()} 分钟',
      ),
      _group('触发场景', [
        _miniSwitch('整点', cfg.triggerHourly, (v) {
          cfg.triggerHourly = v;
          _commit();
        }),
        _miniSwitch('深夜', cfg.triggerLateNight, (v) {
          cfg.triggerLateNight = v;
          _commit();
        }),
        _miniSwitch('久坐', cfg.triggerLongSession, (v) {
          cfg.triggerLongSession = v;
          _commit();
        }),
        _miniSwitch('切窗激增', cfg.triggerAppSwitchSpike, (v) {
          cfg.triggerAppSwitchSpike = v;
          _commit();
        }),
        _miniSwitch('随机', cfg.triggerRandomNudge, (v) {
          cfg.triggerRandomNudge = v;
          _commit();
        }),
        _miniSwitch('空闲归来', cfg.triggerIdleReturn, (v) {
          cfg.triggerIdleReturn = v;
          _commit();
        }, help: '离开电脑又回来后，她主动打个招呼。'),
        _miniSwitch('专注提醒', cfg.triggerFocusReminder, (v) {
          cfg.triggerFocusReminder = v;
          _commit();
        }, help: '盯着同一应用超过 1.5 小时，提醒你休息。'),
        _miniSwitch('记忆关心', cfg.triggerMemoryNudge, (v) {
          cfg.triggerMemoryNudge = v;
          _commit();
        }, help: '聊过的重要事（目标/偏好），过会儿她自然提起。'),
      ]),
      _group('省电休眠', [
        _miniSwitch(
          '空闲休眠',
          cfg.sleepEnabled,
          (v) {
            cfg.sleepEnabled = v;
            _commit();
          },
          help: '连续空闲超过阈值后进入休眠：停止主动说话与记忆审核，省 API 费用；你一回来就自动唤醒。',
        ),
        _miniSwitch('忙时少打扰', cfg.adaptiveFrequency, (v) {
          cfg.adaptiveFrequency = v;
          _commit();
        }, help: '今天活跃时间很长且正在忙时，自动拉长间隔、降低打扰上限。'),
        _slider(
          '休眠阈值',
          '连续空闲多少分钟进入休眠（期间完全不调用 AI）。',
          cfg.sleepIdleMinutes.toDouble(),
          5,
          60,
          (v) {
            cfg.sleepIdleMinutes = v.round();
            _commit();
          },
          (v) => '${v.round()} 分钟',
        ),
      ]),
      _slider(
        '输入框收起时长',
        '聊天输入框无操作多少秒后自动收起。',
        cfg.chatAutoHideSeconds.toDouble(),
        5,
        120,
        (v) {
          cfg.chatAutoHideSeconds = v.round();
          _commit();
        },
        (v) => '${v.round()}s',
      ),
    ]);
  }

  Widget _modelRouteSelector() {
    final selected = _modelOptions.contains(cfg.aiModel)
        ? cfg.aiModel
        : 'custom';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DropdownButtonFormField<String>(
        initialValue: selected,
        decoration: const InputDecoration(
          labelText: '选择对话模型',
          helperText: '选择模型即可；API 密钥仍从系统环境变量读取，不会写入配置文件。',
          isDense: true,
        ),
        items: const [
          DropdownMenuItem(
            value: 'gpt-5.6-luna',
            child: Text('GPT Luna（快速聊天）'),
          ),
          DropdownMenuItem(value: 'gpt-5.6-sol', child: Text('GPT Sol（复杂任务）')),
          DropdownMenuItem(
            value: 'gpt-4.1-mini',
            child: Text('GPT 4.1 Mini（轻量）'),
          ),
          DropdownMenuItem(
            value: 'deepseek-chat',
            child: Text('DeepSeek Chat'),
          ),
          DropdownMenuItem(value: 'custom', child: Text('自定义兼容接口')),
        ],
        onChanged: (value) {
          if (value == null || value == 'custom') return;
          cfg.aiModel = value;
          _modelCtrl.text = value;
          if (value == 'deepseek-chat') {
            cfg.aiBaseUrl = 'https://api.deepseek.com/v1';
            _baseUrlCtrl.text = cfg.aiBaseUrl;
          } else {
            cfg.aiBaseUrl = 'https://api.openai.com/v1';
            _baseUrlCtrl.text = cfg.aiBaseUrl;
          }
          _commit();
          setState(() {});
        },
      ),
    );
  }

  Widget _buildSystem() {
    return _buildSystemNew();
  }

  /*
    return _list([
      _connectionCard(),
      _memoryPreview(),
      _soulCard(),
      _switch('鍚敤 AI', '鍏抽棴鍚庡璇濊蛋鏈湴鍏滃簳鏂囨銆?, cfg.aiEnabled, (v) {
        cfg.aiEnabled = v;
        _commit();
      }),
      _group('绐楀彛', [
        _miniSwitch('妗屽疇濮嬬粓缃《', cfg.alwaysOnTop, (v) {
          cfg.alwaysOnTop = v;
          _commit();
        }),
        _miniSwitch('绐楀彛鑷€傚簲妯″瀷', cfg.autoFitWindow, (v) {
          cfg.autoFitWindow = v;
          _commit();
        }),
        _miniSwitch('鍚姩鏃舵樉绀烘瀹?, cfg.startVisible, (v) {
          cfg.startVisible = v;
          _commit();
        }),
      ]),
      TextButton.icon(
        onPressed: () {
          _textDebounce?.cancel();
          cfg.resetToDefaults();
          _syncControllersFromConfig();
          _notifyPet();
          setState(() {});
        },
        icon: const Icon(Icons.restore_rounded, size: 16),
        label: const Text('鎭㈠榛樿璁剧疆'),
      ),
    ]);
  }

  Widget _connectionCard() {
    final labels = <String, String>{
      'openai_api_key': 'OpenAI API Key',
      'deepseek_api_key': 'DeepSeek API Key',
      'custom': '自定义兼容接口',
      'codex_login': 'ChatGPT / Codex 登录',
    };
    final mode = labels[cfg.aiAuthMode] ?? labels['custom']!;
    final configured = cfg.aiAuthMode == 'codex_login'
        ? false
        : cfg.aiApiKey.trim().isNotEmpty;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.account_tree_outlined),
        title: const Text('对话接入方式'),
        subtitle: Text('$mode · ${configured ? '已配置' : '需要配置'}'),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => _ConnectionPage(config: cfg)),
          );
          if (mounted) setState(() {});
        },
      ),
    );
  }

  */

  Widget _buildSystemNew() {
    return _list([
      _connectionCardNew(),
      _memoryPreview(),
      _soulCard(),
      _switch(
        '\u542f\u7528 AI',
        '\u5173\u95ed\u540e\u4e0d\u518d\u8c03\u7528\u5728\u7ebf\u5bf9\u8bdd\u6a21\u578b\u3002',
        cfg.aiEnabled,
        (v) {
          cfg.aiEnabled = v;
          _commit();
        },
      ),
      _group('\u7a97\u53e3', [
        _miniSwitch('\u684c\u5ba0\u7f6e\u9876', cfg.alwaysOnTop, (v) {
          cfg.alwaysOnTop = v;
          _commit();
        }),
        _miniSwitch('\u7a97\u53e3\u9002\u5e94\u6a21\u578b', cfg.autoFitWindow, (
          v,
        ) {
          cfg.autoFitWindow = v;
          _commit();
        }),
        _miniSwitch('\u542f\u52a8\u65f6\u663e\u793a', cfg.startVisible, (v) {
          cfg.startVisible = v;
          _commit();
        }),
      ]),
      TextButton.icon(
        onPressed: () {
          _textDebounce?.cancel();
          cfg.resetToDefaults();
          _syncControllersFromConfig();
          _notifyPet();
          setState(() {});
        },
        icon: const Icon(Icons.restore_rounded, size: 16),
        label: const Text('\u6062\u590d\u9ed8\u8ba4\u8bbe\u7f6e'),
      ),
    ]);
  }

  Widget _connectionCardNew() {
    final labels = <String, String>{
      'openai_api_key': 'OpenAI API Key',
      'deepseek_api_key': 'DeepSeek API Key',
      'custom': '\u81ea\u5b9a\u4e49\u517c\u5bb9\u63a5\u53e3',
      'codex_login': 'ChatGPT / Codex \u767b\u5f55',
    };
    final mode = labels[cfg.aiAuthMode] ?? labels['custom']!;
    final configured =
        cfg.aiAuthMode != 'codex_login' && cfg.aiApiKey.trim().isNotEmpty;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.account_tree_outlined),
        title: const Text('\u5bf9\u8bdd\u63a5\u5165\u65b9\u5f0f'),
        subtitle: Text(
          '$mode · ${configured ? '\u5df2\u914d\u7f6e' : '\u5f85\u914d\u7f6e'}',
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => _ConnectionPage(config: cfg)),
          );
          if (mounted) setState(() {});
        },
      ),
    );
  }

  // Kept temporarily while the secondary connection page settles; remove in
  // the next cleanup pass once the old settings UI is fully retired.
  // ignore: unused_element
  Widget _buildSystemLegacy() {
    return _list([
      _memoryPreview(),
      _modelRouteSelector(),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              _textDebounce?.cancel();
              cfg.resetToDefaults();
              _syncControllersFromConfig();
              _notifyPet();
              setState(() {});
            },
            icon: const Icon(Icons.restore_rounded, size: 16),
            label: const Text('恢复默认设置'),
          ),
        ),
      ),
      _switch('启用 AI', '关闭后对话走本地兜底文案。', cfg.aiEnabled, (v) {
        cfg.aiEnabled = v;
        _commit();
      }),
      if (!_modelOptions.contains(cfg.aiModel))
        _textField('自定义模型名称', _modelCtrl, (v) {
          cfg.aiModel = v.trim().isEmpty ? 'gpt-5.6-luna' : v.trim();
          _debouncedCommit();
        }, hint: '仅用于自定义兼容接口'),
      _textField('API 地址', _baseUrlCtrl, (v) {
        cfg.aiBaseUrl = v.trim().isEmpty
            ? 'https://api.openai.com/v1'
            : v.trim();
        _debouncedCommit();
      }),
      _slider(
        '回答变化度',
        '只控制回答的稳定程度：低值更稳定，高值更容易换说法；不影响 TimeTrace 语料数量。',
        cfg.aiTemperature,
        0,
        1.5,
        (v) {
          cfg.aiTemperature = v;
          _commit();
        },
        (v) => v.toStringAsFixed(2),
      ),
      _soulCard(),
      _group('窗口', [
        _miniSwitch('桌宠始终置顶', cfg.alwaysOnTop, (v) {
          cfg.alwaysOnTop = v;
          _commit();
        }, help: '开启后桌宠会保持在其他普通窗口上方；不会影响设置窗口。'),
        _miniSwitch('窗口自适应模型', cfg.autoFitWindow, (v) {
          cfg.autoFitWindow = v;
          _commit();
        }, help: '启动时按模型比例自动调整窗口大小，避免大块透明留白。'),
        _miniSwitch('启动时显示桌宠', cfg.startVisible, (v) {
          cfg.startVisible = v;
          _commit();
        }),
      ]),
      _note(
        'API Key 通过环境变量 OPENAI_API_KEY 提供；DeepSeek API 使用 DEEPSEEK_API_KEY。',
      ),
    ]);
  }

  Widget _list(List<Widget> children) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      children: children,
    );
  }

  Widget _memoryPreview() {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.psychology_outlined, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '长期记忆：${PetMemory.instance.memoryCount()} 条\n查看、搜索或删除已审核的记忆。',
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const _MemoryPage())),
              child: const Text('打开'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _soulCard() {
    final text = cfg.soulText.trim();
    final preview = text.isEmpty
        ? '当前使用默认人格。'
        : text
              .replaceAll('\n', ' ')
              .substring(0, text.length > 90 ? 90 : text.length);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        leading: const Icon(Icons.auto_awesome_outlined),
        title: const Text('人格内容'),
        subtitle: Text('$preview\n影响下一次对话的角色语气，不是 TimeTrace 语料设置。'),
        isThreeLine: true,
        trailing: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => _SoulPage(initial: cfg.soulText)),
          ),
          child: const Text('编辑'),
        ),
      ),
    );
  }

  Widget _group(String title, List<Widget> children) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: scheme.surfaceContainerLow,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _switch(
    String label,
    String help,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                if (help.isNotEmpty) _helpButton(help),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }

  Widget _miniSwitch(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    String help = '',
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                if (help.isNotEmpty) _helpButton(help),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }

  Widget _slider(
    String label,
    String help,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
    String Function(double) format,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (help.isNotEmpty) _helpButton(help),
                  ],
                ),
              ),
              Text(
                format(value),
                style: TextStyle(fontSize: 11.5, color: scheme.primary),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: (v) {
              setState(() {});
              onChanged(v);
            },
          ),
        ],
      ),
    );
  }

  Widget _helpButton(String message) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 15,
        tooltip: message,
        visualDensity: VisualDensity.compact,
        icon: Icon(
          Icons.help_outline_rounded,
          color: Theme.of(context).colorScheme.outline,
        ),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('\u8bbe\u7f6e\u8bf4\u660e'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('\u77e5\u9053\u4e86'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _textField(
    String label,
    TextEditingController controller,
    ValueChanged<String> onChanged, {
    String hint = '',
    String help = '',
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              if (help.isNotEmpty)
                Tooltip(
                  message: help,
                  child: Icon(
                    Icons.help_outline_rounded,
                    size: 15,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            maxLines: maxLines,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: TextStyle(
                fontSize: 10.5,
                color: Theme.of(context).colorScheme.outline,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainer,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _note(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          height: 1.4,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
  }
}

class _ConnectionPage extends StatefulWidget {
  const _ConnectionPage({required this.config});

  final PetConfig config;

  @override
  State<_ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<_ConnectionPage> {
  PetConfig get cfg => widget.config;
  late String _mode;
  late final TextEditingController _key;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
    _mode = cfg.aiAuthMode;
    _key = TextEditingController(text: cfg.aiApiKey);
    _baseUrl = TextEditingController(text: cfg.aiBaseUrl);
    _model = TextEditingController(text: cfg.aiModel);
  }

  @override
  void dispose() {
    _key.dispose();
    _baseUrl.dispose();
    _model.dispose();
    super.dispose();
  }

  void _save() {
    cfg.aiAuthMode = _mode;
    cfg.aiApiKey = _key.text.trim();
    cfg.aiBaseUrl = _baseUrl.text.trim();
    cfg.aiModel = _model.text.trim();
    cfg.save();
    PetLog.i('settings: conversation connection saved mode=$_mode');
    const WindowMethodChannel(
      'pet',
      mode: ChannelMode.unidirectional,
    ).invokeMethod('config-changed');
  }

  void _setMode(String? value) {
    if (value == null) return;
    setState(() {
      _mode = value;
      if (value == 'openai_api_key') {
        _baseUrl.text = 'https://api.openai.com/v1';
        if (_model.text.isEmpty || _model.text == 'deepseek-chat') {
          _model.text = 'gpt-5.6-luna';
        }
      } else if (value == 'deepseek_api_key') {
        _baseUrl.text = 'https://api.deepseek.com/v1';
        if (_model.text.isEmpty || _model.text.startsWith('gpt-')) {
          _model.text = 'deepseek-chat';
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isCustom = _mode == 'custom';
    final isCodex = _mode == 'codex_login';
    return Scaffold(
      appBar: AppBar(title: const Text('对话接入方式')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          DropdownButtonFormField<String>(
            initialValue: _mode,
            decoration: const InputDecoration(
              labelText: '使用方式',
              helperText: '选择 TimePet 如何访问对话模型。',
            ),
            items: const [
              DropdownMenuItem(
                value: 'openai_api_key',
                child: Text('OpenAI API Key'),
              ),
              DropdownMenuItem(
                value: 'deepseek_api_key',
                child: Text('DeepSeek API Key'),
              ),
              DropdownMenuItem(value: 'custom', child: Text('自定义兼容接口')),
              DropdownMenuItem(
                value: 'codex_login',
                child: Text('ChatGPT / Codex 登录'),
              ),
            ],
            onChanged: _setMode,
          ),
          const SizedBox(height: 18),
          if (isCodex)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  '当前 Codex 的 ChatGPT 登录不能直接作为 TimePet 的 API 凭据。\n'
                  '请使用 OpenAI API Key，或选择 DeepSeek API Key。',
                ),
              ),
            ),
          if (!isCodex) ...[
            TextField(
              controller: _key,
              obscureText: !_showKey,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: '粘贴后仅显示掩码',
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _showKey = !_showKey),
                  icon: Icon(
                    _showKey ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _baseUrl,
              readOnly: !isCustom,
              decoration: const InputDecoration(
                labelText: '接口地址',
                helperText: 'OpenAI/DeepSeek 会自动填写；兼容接口可手动修改。',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _model,
              decoration: const InputDecoration(
                labelText: '模型名称',
                helperText: '例如 gpt-5.6-luna 或 deepseek-chat。',
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () {
              _save();
              Navigator.pop(context);
            },
            child: const Text('保存并应用'),
          ),
        ],
      ),
    );
  }
}

class _MemoryPage extends StatefulWidget {
  const _MemoryPage();

  @override
  State<_MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<_MemoryPage> {
  @override
  Widget build(BuildContext context) {
    final rows = PetMemory.instance.recentMemoryRows(limit: 100);
    return Scaffold(
      appBar: AppBar(
        title: const Text('长期记忆'),
        actions: [
          IconButton(
            tooltip: '清空全部记忆',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: rows.isEmpty
                ? null
                : () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('清空长期记忆？'),
                        content: const Text(
                          '只会删除已提取的长期记忆，不会删除聊天记录或 TimeTrace 数据。',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('清空'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) {
                      PetDb.instance.clearMemories();
                      setState(() {});
                    }
                  },
          ),
        ],
      ),
      body: rows.isEmpty
          ? const Center(
              child: Text(
                '暂无已审核记忆\n完成几次对话后，这里会显示稳定的偏好、目标和事实。',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: rows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final row = rows[index];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(vertical: 6),
                  title: Text(row['content']?.toString() ?? ''),
                  subtitle: Text(
                    '${row['category'] ?? '事实'} · 重要性 ${row['importance'] ?? 1} · 来源 ${row['source'] ?? '对话审核'}',
                  ),
                  trailing: IconButton(
                    tooltip: '删除记忆',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      final id = row['id'];
                      if (id is int) {
                        PetDb.instance.deleteMemory(id);
                        setState(() {});
                      }
                    },
                  ),
                );
              },
            ),
    );
  }
}

class _SoulPage extends StatefulWidget {
  const _SoulPage({required this.initial});
  final String initial;

  @override
  State<_SoulPage> createState() => _SoulPageState();
}

class _SoulPageState extends State<_SoulPage> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final cfg = PetConfig.instance;
    cfg.soulText = _controller.text.length > 32000
        ? _controller.text.substring(0, 32000)
        : _controller.text;
    cfg.save();
    try {
      const WindowMethodChannel(
        'pet',
        mode: ChannelMode.unidirectional,
      ).invokeMethod('config-changed');
    } catch (_) {}
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑人格'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: _controller,
          autofocus: true,
          expands: true,
          maxLines: null,
          textAlignVertical: TextAlignVertical.top,
          decoration: const InputDecoration(
            hintText: '直接粘贴或编辑人格设定。留空会恢复默认人格。',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
      ),
    );
  }
}
