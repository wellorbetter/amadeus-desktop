import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/pet_config.dart';
import 'package:timepet/services/pet_secret_store.dart';

class _MemorySecretBackend implements SecretBackend {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  test('runtime API key is never serialized into config JSON', () {
    final config = PetConfig(pathOverride: 'unused.json')..aiApiKey = 'secret';

    final ai = config.toJson()['ai'] as Map<String, dynamic>;

    expect(ai.containsKey('apiKey'), isFalse);
    expect(jsonEncode(config.toJson()), isNot(contains('secret')));
  });

  test('plaintext API key migrates once into protected storage', () async {
    final root = Directory.systemTemp.createTempSync('amadeus-secret-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final path = '${root.path}/config.json';
    File(path).writeAsStringSync(
      jsonEncode({
        'ai': {
          'apiKey': 'legacy-key',
          'baseUrl': 'https://api.example.test/v1',
        },
      }),
    );
    final config = PetConfig(pathOverride: path)..load();
    final backend = _MemorySecretBackend();
    final secrets = PetSecretStore(backend: backend);

    expect(await secrets.hydrate(config), isTrue);

    expect(config.aiApiKey, 'legacy-key');
    expect(backend.values[PetSecretStore.apiKeyName], 'legacy-key');
    final persisted = jsonDecode(File(path).readAsStringSync());
    expect((persisted['ai'] as Map).containsKey('apiKey'), isFalse);
  });

  test('protected value wins after plaintext migration', () async {
    final root = Directory.systemTemp.createTempSync('amadeus-secret-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final config = PetConfig(pathOverride: '${root.path}/config.json')..load();
    final backend = _MemorySecretBackend()
      ..values[PetSecretStore.apiKeyName] = 'protected-key';
    final secrets = PetSecretStore(backend: backend);

    await secrets.hydrate(config);
    expect(config.aiApiKey, 'protected-key');

    await secrets.clearApiKey(config);
    expect(config.aiApiKey, isEmpty);
    expect(backend.values, isEmpty);
  });
}
