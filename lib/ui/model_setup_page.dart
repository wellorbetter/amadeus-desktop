import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../services/pet_config.dart';
import '../services/pet_model.dart';
import 'amadeus_theme.dart';

/// First-run onboarding for the independent Amadeus desktop companion.
class ModelSetupPage extends StatefulWidget {
  const ModelSetupPage({super.key});

  @override
  State<ModelSetupPage> createState() => _ModelSetupPageState();
}

class _ModelSetupPageState extends State<ModelSetupPage> {
  int _step = 0;
  bool _rightsConfirmed = false;
  String? _selectedPackagePath;
  String? _selectedEntryPath;
  String? _status;
  bool _busy = false;
  bool _done = false;
  bool _needsRestart = false;

  bool get _configuredPathMissing {
    final configured = PetConfig.instance.modelPath.trim();
    return configured.isNotEmpty && !File(configured).existsSync();
  }

  Future<void> _pickPackage() async {
    final packagePath = await getDirectoryPath(confirmButtonText: '选择此模型包');
    if (!mounted || packagePath == null) return;
    try {
      final inspected = await PetModel.inspectPackage(packagePath);
      setState(() {
        _selectedPackagePath = packagePath;
        _selectedEntryPath = inspected.entryPath;
        _status = '校验通过 · ${inspected.files} 个资源文件';
      });
    } catch (error) {
      setState(() => _status = '无法使用这个模型包：$error');
    }
  }

  Future<void> _import() async {
    final packagePath = _selectedPackagePath;
    if (packagePath == null || !_rightsConfirmed || _busy) return;
    setState(() {
      _busy = true;
      _status = '正在复制并校验模型资源…';
    });
    try {
      final result = await PetModel.importPackage(packagePath);
      if (!mounted) return;
      var notified = true;
      try {
        await const WindowMethodChannel(
          'pet',
          mode: ChannelMode.unidirectional,
        ).invokeMethod('config-changed');
      } catch (_) {
        notified = false;
      }
      setState(() {
        _busy = false;
        _done = true;
        _needsRestart = !notified;
        _status = '导入完成 · ${result.files} 个文件仅保存在本机';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '导入失败：$error';
      });
    }
  }

  Future<void> _close() => windowManager.close();

  Future<void> _restart() async {
    try {
      await const WindowMethodChannel(
        'pet',
        mode: ChannelMode.unidirectional,
      ).invokeMethod('restart');
    } catch (_) {
      await Process.start(
        Platform.resolvedExecutable,
        const [],
        mode: ProcessStartMode.detached,
      );
      await windowManager.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.surface,
              Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.06),
                scheme.surface,
              ),
            ],
          ),
        ),
        child: SafeArea(
          child: Row(
            children: [
              _OnboardingRail(step: _step),
              VerticalDivider(width: 1, color: scheme.outlineVariant),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(44, 36, 44, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const _BrandMark(),
                          const SizedBox(width: 12),
                          Text(
                            'AMADEUS',
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  letterSpacing: 2.4,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: _close,
                            child: const Text('稍后设置'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: switch (_step) {
                            0 => _intro(scheme),
                            1 => _privacy(scheme),
                            _ => _modelImport(scheme),
                          },
                        ),
                      ),
                      const SizedBox(height: 18),
                      _footer(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _intro(ColorScheme scheme) {
    return SingleChildScrollView(
      key: const ValueKey('intro'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _eyebrow('独立桌面伴侣'),
            const SizedBox(height: 12),
            Text(
              '让时间记录，变成一次有分寸的陪伴。',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Amadeus 是独立应用。TimeTrace 只是可选的本地数据源：没有它，桌宠仍能对话；连接后，它才会从聚合记录中理解你的节奏。',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.65,
              ),
            ),
            const SizedBox(height: 30),
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 600;
                final cards = [
                  const _FeatureCard(
                    icon: Icons.timeline_rounded,
                    title: '感知，但不监视',
                    body: '只读取 TimeTrace 聚合统计；窗口标题、截图和日记原文不进入对话。',
                  ),
                  const _FeatureCard(
                    icon: Icons.psychology_alt_outlined,
                    title: '记住，也能忘记',
                    body: '对话与长期记忆保存在本机，可在设置中查看并一键清除。',
                  ),
                  const _FeatureCard(
                    icon: Icons.notifications_active_outlined,
                    title: '由你决定何时开口',
                    body: '整点、久坐、空闲归来等触发器可分别关闭，并受频率上限约束。',
                  ),
                ];
                if (narrow) {
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
          ],
        ),
      ),
    );
  }

  Widget _privacy(ColorScheme scheme) {
    return SingleChildScrollView(
      key: const ValueKey('privacy'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _eyebrow('边界先于能力'),
            const SizedBox(height: 12),
            Text(
              '你控制形象、人格、数据与模型服务。',
              style: Theme.of(
                context,
              ).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 14),
            Text(
              '这四层彼此独立。更换 Live2D 形象不会改写人格；关闭 TimeTrace 也不会删除你的本地记忆。',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.6),
            ),
            const SizedBox(height: 24),
            const _BoundaryRow(
              number: '01',
              title: '形象资源',
              body: '只从你选择的文件夹导入，不随应用下载或上传。',
              color: AmadeusTheme.wine,
            ),
            const _BoundaryRow(
              number: '02',
              title: '人格设定',
              body: '默认使用原创 Amadeus 人格；自定义 soul.md 仅保存在本机。',
              color: AmadeusTheme.blueGrey,
            ),
            const _BoundaryRow(
              number: '03',
              title: 'TimeTrace 数据',
              body: '可选、只读、仅聚合；断开后立即降级为普通桌宠。',
              color: AmadeusTheme.mint,
            ),
            const _BoundaryRow(
              number: '04',
              title: '对话服务',
              body: '由你选择提供商并配置 API Key；调用范围在设置页可见。',
              color: Color(0xFFC6A867),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelImport(ColorScheme scheme) {
    return SingleChildScrollView(
      key: const ValueKey('model'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _eyebrow('本地形象'),
            const SizedBox(height: 12),
            Text(
              '先让你的桌面伴侣出现。',
              style: Theme.of(
                context,
              ).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              '选择一个完整的 Live2D Cubism 2.1 模型包。Amadeus 会校验模型本体、贴图、动作、表情、物理与音效引用。',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.6),
            ),
            if (_configuredPathMissing) ...[
              const SizedBox(height: 18),
              _Notice(
                icon: Icons.link_off_rounded,
                color: scheme.error,
                text: '之前配置的模型已经不可用。重新导入后会自动修复路径。',
              ),
            ],
            const SizedBox(height: 22),
            _DropZone(
              selectedPath: _selectedPackagePath,
              entryPath: _selectedEntryPath,
              onPressed: _busy ? null : _pickPackage,
            ),
            const SizedBox(height: 16),
            Card(
              child: CheckboxListTile(
                value: _rightsConfirmed,
                onChanged: _busy
                    ? null
                    : (value) =>
                          setState(() => _rightsConfirmed = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('我确认有权在本机使用所选形象资源'),
                subtitle: const Text('本机使用权不等于公开分发或商用权。Amadeus 不会把这个模型加入安装包。'),
              ),
            ),
            if (_status != null) ...[
              const SizedBox(height: 14),
              _Notice(
                icon: _done ? Icons.check_circle_outline : Icons.info_outline,
                color: _done ? scheme.tertiary : scheme.secondary,
                text: _status!,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _footer() {
    return Row(
      children: [
        if (_step > 0 && !_done)
          TextButton.icon(
            onPressed: _busy ? null : () => setState(() => _step--),
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text('上一步'),
          ),
        const Spacer(),
        if (_step < 2)
          FilledButton.icon(
            onPressed: () => setState(() => _step++),
            icon: const Icon(Icons.arrow_forward_rounded, size: 18),
            label: Text(_step == 0 ? '了解数据边界' : '选择本地形象'),
          )
        else if (!_done)
          FilledButton.icon(
            onPressed:
                _selectedPackagePath == null || !_rightsConfirmed || _busy
                ? null
                : _import,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_download_done_rounded, size: 18),
            label: const Text('导入并使用'),
          )
        else ...[
          if (_needsRestart)
            OutlinedButton.icon(
              onPressed: _restart,
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('重启并加载'),
            ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: _close,
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('开始使用 Amadeus'),
          ),
        ],
      ],
    );
  }

  Widget _eyebrow(String text) => Text(
    text.toUpperCase(),
    style: TextStyle(
      color: Theme.of(context).colorScheme.primary,
      fontSize: 12,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.3,
    ),
  );
}

class _OnboardingRail extends StatelessWidget {
  const _OnboardingRail({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const labels = ['认识 Amadeus', '数据与权利', '导入形象'];
    const icons = [
      Icons.auto_awesome_rounded,
      Icons.shield_outlined,
      Icons.view_in_ar_outlined,
    ];
    return Container(
      width: 220,
      color: scheme.surfaceContainerLowest.withValues(alpha: 0.72),
      padding: const EdgeInsets.fromLTRB(24, 42, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '初始设置',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 28),
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: i == step
                      ? scheme.primary.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      icons[i],
                      size: 18,
                      color: i <= step ? scheme.primary : scheme.outline,
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        labels[i],
                        style: TextStyle(
                          color: i == step
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                          fontWeight: i == step
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const Spacer(),
          Text(
            '所有选择稍后都能在设置中修改。',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) => Container(
    width: 34,
    height: 34,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [AmadeusTheme.wineLight, AmadeusTheme.wine],
      ),
      borderRadius: BorderRadius.circular(11),
      boxShadow: [
        BoxShadow(
          color: AmadeusTheme.wine.withValues(alpha: 0.28),
          blurRadius: 18,
          offset: const Offset(0, 7),
        ),
      ],
    ),
    child: const Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 20),
  );
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: scheme.primary),
            const SizedBox(height: 18),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 7),
            Text(
              body,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13,
                height: 1.55,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BoundaryRow extends StatelessWidget {
  const _BoundaryRow({
    required this.number,
    required this.title,
    required this.body,
    required this.color,
  });

  final String number;
  final String title;
  final String body;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Text(
                  number,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      body,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DropZone extends StatelessWidget {
  const _DropZone({
    required this.selectedPath,
    required this.entryPath,
    required this.onPressed,
  });

  final String? selectedPath;
  final String? entryPath;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.folder_open_rounded, color: scheme.primary),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  selectedPath == null ? '选择完整模型包' : '已选择模型包',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  selectedPath == null
                      ? '支持包含一个 *.model.json 的 Cubism 2.1 目录'
                      : '$selectedPath\n入口：${entryPath ?? '自动识别'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          OutlinedButton(onPressed: onPressed, child: const Text('选择模型包')),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.24)),
    ),
    child: Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      ],
    ),
  );
}
