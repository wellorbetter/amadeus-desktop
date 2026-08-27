import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'pet_config.dart';
import 'pet_logger.dart';

abstract interface class SecretBackend {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class PlatformSecretBackend implements SecretBackend {
  PlatformSecretBackend({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Keeps provider credentials in the operating system's protected store.
///
/// Existing plaintext `ai.apiKey` values are migrated once and immediately
/// removed from config.json. Windows uses the platform secure-storage backend;
/// macOS uses Keychain with the runner entitlement declared in both profiles.
class PetSecretStore {
  PetSecretStore({SecretBackend? backend})
    : _backend = backend ?? PlatformSecretBackend();

  static final PetSecretStore instance = PetSecretStore();
  static const apiKeyName = 'amadeus.ai_api_key';

  final SecretBackend _backend;
  String? lastError;

  Future<bool> hydrate(PetConfig config) async {
    final legacy = config.aiApiKey.trim();
    try {
      var stored = (await _backend.read(apiKeyName))?.trim() ?? '';
      if (stored.isEmpty && legacy.isNotEmpty) {
        await _backend.write(apiKeyName, legacy);
        stored = legacy;
        PetLog.i('secret: migrated plaintext API key to protected storage');
      }
      config.aiApiKey = stored;
      if (legacy.isNotEmpty) config.save();
      lastError = null;
      return true;
    } catch (error) {
      // Keep a legacy value available for this process if migration failed,
      // but never rewrite it through PetConfig.toJson().
      config.aiApiKey = legacy;
      lastError = '$error';
      PetLog.e('secret: hydrate failed: $error');
      return false;
    }
  }

  Future<bool> saveApiKey(PetConfig config, String value) async {
    final normalized = value.trim();
    config.aiApiKey = normalized;
    try {
      if (normalized.isEmpty) {
        await _backend.delete(apiKeyName);
      } else {
        await _backend.write(apiKeyName, normalized);
      }
      config.save();
      lastError = null;
      return true;
    } catch (error) {
      lastError = '$error';
      PetLog.e('secret: save failed: $error');
      return false;
    }
  }

  Future<bool> clearApiKey(PetConfig config) => saveApiKey(config, '');
}
