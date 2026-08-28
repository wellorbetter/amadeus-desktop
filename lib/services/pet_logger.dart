import 'dart:io';

import 'pet_config.dart';
import 'app_paths.dart';

/// 轻量文件日志：写入 exe 同级目录 timepet.log。
/// 支持通过配置开关与级别过滤（INFO / WARN / ERROR），便于排查桌宠问题。
class PetLog {
  static File? _file;

  /// 是否写日志（对应配置 log.enabled）。
  static bool get enabled => PetConfig.instance.logEnabled;

  static const _levels = {'INFO': 0, 'WARN': 1, 'ERROR': 2};

  static int _levelIndex() {
    final lv = PetConfig.instance.logLevel.toUpperCase();
    return _levels[lv] ?? 0;
  }

  static void _ensure() {
    if (_file != null) return;
    try {
      _file = AppPaths.logFile;
      _file!.parent.createSync(recursive: true);
    } catch (_) {
      _file = File('timepet.log');
    }
  }

  static void i(String msg) => _write('INFO', msg);
  static void w(String msg) => _write('WARN', msg);
  static void e(String msg) => _write('ERROR', msg);

  static void _write(String level, String msg) {
    if (!enabled) return;
    if (_levelIndex() > (_levels[level] ?? 0)) return;
    _ensure();
    try {
      _file!.writeAsStringSync(
        '${DateTime.now().toIso8601String()} [$level] $msg\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // 日志失败不影响主流程
    }
  }
}
