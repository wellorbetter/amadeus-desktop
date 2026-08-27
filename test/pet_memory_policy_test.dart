import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/pet_config.dart';
import 'package:timepet/services/pet_db.dart';
import 'package:timepet/services/pet_memory.dart';

void main() {
  test('disabled categories are rejected during audited memory storage', () {
    final root = Directory.systemTemp.createTempSync('amadeus-memory-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final database = PetDb(
      pathOverride: '${root.path}/mem.db',
      migrateLegacy: false,
    )..init();
    addTearDown(database.dispose);
    final config = PetConfig(pathOverride: '${root.path}/config.json')
      ..memoryDisabledCategories = const ['relationship'];
    final memory = PetMemory(database: database, config: config);

    memory.storeAudited([
      {'content': '伴侣叫小夏', 'category': 'relationship', 'importance': 5},
      {'content': '偏好安静的 UI', 'category': 'preference', 'importance': 3},
      {'content': '一次性的低价值信息', 'category': 'fact', 'importance': 1},
    ]);

    expect(memory.memoryCount(), 1);
    expect(memory.recentMemoryRows().single['content'], '偏好安静的 UI');
  });
}
