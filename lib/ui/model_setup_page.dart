import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../services/pet_model.dart';
import '../services/pet_config.dart';

/// First-run model onboarding. It only imports a file selected by the user;
/// it never downloads or bundles third-party model assets.
class ModelSetupPage extends StatefulWidget {
  const ModelSetupPage({super.key});

  @override
  State<ModelSetupPage> createState() => _ModelSetupPageState();
}

class _ModelSetupPageState extends State<ModelSetupPage> {
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
        _status = '已识别完整模型包：${inspected.files} 个资源文件，可导入。';
      });
    } catch (e) {
      setState(() => _status = '模型包校验失败：$e');
    }
  }

  Future<void> _import() async {
    final packagePath = _selectedPackagePath;
    if (packagePath == null || _busy) return;
    setState(() {
      _busy = true;
      _status = '正在校验模型包及其本体、贴图、动作、表情、物理和音效…';
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
        _status = '导入完成：${result.files} 个资源文件已安装。';
        _needsRestart = !notified;
      });
      if (!notified) {
        setState(() => _status = '导入成功，但主桌宠未收到通知。请点击“重启并加载模型”。');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '导入失败：$e';
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
        [],
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
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.auto_awesome_rounded,
                          size: 36,
                          color: scheme.primary,
                        ),
                        if (_configuredPathMissing) ...[
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: scheme.errorContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '配置的模型不可用。当前桌宠会暂时使用备用模型；请导入一个可用模型来替换它。',
                              style: TextStyle(color: scheme.onErrorContainer),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Text(
                          '先让她来到桌面上',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'TimePet 需要一个你拥有使用权的 Live2D Cubism 2.1 模型包。请选择包含完整资源的模型目录；程序会自动识别入口并校验模型本体、贴图、动作、表情、物理和音效。',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const _InfoRow(
                          icon: Icons.verified_user_outlined,
                          text: '只导入你有权使用和再分发的模型',
                        ),
                        const _InfoRow(
                          icon: Icons.account_tree_outlined,
                          text: '导入的是完整模型包；入口配置只是内部文件，缺少资源会阻止导入',
                        ),
                        const _InfoRow(
                          icon: Icons.folder_copy_outlined,
                          text: r'安装位置：%APPDATA%\timepet\models',
                        ),
                        const _InfoRow(
                          icon: Icons.cloud_off_outlined,
                          text: '不会自动下载模型，也不会把模型上传到网络',
                        ),
                        const SizedBox(height: 22),
                        if (_selectedPackagePath != null)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '模型包：$_selectedPackagePath\n入口：${_selectedEntryPath ?? '自动识别'}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        if (_status != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _status!,
                            style: TextStyle(
                              color: _done
                                  ? Colors.green
                                  : scheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: _busy ? null : _close,
                              child: const Text('稍后设置'),
                            ),
                            const SizedBox(width: 10),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _pickPackage,
                              icon: const Icon(Icons.folder_open_rounded),
                              label: const Text('选择模型包'),
                            ),
                            const SizedBox(width: 10),
                            FilledButton.icon(
                              onPressed: _selectedPackagePath == null || _busy
                                  ? null
                                  : _import,
                              icon: _busy
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      _done
                                          ? Icons.check_rounded
                                          : Icons.download_done_rounded,
                                    ),
                              label: Text(_done ? '已导入' : '导入并使用'),
                            ),
                          ],
                        ),
                        if (_done)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _close,
                              child: const Text('关闭向导，回到桌宠'),
                            ),
                          ),
                        if (_done && _needsRestart)
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              onPressed: _restart,
                              icon: const Icon(Icons.restart_alt_rounded),
                              label: const Text('重启并加载模型'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 17, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}
