import 'dart:io';

import 'pet_config.dart';
import 'pet_logger.dart';

/// 人格插件：从外部 soul.md 加载角色设定（插件化人格，不写死在代码里）。
///
/// 查找顺序：
/// 1. 配置 `ai.soulFile`（显式路径）
/// 2. `%APPDATA%/timepet/soul.md`
/// 3. `<exe>/soul.md`
///
/// 未找到时返回空文本，AI 使用内置默认人格（牧濑红莉栖）。
class PetSoul {
  PetSoul._();

  static final PetSoul instance = PetSoul._();

  String _text = '';
  String _source = '';

  /// soul.md 全文（未配置则为空串）。
  String get text => _text;

  /// 来源路径（用于日志/设置页显示）。
  String get source => _source;

  bool get hasSoul => _text.trim().isNotEmpty;

  void load() {
    final cfg = PetConfig.instance;
    if (cfg.soulText.trim().isNotEmpty) {
      _text = cfg.soulText.trim();
      _source = 'settings';
      PetLog.i('soul: loaded ${_text.length} chars from settings');
      return;
    }
    final candidates = <String>[
      if (cfg.soulFile.trim().isNotEmpty) cfg.soulFile.trim(),
      '${_appDataDir()}/timepet/soul.md',
      '${_exeDir()}/soul.md',
    ];
    for (final path in candidates) {
      final f = File(path);
      if (f.existsSync()) {
        try {
          _text = f.readAsStringSync().trim();
          _source = f.path;
          PetLog.i('soul: loaded ${_text.length} chars from $path');
          return;
        } catch (e) {
          PetLog.e('soul: read error $path: $e');
        }
      }
    }
    _text = '';
    _source = '';
    PetLog.i('soul: none found, use built-in persona');
  }

  static String _appDataDir() =>
      Platform.environment['APPDATA'] ?? Directory.systemTemp.path;

  static String _exeDir() => File(Platform.resolvedExecutable).parent.path;
}
