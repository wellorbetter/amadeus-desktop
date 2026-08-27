import 'dart:io';

/// Cross-platform locations for data that must remain writable at runtime.
///
/// Windows keeps the existing `%APPDATA%/timepet` directory for backward
/// compatibility. macOS follows the Application Support convention so the app
/// bundle remains read-only and can be signed/notarized normally.
abstract final class AppPaths {
  static Directory get userDataDirectory {
    if (Platform.isWindows) {
      final roaming = Platform.environment['APPDATA'];
      return Directory('${roaming ?? Directory.systemTemp.path}/timepet');
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
      return Directory('$home/Library/Application Support/Amadeus');
    }
    final xdg = Platform.environment['XDG_DATA_HOME'];
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    return Directory('${xdg ?? '$home/.local/share'}/amadeus');
  }

  static Directory get modelsDirectory =>
      Directory('${userDataDirectory.path}${Platform.pathSeparator}models');

  static File get configFile =>
      File('${userDataDirectory.path}${Platform.pathSeparator}config.json');

  static File get memoryFile =>
      File('${userDataDirectory.path}${Platform.pathSeparator}mem.db');

  static File get soulFile =>
      File('${userDataDirectory.path}${Platform.pathSeparator}soul.md');

  static File get logFile =>
      File('${userDataDirectory.path}${Platform.pathSeparator}amadeus.log');

  static List<File> get timeTraceDatabases {
    final explicit =
        Platform.environment['TIMEPET_TT_DB'] ??
        Platform.environment['TIMETRACE_DB'];
    final files = <File>[
      if (explicit != null && explicit.trim().isNotEmpty) File(explicit.trim()),
    ];
    if (Platform.isWindows) {
      final roaming = Platform.environment['APPDATA'];
      if (roaming != null) {
        files.addAll([
          File(
            '$roaming${Platform.pathSeparator}TimeTrace${Platform.pathSeparator}time.db',
          ),
          File(
            '$roaming${Platform.pathSeparator}timetrace${Platform.pathSeparator}time.db',
          ),
        ]);
      }
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
      files.addAll([
        File('$home/Library/Application Support/TimeTrace/time.db'),
        File('$home/Library/Application Support/timetrace/time.db'),
      ]);
    }
    return files;
  }
}
