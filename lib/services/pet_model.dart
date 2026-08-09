import 'dart:convert';
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
  static String? _missingExplicitPath;

  static bool get configuredPathMissing => _missingExplicitPath != null;
  static String? get missingExplicitPath => _missingExplicitPath;

  /// Finds the Cubism 2.1 entry inside one complete user-provided package.
  /// The entry JSON is an implementation detail; callers should present the
  /// package as a directory containing the model and its resources.
  static List<File> packageEntries(String packagePath) {
    final root = Directory(packagePath);
    if (!root.existsSync()) {
      throw ArgumentError('找不到模型包目录：$packagePath');
    }
    return _find(root, legacySuffix, depth: 6);
  }

  static Future<({String entryPath, int files})> inspectPackage(
    String packagePath,
  ) async {
    final entries = packageEntries(packagePath);
    if (entries.isEmpty) {
      throw ArgumentError('模型包中没有找到可用的 Cubism 2.1 模型');
    }
    if (entries.length > 1) {
      throw ArgumentError('模型包中找到多个模型，请每次选择只包含一个桌宠模型的目录');
    }
    final entry = entries.single;
    final decoded = await _readModelJson(entry);
    final missing = _missingReferences(decoded, entry.parent, entry.path);
    if (missing.isNotEmpty) {
      throw ArgumentError('模型包缺少资源：${missing.take(3).join('、')}');
    }
    final files = Directory(
      packagePath,
    ).listSync(recursive: true, followLinks: false).whereType<File>().length;
    return (entryPath: entry.path, files: files);
  }

  static Future<({String path, int files})> importPackage(
    String packagePath, {
    String? targetRoot,
    bool persistConfig = true,
  }) async {
    final inspected = await inspectPackage(packagePath);
    return importFromFile(
      inspected.entryPath,
      targetRoot: targetRoot,
      persistConfig: persistConfig,
    );
  }

  /// 解析结果：file = 模型 json 文件名（相对虚拟主机根），dir = 模型 json 所在目录。
  static ({String file, String dir})? resolve() {
    final cfg = PetConfig.instance;
    final explicit = cfg.modelPath.trim();
    _missingExplicitPath = null;
    if (explicit.isNotEmpty) {
      final f = File(explicit);
      if (f.existsSync()) {
        PetLog.i('model: explicit path -> ${f.path}');
        return (file: _fileName(f.path), dir: f.parent.path);
      }
      PetLog.w('model: config path not found: $explicit');
      _missingExplicitPath = explicit;
      // Keep searching for a usable fallback, but expose the invalid
      // configured path so the UI can explain the fallback and offer import.
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
    final appData =
        Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    return ['$exeDir/models', '$appData/timepet/models'];
  }

  static ({String file, String dir})? _scan(String root) {
    final dir = Directory(root);
    if (!dir.existsSync()) return null;

    // 仅支持 Cubism 2.1：*.model.json
    final legacy = _find(dir, legacySuffix, depth: 4);
    if (legacy.isNotEmpty) {
      return (
        file: _fileName(legacy.first.path),
        dir: legacy.first.parent.path,
      );
    }

    // 检测到 Cubism 5（model3.json）但暂不支持：给出明确提示，避免黑屏/挂起
    final model3 = _find(dir, model3Suffix, depth: 4);
    if (model3.isNotEmpty) {
      PetLog.w(
        'model: found model3.json (Cubism 5) but unsupported: '
        '${model3.first.path}. Only Cubism 2.1 (.model.json) is supported.',
      );
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

  /// Copy a user-owned Cubism 2.1 model into the per-user model directory.
  /// The app never downloads or redistributes model assets.
  static Future<({String path, int files})> importFromFile(
    String sourcePath, {
    String? targetRoot,
    bool persistConfig = true,
  }) async {
    final source = File(sourcePath);
    if (!source.existsSync()) throw ArgumentError('找不到模型文件');
    if (!source.path.toLowerCase().endsWith(legacySuffix)) {
      throw ArgumentError('请选择 Cubism 2.1 的 *.model.json 文件');
    }
    final decoded = await _readModelJson(source);
    if (decoded is! Map ||
        decoded['model'] is! String ||
        decoded['textures'] is! List) {
      throw ArgumentError('不是有效的 Cubism 2.1 模型配置');
    }
    final missing = _missingReferences(decoded, source.parent, source.path);
    if (missing.isNotEmpty) {
      throw ArgumentError('模型缺少资源：${missing.take(3).join('、')}');
    }
    final root = targetRoot ?? _roots.last;
    final sourceDir = source.parent;
    final rawName = sourceDir.path.split(RegExp(r'[\\/]')).last;
    final name = rawName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_');
    final targetDir = Directory('${Directory(root).path}/$name');
    final sameDirectory = _samePath(sourceDir.path, targetDir.path);
    if (!sameDirectory && targetDir.existsSync()) {
      throw StateError('模型目录已存在：${targetDir.path}，请先改名或删除旧模型');
    }
    if (!sameDirectory) {
      final staging = Directory(
        '${Directory(root).path}/.timepet-import-${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        await _copyDirectory(sourceDir, staging);
        await staging.rename(targetDir.path);
      } catch (_) {
        if (staging.existsSync()) await staging.delete(recursive: true);
        rethrow;
      }
    }
    final imported = File('${targetDir.path}/${_fileName(source.path)}');
    if (!imported.existsSync()) throw StateError('模型复制后未找到配置文件');
    PetConfig.instance.modelPath = imported.path;
    if (persistConfig && !PetConfig.instance.save()) {
      if (!sameDirectory && targetDir.existsSync()) {
        await targetDir.delete(recursive: true);
      }
      throw StateError('模型已复制，但配置无法保存');
    }
    return (
      path: imported.path,
      files: targetDir
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .length,
    );
  }

  static Future<dynamic> _readModelJson(File source) async {
    dynamic decoded;
    try {
      decoded = jsonDecode(await source.readAsString());
    } catch (_) {
      throw ArgumentError('模型包中的入口配置无法解析');
    }
    if (decoded is! Map ||
        decoded['model'] is! String ||
        decoded['textures'] is! List) {
      throw ArgumentError('模型包中的入口配置不是有效的 Cubism 2.1 模型');
    }
    return decoded;
  }

  static Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    for (final entity in source.listSync(followLinks: false)) {
      final name = entity.path
          .substring(source.path.length)
          .replaceFirst(RegExp(r'^[\\/]'), '');
      final destination = '${target.path}${Platform.pathSeparator}$name';
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(destination));
      } else if (entity is File) {
        await entity.copy(destination);
      }
    }
  }

  static bool _samePath(String left, String right) {
    String normalise(String value) => value
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '')
        .toLowerCase();
    return normalise(File(left).absolute.path) ==
        normalise(File(right).absolute.path);
  }

  static List<String> _missingReferences(
    dynamic value,
    Directory root,
    String configPath,
  ) {
    const extensions = <String>[
      '.png',
      '.jpg',
      '.jpeg',
      '.moc',
      '.mtn',
      '.wav',
      '.mp3',
      '.ogg',
      '.json',
    ];
    final missing = <String>[];
    void walk(dynamic item) {
      if (item is Map) {
        for (final child in item.values) {
          walk(child);
        }
      } else if (item is List) {
        for (final child in item) {
          walk(child);
        }
      } else if (item is String) {
        final normalized = item.replaceAll('\\', '/');
        final lower = normalized.toLowerCase();
        if (normalized.contains('://') ||
            normalized == _fileName(configPath) ||
            !extensions.any(lower.endsWith)) {
          return;
        }
        if (!File(
          '${root.path}${Platform.pathSeparator}$normalized',
        ).existsSync()) {
          missing.add(normalized);
        }
      }
    }

    walk(value);
    return missing.toSet().toList();
  }
}
