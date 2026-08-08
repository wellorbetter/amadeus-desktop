import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';

import '../services/pet_config.dart';
import '../services/pet_db.dart';
import '../services/pet_logger.dart';
import '../services/pet_memory.dart';

/// 设置页（独立设置窗口内容，Material3 简洁风格）：
/// - 三个 Tab：外观 / 对话 / 系统
/// - 所有修改即时写入 config.json，并通过跨窗口通道通知桌宠热生效
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.onClose});

  /// 关闭回调（桌面窗口用系统关闭按钮即可，可空）。
  final VoidCallback? onClose;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  PetConfig get cfg => PetConfig.instance;

  Timer? _textDebounce;
  final TextEditingController _baseUrlCtrl = TextEditingController();
  final TextEditingController _modelPathCtrl = TextEditingController();
  final TextEditingController _soulFileCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _baseUrlCtrl.text = cfg.aiBaseUrl;
    _modelPathCtrl.text = cfg.modelPath;
    _soulFileCtrl.text = cfg.soulFile;
  }

  @override
  void dispose() {
    _textDebounce?.cancel();
    _baseUrlCtrl.dispose();
    _modelPathCtrl.dispose();
    _soulFileCtrl.dispose();
    super.dispose();
  }

  /// 保存配置并通知桌宠窗口热生效（跨窗口通道）。
  void _commit() {
    cfg.save();
    PetLog.i('settings: committed');
    _notifyPet();
    if (mounted) setState(() {});
  }

  void _debouncedCommit() {
    _textDebounce?.cancel();
    _textDebounce = Timer(const Duration(milliseconds: 400), _commit);
  }

  void _notifyPet() {
    try {
      const WindowMethodChannel('pet')
          .invokeMethod('config-changed')
          .catchError((_) {});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: DefaultTabController(
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
              labelStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              unselectedLabelStyle: const TextStyle(fontSize: 13),
              indicatorSize: TabBarIndicatorSize.label,
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                children: [
                  _buildAppearance(),
                  _buildChat(),
                  _buildSystem(),
                ],
              ),
            ),
          ],
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
          Text('设置',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface)),
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
      _slider('模型大小', 'Live2D 模型相对画布的缩放。', cfg.modelScale, 0.7, 1.6, (v) {
        cfg.modelScale = v;
        _commit();
      }, (v) => '${(v * 100).round()}%'),
      _slider('底部留白', '画布底部离窗口底部的距离，调大模型会往上抬。', cfg.vOffset.toDouble(), 0, 80, (v) {
        cfg.vOffset = v.round();
        _commit();
      }, (v) => '${v.round()}px'),
      _slider('模型透明度', '模型整体透明度。', cfg.modelOpacity, 0.3, 1.0, (v) {
        cfg.modelOpacity = v;
        _commit();
      }, (v) => '${(v * 100).round()}%'),
      _slider('气泡字号', '对话气泡文字大小。', cfg.bubbleFontSize, 10, 18, (v) {
        cfg.bubbleFontSize = v;
        _commit();
      }, (v) => v.toStringAsFixed(1)),
      _slider('气泡显示时长', '气泡出现后多少秒自动隐藏。', cfg.bubbleAutoHideSeconds.toDouble(), 3, 30, (v) {
        cfg.bubbleAutoHideSeconds = v.round();
        _commit();
      }, (v) => '${v.round()}s'),
      _textField('模型路径', _modelPathCtrl, (v) {
        cfg.modelPath = v.trim();
        _debouncedCommit();
      }, hint: '留空自动扫描 exe 目录/models 与 %APPDATA%/timepet/models',
        help: '插件化模型：指向 Live2D 模型的 *.model.json（Cubism 2.1，绝对路径）。模型文件不入库、不入安装包，版权由你自行确认。'),
    ]);
  }

  Widget _buildChat() {
    return _list([
      _switch('主动聊天', '关闭后红莉栖不会主动找你。', cfg.proactiveEnabled, (v) {
        cfg.proactiveEnabled = v;
        _commit();
      }),
      _slider('最小间隔', '两次主动聊天的最小间隔（分钟）。', cfg.minIntervalMinutes, 5, 120, (v) {
        cfg.minIntervalMinutes = v;
        _commit();
      }, (v) => '${v.round()} 分钟'),
      _slider('每小时上限', '每小时最多主动聊天次数。', cfg.maxPerHour.toDouble(), 1, 10, (v) {
        cfg.maxPerHour = v.round();
        _commit();
      }, (v) => '${v.round()} 次'),
      _slider('随机搭话概率', '每分钟评估时的随机搭话概率。', cfg.randomNudgeChance, 0, 1, (v) {
        cfg.randomNudgeChance = v;
        _commit();
      }, (v) => '${(v * 100).round()}%'),
      _slider('久坐阈值', '连续使用多少分钟算「久坐」。', cfg.longSessionMinutes.toDouble(), 30, 300, (v) {
        cfg.longSessionMinutes = v.round();
        _commit();
      }, (v) => '${v.round()} 分钟'),
      _group('触发场景', [
        _miniSwitch('整点', cfg.triggerHourly, (v) { cfg.triggerHourly = v; _commit(); }),
        _miniSwitch('深夜', cfg.triggerLateNight, (v) { cfg.triggerLateNight = v; _commit(); }),
        _miniSwitch('久坐', cfg.triggerLongSession, (v) { cfg.triggerLongSession = v; _commit(); }),
        _miniSwitch('切窗激增', cfg.triggerAppSwitchSpike, (v) { cfg.triggerAppSwitchSpike = v; _commit(); }),
        _miniSwitch('随机', cfg.triggerRandomNudge, (v) { cfg.triggerRandomNudge = v; _commit(); }),
        _miniSwitch('空闲归来', cfg.triggerIdleReturn, (v) { cfg.triggerIdleReturn = v; _commit(); }, help: '离开电脑又回来后，她主动打个招呼。'),
        _miniSwitch('专注提醒', cfg.triggerFocusReminder, (v) { cfg.triggerFocusReminder = v; _commit(); }, help: '盯着同一应用超过 1.5 小时，提醒你休息。'),
        _miniSwitch('记忆关心', cfg.triggerMemoryNudge, (v) { cfg.triggerMemoryNudge = v; _commit(); }, help: '聊过的重要事（目标/偏好），过会儿她自然提起。'),
      ]),
      _group('省电休眠', [
        _miniSwitch('空闲休眠', cfg.sleepEnabled, (v) { cfg.sleepEnabled = v; _commit(); }, help: '连续空闲超过阈值后进入休眠：停止主动说话与记忆审核，省 API 费用；你一回来就自动唤醒。'),
        _miniSwitch('忙时少打扰', cfg.adaptiveFrequency, (v) { cfg.adaptiveFrequency = v; _commit(); }, help: '今天活跃时间很长且正在忙时，自动拉长间隔、降低打扰上限。'),
        _slider('休眠阈值', '连续空闲多少分钟进入休眠（期间完全不调用 AI）。', cfg.sleepIdleMinutes.toDouble(), 5, 60, (v) {
          cfg.sleepIdleMinutes = v.round();
          _commit();
        }, (v) => '${v.round()} 分钟'),
      ]),
      _slider('输入框收起时长', '聊天输入框无操作多少秒后自动收起。', cfg.chatAutoHideSeconds.toDouble(), 5, 120, (v) {
        cfg.chatAutoHideSeconds = v.round();
        _commit();
      }, (v) => '${v.round()}s'),
    ]);
  }

  Widget _buildSystem() {
    return _list([
      _switch('启用 AI', '关闭后对话走本地兜底文案。', cfg.aiEnabled, (v) {
        cfg.aiEnabled = v;
        _commit();
      }),
      _dropdown('模型', cfg.aiModel, ['deepseek-chat', 'deepseek-reasoner'], (v) {
        cfg.aiModel = v;
        _commit();
      }),
      _textField('API 地址', _baseUrlCtrl, (v) {
        cfg.aiBaseUrl = v.trim().isEmpty ? 'https://api.deepseek.com/v1' : v.trim();
        _debouncedCommit();
      }),
      _slider('温度', '回复随机性：越高越有创造力。', cfg.aiTemperature, 0, 1.5, (v) {
        cfg.aiTemperature = v;
        _commit();
      }, (v) => v.toStringAsFixed(2)),
      _textField('人格文件(soul.md)', _soulFileCtrl, (v) {
        cfg.soulFile = v.trim();
        _debouncedCommit();
      }, hint: '留空自动检测 %APPDATA%/timepet/soul.md 或 exe 目录/soul.md',
        help: '插件化人格：soul.md 内容会整体作为角色设定注入 AI（支持 Markdown）。留空使用内置默认人格。'),
      _group('窗口', [
        _miniSwitch('置顶', cfg.alwaysOnTop, (v) { cfg.alwaysOnTop = v; _commit(); }),
        _miniSwitch('窗口贴合模型', cfg.autoFitWindow, (v) { cfg.autoFitWindow = v; _commit(); }, help: '启动时按模型比例自动调整窗口大小，避免大块透明留白。'),
        _miniSwitch('任务栏显示', !cfg.skipTaskbar, (v) { cfg.skipTaskbar = !v; _commit(); }),
        _miniSwitch('启动显示', cfg.startVisible, (v) { cfg.startVisible = v; _commit(); }),
      ]),
      _group('记忆', [
        _note('长期记忆 ${PetMemory.instance.memoryCount()} 条：对话中自动提取偏好/目标等，存本地 SQLite（mem.db），重启不丢失。'),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                PetDb.instance.clearMemories();
                setState(() {});
              },
              icon: const Icon(Icons.delete_outline_rounded, size: 16),
              label: const Text('清空长期记忆'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          ),
        ),
      ]),
      _note('API Key 通过环境变量 DEEPSEEK_API_KEY 提供，不写入配置文件。'),
    ]);
  }

  Widget _list(List<Widget> children) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      children: children,
    );
  }

  Widget _group(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.primary)),
          const SizedBox(height: 2),
          ...children,
        ],
      ),
    );
  }

  Widget _switch(String label, String help, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface)),
                if (help.isNotEmpty)
                  Text(help,
                      style: TextStyle(fontSize: 10.5, color: Theme.of(context).colorScheme.outline)),
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

  Widget _miniSwitch(String label, bool value, ValueChanged<bool> onChanged,
      {String help = ''}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface)),
                if (help.isNotEmpty)
                  Text(help,
                      style: TextStyle(
                          fontSize: 10,
                          color: Theme.of(context).colorScheme.outline)),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface)),
                    if (help.isNotEmpty)
                      Text(help,
                          style: TextStyle(fontSize: 10.5, color: scheme.outline)),
                  ],
                ),
              ),
              Text(format(value),
                  style: TextStyle(fontSize: 11.5, color: scheme.primary)),
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

  Widget _dropdown(
    String label,
    String value,
    List<String> items,
    ValueChanged<String> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface))),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: items.contains(value) ? value : items.first,
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface),
                dropdownColor: Theme.of(context).colorScheme.surfaceContainer,
                isDense: true,
                items: [
                  for (final it in items) DropdownMenuItem(value: it, child: Text(it)),
                ],
                onChanged: (v) {
                  if (v != null) onChanged(v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _textField(
    String label,
    TextEditingController controller,
    ValueChanged<String> onChanged, {
    String hint = '',
    String help = '',
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface)),
              ),
              if (help.isNotEmpty)
                Tooltip(
                  message: help,
                  child: Icon(Icons.help_outline_rounded, size: 15, color: Theme.of(context).colorScheme.outline),
                ),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: TextStyle(fontSize: 10.5, color: Theme.of(context).colorScheme.outline),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainer,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
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
      child: Text(text,
          style: TextStyle(
              fontSize: 10.5,
              height: 1.4,
              color: Theme.of(context).colorScheme.outline)),
    );
  }
}
