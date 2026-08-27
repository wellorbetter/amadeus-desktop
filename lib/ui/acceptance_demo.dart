import 'dart:io';

import 'package:flutter/material.dart';

import '../services/activity_history.dart';
import '../services/pet_config.dart';
import 'amadeus_theme.dart';
import 'settings_panel.dart';

/// Deterministic, offline product tour used by release acceptance recording.
///
/// It never reads the user's normal config, memory, model, or credentials.
/// The native release executable still renders the real settings widgets;
/// only the data source and automatic navigation are synthetic.
class AcceptanceDemoApp extends StatefulWidget {
  const AcceptanceDemoApp({super.key, this.targetPlatform});

  static const surfaceKey = ValueKey('acceptance-demo-surface');

  final TargetPlatform? targetPlatform;

  @override
  State<AcceptanceDemoApp> createState() => _AcceptanceDemoAppState();
}

class _AcceptanceDemoAppState extends State<AcceptanceDemoApp> {
  late final Directory _root;
  late final PetConfig _config;
  late final ActivityHistory _history;

  @override
  void initState() {
    super.initState();
    _root = Directory.systemTemp.createTempSync('amadeus-acceptance-demo-');
    _config = PetConfig(pathOverride: '${_root.path}/config.json')
      ..resetToDefaults(persist: false)
      ..aiEnabled = true
      ..aiApiKey = 'acceptance-demo-only'
      ..activityAwarenessEnabled = true
      ..activityAwarenessPaused = false;
    _history = ActivityHistory(
      pathOverride: '${_root.path}/activity.db',
      provider: () async => ActivitySnapshot(
        appName: 'Visual Studio Code',
        appId: 'acceptance:code',
        idleSeconds: 0,
        capturedAt: DateTime.now(),
        nativeDecision: ActivityDecision.active,
        nativeCoreVersion: 1,
      ),
    );
    _seedHistory();
  }

  void _seedHistory() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 9, 20);
    final samples = [
      ('Visual Studio Code', 'code', 0, 0),
      ('Visual Studio Code', 'code', 0, 34),
      ('Terminal', 'terminal', 0, 46),
      ('Browser', 'browser', 0, 62),
      ('Browser', 'browser', 0, 88),
    ];
    for (final sample in samples) {
      _history.recordSnapshot(
        ActivitySnapshot(
          appName: sample.$1,
          appId: sample.$2,
          idleSeconds: sample.$3,
          capturedAt: start.add(Duration(minutes: sample.$4)),
        ),
      );
    }
  }

  @override
  void dispose() {
    _history.close();
    try {
      _root.deleteSync(recursive: true);
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lightTheme = AmadeusTheme.light().copyWith(
      platform: widget.targetPlatform,
    );
    final darkTheme = AmadeusTheme.dark().copyWith(
      platform: widget.targetPlatform,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Amadeus · Acceptance Demo',
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: ThemeMode.light,
      home: RepaintBoundary(
        key: AcceptanceDemoApp.surfaceKey,
        child: SettingsPage(
          config: _config,
          activityHistory: _history,
          demoCycleInterval: const Duration(seconds: 4),
        ),
      ),
    );
  }
}
