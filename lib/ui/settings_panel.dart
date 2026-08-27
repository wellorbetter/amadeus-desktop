import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../services/activity_history.dart';
import '../services/pet_config.dart';
import '../services/pet_db.dart';
import '../services/pet_logger.dart';
import '../services/pet_memory.dart';
import 'activity_workspace.dart';
import 'amadeus_theme.dart';

enum _SettingsSection {
  overview,
  appearance,
  activity,
  interaction,
  intelligence,
  privacy,
}

extension on _SettingsSection {
  String get label => switch (this) {
    _SettingsSection.overview => 'Agent 概览',
    _SettingsSection.appearance => '形象与外观',
    _SettingsSection.activity => '活动工作台',
    _SettingsSection.interaction => '主动性',
    _SettingsSection.intelligence => '能力与人格',
    _SettingsSection.privacy => '记忆与隐私',
  };

  IconData get icon => switch (this) {
    _SettingsSection.overview => Icons.space_dashboard_outlined,
    _SettingsSection.appearance => Icons.palette_outlined,
    _SettingsSection.activity => Icons.monitor_heart_outlined,
    _SettingsSection.interaction => Icons.notifications_active_outlined,
    _SettingsSection.intelligence => Icons.psychology_alt_outlined,
    _SettingsSection.privacy => Icons.shield_outlined,
  };

  String get description => switch (this) {
    _SettingsSection.overview => '运行状态与关键入口',
    _SettingsSection.appearance => '本地形象、窗口和气泡',
    _SettingsSection.activity => '观察状态、节奏投影与来源控制',
    _SettingsSection.interaction => '触发条件、频率和休眠',
    _SettingsSection.intelligence => '对话服务与人格边界',
    _SettingsSection.privacy => '本地数据、日志与系统行为',
  };
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.onClose,
    this.config,
    this.activityHistory,
  });

  final VoidCallback? onClose;
  final PetConfig? config;
  final ActivityHistory? activityHistory;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  PetConfig get cfg => widget.config ?? PetConfig.instance;

  _SettingsSection _section = _SettingsSection.overview;
  Timer? _commitTimer;
  bool _disposing = false;
  bool _apiKeyVisible = false;
  bool _navCollapsed = false;
  bool _savePending = false;

  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _apiKey = TextEditingController();
  final _modelPath = TextEditingController();
  final _soulFile = TextEditingController();
  final _soulText = TextEditingController();
  final _excludedApps = TextEditingController();

  @override
  void initState() {
    super.initState();
    _navCollapsed = cfg.settingsSidebarCollapsed;
    _syncControllers();
  }

  void _syncControllers() {
    _baseUrl.text = cfg.aiBaseUrl;
    _model.text = cfg.aiModel;
    _apiKey.text = cfg.aiApiKey;
    _modelPath.text = cfg.modelPath;
    _soulFile.text = cfg.soulFile;
    _soulText.text = cfg.soulText;
    _excludedApps.text = cfg.activityExcludedApps.join(', ');
  }

  @override
  void dispose() {
    _disposing = true;
    _commitTimer?.cancel();
    _saveNow();
    for (final controller in [
      _baseUrl,
      _model,
      _apiKey,
      _modelPath,
      _soulFile,
      _soulText,
      _excludedApps,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _commit() {
    _commitTimer?.cancel();
    _commitTimer = Timer(const Duration(milliseconds: 350), _saveNow);
    if (mounted) setState(() => _savePending = true);
  }

  void _saveNow() {
    cfg.save();
    PetLog.i('settings: committed');
    try {
      const WindowMethodChannel(
        'pet',
        mode: ChannelMode.unidirectional,
      ).invokeMethod('config-changed').catchError((_) {});
    } catch (_) {}
    if (mounted && !_disposing) setState(() => _savePending = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.surface,
              Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.045),
                scheme.surface,
              ),
            ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 820;
              return Column(
                children: [
                  _titleBar(compact),
                  Divider(height: 1, color: scheme.outlineVariant),
                  Expanded(
                    child: compact
                        ? Column(
                            children: [
                              _compactNavigation(),
                              Expanded(child: _content(compact: true)),
                            ],
                          )
                        : Row(
                            children: [
                              _navigationRail(),
                              VerticalDivider(
                                width: 1,
                                color: scheme.outlineVariant,
                              ),
                              Expanded(child: _content(compact: false)),
                            ],
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _titleBar(bool compact) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AmadeusTheme.wineLight, AmadeusTheme.wine],
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.graphic_eq_rounded,
                size: 19,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 11),
            Text(
              'Amadeus',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
            if (!compact) ...[
              const SizedBox(width: 10),
              Container(width: 1, height: 18, color: scheme.outlineVariant),
              const SizedBox(width: 10),
              Text('设置', style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
            const Spacer(),
            if (!compact) ...[
              _StatusPill(
                color: _savePending ? scheme.secondary : AmadeusTheme.sage,
                text: _savePending ? '正在保存' : '已保存',
              ),
              const SizedBox(width: 8),
            ],
            _StatusPill(
              color: cfg.aiEnabled ? AmadeusTheme.mint : scheme.outline,
              text: cfg.aiEnabled ? 'AI 已启用' : 'AI 已暂停',
            ),
            const SizedBox(width: 8),
            if (widget.onClose != null)
              IconButton(
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded),
                tooltip: '关闭',
              ),
          ],
        ),
      ),
    );
  }

  Widget _navigationRail() {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: _navCollapsed ? 78 : 224,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
        child: Column(
          children: [
            for (final item in _SettingsSection.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: _NavTile(
                  selected: item == _section,
                  icon: item.icon,
                  label: item.label,
                  compact: _navCollapsed,
                  onTap: () => setState(() => _section = item),
                ),
              ),
            const Spacer(),
            if (!_navCollapsed)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Text(
                  'Rust 在落盘前过滤，Flutter 只消费本机短期事件流与投影视图。',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Tooltip(
              message: _navCollapsed ? '展开侧边栏' : '收起侧边栏',
              child: IconButton(
                onPressed: () {
                  setState(() => _navCollapsed = !_navCollapsed);
                  cfg.settingsSidebarCollapsed = _navCollapsed;
                  _commit();
                },
                icon: Icon(
                  _navCollapsed
                      ? Icons.keyboard_double_arrow_right_rounded
                      : Icons.keyboard_double_arrow_left_rounded,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _compactNavigation() {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          for (final item in _SettingsSection.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                selected: item == _section,
                avatar: Icon(item.icon, size: 17),
                label: Text(item.label),
                onSelected: (_) => setState(() => _section = item),
                side: BorderSide(color: scheme.outlineVariant),
              ),
            ),
        ],
      ),
    );
  }

  Widget _content({required bool compact}) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.018, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: SingleChildScrollView(
        key: ValueKey(_section),
        padding: compact
            ? const EdgeInsets.fromLTRB(18, 20, 18, 36)
            : const EdgeInsets.fromLTRB(32, 28, 32, 44),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _section.label,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _section.description,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                switch (_section) {
                  _SettingsSection.overview => _overview(),
                  _SettingsSection.appearance => _appearance(),
                  _SettingsSection.activity => _activity(),
                  _SettingsSection.interaction => _interaction(),
                  _SettingsSection.intelligence => _intelligence(),
                  _SettingsSection.privacy => _privacy(),
                },
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _overview() {
    final scheme = Theme.of(context).colorScheme;
    final modelReady = cfg.modelPath.trim().isNotEmpty;
    final keyReady = cfg.aiApiKey.trim().isNotEmpty;
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final stacked = constraints.maxWidth < 650;
            final cards = [
              _OverviewCard(
                icon: Icons.view_in_ar_outlined,
                title: '本地形象',
                value: modelReady ? '已配置' : '待导入',
                detail: modelReady ? '模型资源留在本机' : '导入一个拥有使用权的模型包',
                color: modelReady ? AmadeusTheme.mint : scheme.secondary,
                onTap: () =>
                    setState(() => _section = _SettingsSection.appearance),
              ),
              _OverviewCard(
                icon: Icons.psychology_alt_outlined,
                title: '对话服务',
                value: cfg.aiEnabled && keyReady ? '可用' : '待配置',
                detail: cfg.aiEnabled ? cfg.aiModel : '当前已暂停全部在线调用',
                color: keyReady ? AmadeusTheme.wine : scheme.secondary,
                onTap: () =>
                    setState(() => _section = _SettingsSection.intelligence),
              ),
              _OverviewCard(
                icon: Icons.memory_outlined,
                title: '长期记忆',
                value: '${_memoryCount()} 条',
                detail: '仅保存在本机 SQLite',
                color: AmadeusTheme.blueGrey,
                onTap: () =>
                    setState(() => _section = _SettingsSection.privacy),
              ),
              _OverviewCard(
                icon: Icons.timeline_rounded,
                title: '活动感知',
                value: !cfg.activityAwarenessEnabled
                    ? '已关闭'
                    : (cfg.activityAwarenessPaused ? '已暂停' : '运行中'),
                detail: '原始事件保留 ${cfg.activityRetentionHours} 小时',
                color:
                    cfg.activityAwarenessEnabled && !cfg.activityAwarenessPaused
                    ? AmadeusTheme.mint
                    : scheme.outline,
                onTap: () =>
                    setState(() => _section = _SettingsSection.activity),
              ),
            ];
            if (stacked) {
              return Column(
                children: [
                  for (final card in cards)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: card,
                    ),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  Expanded(child: cards[i]),
                  if (i < cards.length - 1) const SizedBox(width: 12),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        _SettingsCard(
          title: '产品结构',
          subtitle: '观察能力已经进入 Amadeus 本体，TimeTrace 仅用于兼容旧数据。',
          child: Column(
            children: const [
              _ArchitectureRow(
                icon: Icons.desktop_windows_outlined,
                title: 'Amadeus 桌面端',
                body: '窗口、触发器、记忆、人格和 AI 连接',
                badge: '独立应用',
              ),
              Divider(height: 24),
              _ArchitectureRow(
                icon: Icons.timeline_rounded,
                title: '内置活动感知',
                body: '前台应用、活跃与空闲事件；不采集截图、声音和输入内容',
                badge: '本机能力',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _appearance() => Column(
    children: [
      _SettingsCard(
        title: '形象资源',
        subtitle: '路径只指向本机文件，不会进入安装包或上传网络。',
        child: _field(
          label: 'Live2D 模型路径',
          controller: _modelPath,
          hint: '留空时扫描用户数据目录中的 models 文件夹',
          onChanged: (value) {
            cfg.modelPath = value.trim();
            _commit();
          },
        ),
      ),
      const SizedBox(height: 14),
      _SettingsCard(
        title: '显示',
        subtitle: '调整会实时同步到桌宠窗口。',
        child: Column(
          children: [
            _switchRow('深色设置界面', '只影响设置窗口，不改变模型素材。', cfg.darkMode, (v) {
              cfg.darkMode = v;
              _commit();
            }),
            _sliderRow('设置窗口透明度', cfg.settingsOpacity, 0.75, 1, (v) {
              cfg.settingsOpacity = v;
              windowManager.setOpacity(v);
              _commit();
            }, (v) => '${(v * 100).round()}%'),
            _sliderRow('模型大小', cfg.modelScale, 0.7, 3, (v) {
              cfg.modelScale = v;
              _commit();
            }, (v) => '${(v * 100).round()}%'),
            _sliderRow('模型垂直偏移', cfg.vOffset.toDouble(), -160, 160, (v) {
              cfg.vOffset = v.round();
              _commit();
            }, (v) => '${v.round()} px'),
            _sliderRow('模型透明度', cfg.modelOpacity, 0.3, 1, (v) {
              cfg.modelOpacity = v;
              _commit();
            }, (v) => '${(v * 100).round()}%'),
            _sliderRow('气泡字号', cfg.bubbleFontSize, 10, 18, (v) {
              cfg.bubbleFontSize = v;
              _commit();
            }, (v) => v.toStringAsFixed(1)),
            _sliderRow('气泡显示时长', cfg.bubbleAutoHideSeconds.toDouble(), 3, 30, (
              v,
            ) {
              cfg.bubbleAutoHideSeconds = v.round();
              _commit();
            }, (v) => '${v.round()} 秒'),
          ],
        ),
      ),
    ],
  );

  Widget _activity() => ActivityWorkspace(
    config: cfg,
    excludedAppsController: _excludedApps,
    onChanged: _commit,
    onClear: _confirmClearActivity,
    history: widget.activityHistory,
  );

  Widget _interaction() => Column(
    children: [
      _SettingsCard(
        title: '主动互动',
        subtitle: '总开关关闭后，Amadeus 只在你主动发起对话时响应。',
        child: Column(
          children: [
            _switchRow('允许主动开口', '仍受最小间隔与每小时上限约束。', cfg.proactiveEnabled, (v) {
              cfg.proactiveEnabled = v;
              _commit();
            }),
            _sliderRow('最小间隔', cfg.minIntervalMinutes, 5, 120, (v) {
              cfg.minIntervalMinutes = v;
              _commit();
            }, (v) => '${v.round()} 分钟'),
            _sliderRow('每小时上限', cfg.maxPerHour.toDouble(), 1, 10, (v) {
              cfg.maxPerHour = v.round();
              _commit();
            }, (v) => '${v.round()} 次'),
            _sliderRow('久坐阈值', cfg.longSessionMinutes.toDouble(), 30, 300, (v) {
              cfg.longSessionMinutes = v.round();
              _commit();
            }, (v) => '${v.round()} 分钟'),
          ],
        ),
      ),
      const SizedBox(height: 14),
      _SettingsCard(
        title: '触发条件',
        subtitle: '每个条件可以独立关闭。触发只决定“是否请求”，不会绕过频率上限。',
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _triggerChip(
              '整点',
              Icons.schedule_rounded,
              cfg.triggerHourly,
              (v) => cfg.triggerHourly = v,
            ),
            _triggerChip(
              '深夜',
              Icons.bedtime_outlined,
              cfg.triggerLateNight,
              (v) => cfg.triggerLateNight = v,
            ),
            _triggerChip(
              '久坐',
              Icons.airline_seat_recline_normal,
              cfg.triggerLongSession,
              (v) => cfg.triggerLongSession = v,
            ),
            _triggerChip(
              '切窗激增',
              Icons.swap_horiz_rounded,
              cfg.triggerAppSwitchSpike,
              (v) => cfg.triggerAppSwitchSpike = v,
            ),
            _triggerChip(
              '随机搭话',
              Icons.casino_outlined,
              cfg.triggerRandomNudge,
              (v) => cfg.triggerRandomNudge = v,
            ),
            _triggerChip(
              '空闲归来',
              Icons.waving_hand_outlined,
              cfg.triggerIdleReturn,
              (v) => cfg.triggerIdleReturn = v,
            ),
            _triggerChip(
              '专注提醒',
              Icons.center_focus_strong_outlined,
              cfg.triggerFocusReminder,
              (v) => cfg.triggerFocusReminder = v,
            ),
            _triggerChip(
              '记忆关心',
              Icons.favorite_border_rounded,
              cfg.triggerMemoryNudge,
              (v) => cfg.triggerMemoryNudge = v,
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      _SettingsCard(
        title: '休眠与打扰控制',
        subtitle: '空闲休眠期间不会调用 AI。',
        child: Column(
          children: [
            _switchRow('空闲时休眠', '回来后自动唤醒。', cfg.sleepEnabled, (v) {
              cfg.sleepEnabled = v;
              _commit();
            }),
            _switchRow('忙时减少打扰', '活跃时间较长时自动拉长互动间隔。', cfg.adaptiveFrequency, (
              v,
            ) {
              cfg.adaptiveFrequency = v;
              _commit();
            }),
            _sliderRow('休眠阈值', cfg.sleepIdleMinutes.toDouble(), 5, 60, (v) {
              cfg.sleepIdleMinutes = v.round();
              _commit();
            }, (v) => '${v.round()} 分钟'),
          ],
        ),
      ),
    ],
  );

  Widget _intelligence() => Column(
    children: [
      _SettingsCard(
        title: '对话服务',
        subtitle: 'ChatGPT / Codex 的订阅登录不能直接作为第三方桌面应用的 API 凭据。',
        trailing: Switch(
          value: cfg.aiEnabled,
          onChanged: (v) {
            cfg.aiEnabled = v;
            _commit();
          },
        ),
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              initialValue: _providerValue,
              decoration: const InputDecoration(labelText: '接入方式'),
              items: const [
                DropdownMenuItem(
                  value: 'openai_api_key',
                  child: Text('OpenAI API Key'),
                ),
                DropdownMenuItem(
                  value: 'deepseek_api_key',
                  child: Text('DeepSeek API Key'),
                ),
                DropdownMenuItem(
                  value: 'custom',
                  child: Text('自定义 OpenAI 兼容接口'),
                ),
              ],
              onChanged: (value) {
                if (value == null) return;
                cfg.aiAuthMode = value;
                if (value == 'openai_api_key') {
                  cfg.aiBaseUrl = 'https://api.openai.com/v1';
                } else if (value == 'deepseek_api_key') {
                  cfg.aiBaseUrl = 'https://api.deepseek.com/v1';
                  if (cfg.aiModel.startsWith('gpt-')) {
                    cfg.aiModel = 'deepseek-chat';
                  }
                }
                _baseUrl.text = cfg.aiBaseUrl;
                _model.text = cfg.aiModel;
                _commit();
              },
            ),
            const SizedBox(height: 12),
            _field(
              label: 'API Key',
              controller: _apiKey,
              obscureText: !_apiKeyVisible,
              suffix: IconButton(
                onPressed: () =>
                    setState(() => _apiKeyVisible = !_apiKeyVisible),
                icon: Icon(
                  _apiKeyVisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                tooltip: _apiKeyVisible ? '隐藏' : '显示',
              ),
              onChanged: (value) {
                cfg.aiApiKey = value.trim();
                _commit();
              },
            ),
            const SizedBox(height: 12),
            _field(
              label: 'Base URL',
              controller: _baseUrl,
              onChanged: (value) {
                cfg.aiBaseUrl = value.trim();
                _commit();
              },
            ),
            const SizedBox(height: 12),
            _field(
              label: '模型名称',
              controller: _model,
              onChanged: (value) {
                cfg.aiModel = value.trim();
                _commit();
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _sliderRow(
                    '温度',
                    cfg.aiTemperature,
                    0,
                    2,
                    (v) {
                      cfg.aiTemperature = v;
                      _commit();
                    },
                    (v) => v.toStringAsFixed(1),
                    showDivider: false,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _sliderRow(
                    '回复上限',
                    cfg.aiMaxTokens.toDouble(),
                    100,
                    2000,
                    (v) {
                      cfg.aiMaxTokens = v.round();
                      _commit();
                    },
                    (v) => '${v.round()} tokens',
                    showDivider: false,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      _SettingsCard(
        title: '人格设定',
        subtitle: '留空时使用原创 Amadeus 默认人格；自定义内容不会随仓库或安装包分发。',
        child: Column(
          children: [
            _field(
              label: 'soul.md 路径（可选）',
              controller: _soulFile,
              onChanged: (value) {
                cfg.soulFile = value.trim();
                _commit();
              },
            ),
            const SizedBox(height: 12),
            _field(
              label: '人格说明',
              controller: _soulText,
              maxLines: 7,
              hint: '描述称呼、语气、边界与不希望发生的行为…',
              onChanged: (value) {
                cfg.soulText = value;
                _commit();
              },
            ),
            const SizedBox(height: 12),
            _InfoBanner(
              icon: Icons.copyright_outlined,
              text: '使用第三方角色设定时，请确认你拥有相应使用权；个人本地使用权不自动包含公开发布或商业使用。',
              color: Theme.of(context).colorScheme.secondary,
            ),
          ],
        ),
      ),
    ],
  );

  Widget _privacy() => Column(
    children: [
      _SettingsCard(
        title: '数据边界',
        subtitle: '在线请求只包含对话所需的文本语料。',
        child: const Column(
          children: [
            _ArchitectureRow(
              icon: Icons.visibility_off_outlined,
              title: '不会采集',
              body: '窗口标题、截图、音频、键盘内容、文件路径与浏览历史',
              badge: 'Not collected',
            ),
            Divider(height: 24),
            _ArchitectureRow(
              icon: Icons.lock_outline_rounded,
              title: '只留在本机',
              body: '模型资源、API Key、活动原始事件、数据库与长期记忆',
              badge: 'Local only',
            ),
            Divider(height: 24),
            _ArchitectureRow(
              icon: Icons.cloud_outlined,
              title: '发送到所选 AI 服务',
              body: '你的消息、必要的近期对话，以及可选的活动聚合摘要',
              badge: '可控',
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      _SettingsCard(
        title: '本地记忆',
        subtitle: '${_memoryCount()} 条长期记忆 · ${PetDb.instance.path}',
        trailing: TextButton.icon(
          onPressed: _memoryCount() == 0 ? null : _confirmClearMemories,
          icon: const Icon(Icons.delete_outline_rounded, size: 18),
          label: const Text('清除'),
        ),
        child: _memoryPreview(),
      ),
      const SizedBox(height: 14),
      _SettingsCard(
        title: '系统行为',
        child: Column(
          children: [
            _switchRow('桌宠始终置顶', '设置窗口不受此项影响。', cfg.alwaysOnTop, (v) {
              cfg.alwaysOnTop = v;
              _commit();
            }),
            _switchRow('窗口适应模型', '按实际绘制区域收紧透明窗口。', cfg.autoFitWindow, (v) {
              cfg.autoFitWindow = v;
              _commit();
            }),
            _switchRow('启动时显示', '关闭后从系统托盘唤出。', cfg.startVisible, (v) {
              cfg.startVisible = v;
              _commit();
            }),
            _switchRow('记录诊断日志', '日志只保存在用户数据目录。', cfg.logEnabled, (v) {
              cfg.logEnabled = v;
              _commit();
            }, showDivider: false),
          ],
        ),
      ),
      const SizedBox(height: 18),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _confirmReset,
          icon: const Icon(Icons.restore_rounded, size: 18),
          label: const Text('恢复默认设置'),
        ),
      ),
    ],
  );

  String get _providerValue => switch (cfg.aiAuthMode) {
    'openai_api_key' || 'deepseek_api_key' || 'custom' => cfg.aiAuthMode,
    _ => 'custom',
  };

  int _memoryCount() {
    try {
      if (!PetDb.instance.initialized) return 0;
      return PetMemory.instance.memoryCount();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _confirmClearActivity() async {
    final range = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('清理活动时间线'),
        children: [
          for (final option in const [
            ('10m', '最近 10 分钟'),
            ('1h', '最近 1 小时'),
            ('1d', '最近 1 天'),
            ('all', '全部活动历史'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, option.$1),
              child: Text(option.$2),
            ),
        ],
      ),
    );
    if (range == null) return;
    final now = DateTime.now();
    final since = switch (range) {
      '10m' => now.subtract(const Duration(minutes: 10)),
      '1h' => now.subtract(const Duration(hours: 1)),
      '1d' => now.subtract(const Duration(days: 1)),
      _ => null,
    };
    (widget.activityHistory ?? ActivityHistory.instance).clearSince(since);
    if (mounted) setState(() {});
  }

  Widget _memoryPreview() {
    try {
      final rows = PetMemory.instance.recentMemoryRows(limit: 4);
      if (rows.isEmpty) {
        return const _EmptyState(
          icon: Icons.memory_outlined,
          title: '还没有长期记忆',
          body: 'Amadeus 只会保存未来有帮助的稳定偏好、目标或重要事件。',
        );
      }
      return Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.circle, size: 8),
              title: Text(
                '${rows[i]['content']}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${rows[i]['category']} · 重要度 ${rows[i]['importance']}',
              ),
            ),
            if (i < rows.length - 1) const Divider(height: 1),
          ],
        ],
      );
    } catch (_) {
      return const _EmptyState(
        icon: Icons.memory_outlined,
        title: '记忆库尚未初始化',
        body: '启动桌宠后会自动创建本地记忆库。',
      );
    }
  }

  Future<void> _confirmClearMemories() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除长期记忆？'),
        content: const Text('这会删除自动提取的偏好、目标和事件。近期对话不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      PetDb.instance.clearMemories();
      setState(() {});
    }
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复默认设置？'),
        content: const Text('模型路径、人格内容和 AI 连接信息也会被清除。本地记忆不会删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (ok == true) {
      _commitTimer?.cancel();
      cfg.resetToDefaults();
      _syncControllers();
      _saveNow();
    }
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
    String? hint,
    bool obscureText = false,
    Widget? suffix,
    int maxLines = 1,
  }) => TextField(
    controller: controller,
    obscureText: obscureText,
    maxLines: obscureText ? 1 : maxLines,
    onChanged: onChanged,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      suffixIcon: suffix,
      alignLabelWithHint: maxLines > 1,
    ),
  );

  Widget _switchRow(
    String title,
    String detail,
    bool value,
    ValueChanged<bool>? onChanged, {
    bool showDivider = true,
  }) => Column(
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
        subtitle: Text(detail),
        value: value,
        onChanged: onChanged,
      ),
      if (showDivider) const Divider(height: 1),
    ],
  );

  Widget _sliderRow(
    String title,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
    String Function(double) format, {
    bool showDivider = true,
  }) {
    final safe = value.clamp(min, max).toDouble();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 13),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                  Text(
                    format(safe),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              Slider(value: safe, min: min, max: max, onChanged: onChanged),
            ],
          ),
        ),
        if (showDivider) const Divider(height: 1),
      ],
    );
  }

  Widget _triggerChip(
    String label,
    IconData icon,
    bool selected,
    ValueChanged<bool> update,
  ) => FilterChip(
    selected: selected,
    avatar: Icon(icon, size: 17),
    label: Text(label),
    onSelected: (value) {
      update(value);
      _commit();
    },
  );
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
    this.compact = false,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tile = Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 12,
            vertical: 11,
          ),
          child: Row(
            mainAxisAlignment: compact
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 19,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              if (!compact) ...[
                const SizedBox(width: 11),
                Text(
                  label,
                  style: TextStyle(
                    color: selected
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return compact ? Tooltip(message: label, child: tile) : tile;
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    ),
  );
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.detail,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final String detail;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: color, size: 21),
                  const Spacer(),
                  Icon(
                    Icons.arrow_forward_rounded,
                    color: scheme.outline,
                    size: 17,
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Text(
                title,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArchitectureRow extends StatelessWidget {
  const _ArchitectureRow({
    required this.icon,
    required this.title,
    required this.body,
    required this.badge,
  });

  final IconData icon;
  final String title;
  final String body;
  final String badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, color: scheme.primary, size: 21),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(
                body,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _StatusPill(color: scheme.secondary, text: badge),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.22)),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
    ),
  );
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.09),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.2)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 13, height: 1.45)),
        ),
      ],
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Column(
          children: [
            Icon(icon, color: scheme.outline, size: 28),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
