import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/pet_config.dart';

void main() {
  test('invalid config is backed up and replaced with valid defaults', () {
    final root = Directory.systemTemp.createTempSync('amadeus-config-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final path = '${root.path}/config.json';
    File(path).writeAsStringSync('{invalid json');
    final config = PetConfig(pathOverride: path)..aiApiKey = 'runtime-secret';

    config.load();

    expect(File(path).existsSync(), isTrue);
    expect(jsonDecode(File(path).readAsStringSync()), isA<Map>());
    expect(config.aiApiKey, 'runtime-secret');
    expect(File(path).readAsStringSync(), isNot(contains('runtime-secret')));
    expect(
      root.listSync().whereType<File>().any(
        (file) => file.path.contains('config.json.corrupt-'),
      ),
      isTrue,
    );
  });
}
