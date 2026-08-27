import 'package:flutter/material.dart';

import '../services/activity_history.dart';
import '../services/pet_config.dart';
import 'amadeus_theme.dart';

/// A dedicated observability surface for Amadeus' built-in activity stream.
///
/// This intentionally separates "what the agent observed" from "what the
/// agent remembers". The layout follows an event-stream mental model: current
/// status, derived projections, recent episodes, then source controls.
class ActivityWorkspace extends StatelessWidget {
  const ActivityWorkspace({
    super.key,
    required this.config,
    required this.excludedAppsController,
    required this.onChanged,
    required this.onClear,
    this.history,
  });

  final PetConfig config;
  final TextEditingController excludedAppsController;
  final VoidCallback onChanged;
  final VoidCallback onClear;
  final ActivityHistory? history;

  @override
  Widget build(BuildContext context) {
    final activityHistory = history ?? ActivityHistory.instance;
    ActivityPulse? pulse;
    List<ActivityEpisode> episodes = const [];
    try {
      pulse = activityHistory.pulse();
      episodes = activityHistory.recentEpisodes(limit: 8);
    } catch (_) {}

    return Column(
      children: [
        _hero(context, pulse),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final stacked = constraints.maxWidth < 680;
            final rhythm = _panel(
              context,
              title: '最近 7 天',
              subtitle: '由短期事件流实时生成，不进入长期记忆',
              child: _WeekBars(points: pulse?.days ?? const []),
            );
            final pipeline = _panel(
              context,
              title: '事件管线',
              subtitle: '采集、过滤与投影彼此解耦',
              child: const _PipelineView(),
            );
            if (stacked) {
              return Column(
                children: [rhythm, const SizedBox(height: 14), pipeline],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: rhythm),
                const SizedBox(width: 14),
                Expanded(flex: 2, child: pipeline),
              ],
            );
          },
        ),
        const SizedBox(height: 14),
        _panel(
          context,
          title: '活动片段',
          subtitle: '只展示应用级片段，不保存窗口标题或输入内容',
          trailing: TextButton.icon(
            onPressed: onClear,
            icon: const Icon(Icons.auto_delete_outlined, size: 18),
            label: const Text('按范围清理'),
          ),
          child: _timeline(context, episodes),
        ),
        const SizedBox(height: 14),
        _panel(
          context,
          title: '采集与保留',
          subtitle: '所有控制都在本机即时生效',
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用活动感知'),
                subtitle: const Text('关闭后停止采集；对话与长期记忆仍可使用。'),
                value: config.activityAwarenessEnabled,
                onChanged: (value) {
                  config.activityAwarenessEnabled = value;
                  if (!value) config.activityAwarenessPaused = false;
                  onChanged();
                },
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 15),
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('原始事件保留期'),
                          SizedBox(height: 3),
                          Text(
                            '过期事件每小时自动清理；会话投影同步删除。',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 260,
                      child: Row(
                        children: [
                          Expanded(
                            child: Slider(
                              value: config.activityRetentionHours
                                  .clamp(1, 168)
                                  .toDouble(),
                              min: 1,
                              max: 168,
                              divisions: 167,
                              onChanged: (value) {
                                config.activityRetentionHours = value.round();
                                onChanged();
                              },
                            ),
                          ),
                          SizedBox(
                            width: 62,
                            child: Text(
                              '${config.activityRetentionHours} 小时',
                              textAlign: TextAlign.end,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              const SizedBox(height: 15),
              TextField(
                controller: excludedAppsController,
                decoration: const InputDecoration(
                  labelText: '排除应用',
                  hintText: '1Password, Bitwarden, 银行客户端',
                  helperText: '使用逗号分隔。匹配到的事件会在 Rust 原生边界被丢弃。',
                  prefixIcon: Icon(Icons.visibility_off_outlined),
                ),
                onChanged: (value) {
                  config.activityExcludedApps = value
                      .split(RegExp(r'[,，\n]'))
                      .map((item) => item.trim())
                      .where((item) => item.isNotEmpty)
                      .toList(growable: false);
                  onChanged();
                },
              ),
              const SizedBox(height: 14),
              const _PrivacyBoundary(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _hero(BuildContext context, ActivityPulse? pulse) {
    final scheme = Theme.of(context).colorScheme;
    final running =
        config.activityAwarenessEnabled && !config.activityAwarenessPaused;
    final status = !config.activityAwarenessEnabled
        ? '观察能力已关闭'
        : (config.activityAwarenessPaused ? '已暂停，记录保持不变' : '正在理解你的工作节奏');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.18),
            scheme.tertiary.withValues(alpha: 0.08),
            scheme.surfaceContainerLow,
          ],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: (running ? AmadeusTheme.mint : scheme.outline)
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  running ? Icons.sensors_rounded : Icons.pause_rounded,
                  color: running ? AmadeusTheme.mint : scheme.outline,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Rust Core v1 · 本机追加事件流 · ${config.activityRetentionHours} 小时自动过期',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (config.activityAwarenessEnabled)
                FilledButton.tonalIcon(
                  onPressed: () {
                    config.activityAwarenessPaused =
                        !config.activityAwarenessPaused;
                    onChanged();
                  },
                  icon: Icon(
                    config.activityAwarenessPaused
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                  ),
                  label: Text(config.activityAwarenessPaused ? '恢复' : '暂停'),
                ),
            ],
          ),
          const SizedBox(height: 24),
          _metrics(context, pulse),
        ],
      ),
    );
  }

  Widget _metrics(BuildContext context, ActivityPulse? pulse) {
    final items = [
      ('今日活跃', _duration(pulse?.activeSeconds ?? 0), AmadeusTheme.wine),
      ('主要应用', pulse?.topApp ?? '暂无', AmadeusTheme.event),
      ('上下文切换', '${pulse?.switches ?? 0} 次', AmadeusTheme.focus),
      ('节奏稳定度', '${pulse?.focusScore ?? 0}', AmadeusTheme.memory),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 620 ? 2 : 4;
        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: columns == 4 ? 2.0 : 2.7,
          children: [
            for (final item in items)
              _MetricTile(label: item.$1, value: item.$2, color: item.$3),
          ],
        );
      },
    );
  }

  Widget _timeline(BuildContext context, List<ActivityEpisode> episodes) {
    if (episodes.isEmpty) {
      return const _WorkspaceEmpty(
        icon: Icons.history_toggle_off_outlined,
        title: '还没有可展示的活动片段',
        body: '产生两个连续采样后，这里会出现应用级时间线。',
      );
    }
    return Column(
      children: [
        for (var index = 0; index < episodes.length; index++) ...[
          _EpisodeRow(episode: episodes[index]),
          if (index < episodes.length - 1) const Divider(height: 1),
        ],
      ],
    );
  }

  Widget _panel(
    BuildContext context, {
    required String title,
    required Widget child,
    String? subtitle,
    Widget? trailing,
  }) {
    return Card(
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
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 18),
            child,
          ],
        ),
      ),
    );
  }

  static String _duration(int seconds) {
    if (seconds < 60) return '不到 1 分钟';
    final minutes = (seconds / 60).round();
    if (minutes < 60) return '$minutes 分钟';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分';
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.8)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _WeekBars extends StatelessWidget {
  const _WeekBars({required this.points});

  final List<ActivityDayPoint> points;

  @override
  Widget build(BuildContext context) {
    final values = points
        .map((point) => point.activeSeconds + point.idleSeconds)
        .toList();
    final maximum = values.fold<int>(
      1,
      (value, item) => item > value ? item : value,
    );
    final scheme = Theme.of(context).colorScheme;
    if (points.isEmpty) {
      return const SizedBox(
        height: 142,
        child: _WorkspaceEmpty(
          icon: Icons.bar_chart_rounded,
          title: '等待第一批事件',
          body: '图表会从本机投影视图生成。',
        ),
      );
    }
    return SizedBox(
      height: 156,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final point in points)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Tooltip(
                      message:
                          '${point.activeSeconds ~/ 60} 分钟活跃 · ${point.idleSeconds ~/ 60} 分钟空闲',
                      child: Container(
                        height: 112,
                        alignment: Alignment.bottomCenter,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: SizedBox(
                            width: 22,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 420),
                                  curve: Curves.easeOutCubic,
                                  height: point.idleSeconds / maximum * 100,
                                  color: scheme.outlineVariant,
                                ),
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 420),
                                  curve: Curves.easeOutCubic,
                                  height: point.activeSeconds == 0
                                      ? 4
                                      : point.activeSeconds / maximum * 100,
                                  color: AmadeusTheme.wine,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _weekday(point.date.weekday),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _weekday(int value) =>
      const ['一', '二', '三', '四', '五', '六', '日'][value - 1];
}

class _PipelineView extends StatelessWidget {
  const _PipelineView();

  @override
  Widget build(BuildContext context) {
    const steps = [
      (Icons.desktop_windows_outlined, '原生采集', '应用 + 空闲'),
      (Icons.shield_outlined, 'Rust 过滤', '先于落盘'),
      (Icons.view_timeline_outlined, '事件流', '短期追加'),
      (Icons.auto_graph_rounded, 'Flutter 投影', '图表 + 触发'),
    ];
    return Column(
      children: [
        for (var index = 0; index < steps.length; index++) ...[
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(steps[index].$1, size: 18),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  steps[index].$2,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                steps[index].$3,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          if (index < steps.length - 1)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 2,
                  height: 14,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({required this.episode});

  final ActivityEpisode episode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hour = episode.startedAt.hour.toString().padLeft(2, '0');
    final minute = episode.startedAt.minute.toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          CircleAvatar(
            radius: 17,
            backgroundColor: scheme.primary.withValues(alpha: 0.1),
            child: Text(
              episode.appName.characters.first.toUpperCase(),
              style: TextStyle(color: scheme.primary, fontSize: 12),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  episode.appName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  '$hour:$minute 开始',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              episode.durationText,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivacyBoundary extends StatelessWidget {
  const _PrivacyBoundary();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.tertiary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.tertiary.withValues(alpha: 0.2)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded, size: 19),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              '不采集截图、音频、窗口标题、文件路径、浏览记录或键盘输入。排除事件不会写入 activity.db。',
              style: TextStyle(fontSize: 13, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceEmpty extends StatelessWidget {
  const _WorkspaceEmpty({
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: scheme.outline, size: 26),
            const SizedBox(height: 9),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
