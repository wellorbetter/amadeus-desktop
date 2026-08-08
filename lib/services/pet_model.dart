import 'dart:io';

import 'pet_config.dart';
import 'pet_logger.dart';

/// 模型插件：从外部目录解析 Live2D 模型（Cubism 2.1，*.model.json）。
/// 查找顺序：
/// 1. 配置 `appearance.modelPath`（显式指定模型 json 绝对/相对路径）
/// 2. `<exe>/models/` 递归扫描
/// 3. `%APPDATA%/timepet/models/` 递归扫描
///
/// 返回模型 json 文件名与所在目录（虚拟主机 model.local 映射该目录）。
/// 注意：仅支持 Cubism 2.1（.model.json）；Cubism 5（model3.json）暂不支持，
/// 检测到时记录警告并跳过，避免 WebView 内加载挂起。
class PetModel {
  static const String legacySuffix = '.model.json';
  static const String model3Suffix = 'model3.json';

  /// 解析结果：file = 模型 json 文件名（相对虚拟主机根），dir = 模型 json 所在目录。
  static ({String file, String dir})? resolve() {
    final cfg = PetConfig.instance;
    final explicit = cfg.modelPath.trim();
    if (explicit.isNotEmpty) {
      final f = File(explicit);
      if (f.existsSync()) {
        PetLog.i('model: explicit path -> ${f.path}');
        return (file: _fileName(f.path), dir: f.parent.path);
      }
      PetLog.w('model: config path not found: $explicit');
    }

    for (final root in _roots) {
      final r = _scan(root);
      if (r != null) return r;
    }
    PetLog.w('model: no model found (checked: ${_roots.join(', ')})');
    return null;
  }

  static List<String> get _roots {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final appData = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    return ['$exeDir/models', '$appData/timepet/models'];
  }

  static ({String file, String dir})? _scan(String root) {
    final dir = Directory(root);
    if (!dir.existsSync()) return null;

    // 仅支持 Cubism 2.1：*.model.json
    final legacy = _find(dir, legacySuffix, depth: 4);
    if (legacy.isNotEmpty) {
      return (file: _fileName(legacy.first.path), dir: legacy.first.parent.path);
    }

    // 检测到 Cubism 5（model3.json）但暂不支持：给出明确提示，避免黑屏/挂起
    final model3 = _find(dir, model3Suffix, depth: 4);
    if (model3.isNotEmpty) {
      PetLog.w('model: found model3.json (Cubism 5) but unsupported: '
          '${model3.first.path}. Only Cubism 2.1 (.model.json) is supported.');
    }
    return null;
  }

  static List<File> _find(Directory dir, String suffix, {required int depth}) {
    final out = <File>[];
    void walk(Directory d, int level) {
      if (level > depth) return;
      try {
        for (final e in d.listSync(followLinks: false)) {
          if (e is File && e.path.toLowerCase().endsWith(suffix)) {
            out.add(e);
          } else if (e is Directory) {
            walk(e, level + 1);
          }
        }
      } catch (_) {
        // 目录不可读时跳过
      }
    }

    walk(dir, 0);
    return out;
  }

  static String _fileName(String path) {
    final segs = path.replaceAll('\\', '/').split('/');
    return segs.isNotEmpty ? segs.last : path;
  }
}
