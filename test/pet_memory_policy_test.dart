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

  test(
    'trigger audit metadata never enters conversational working memory',
    () {
      final root = Directory.systemTemp.createTempSync('amadeus-memory-test-');
      addTearDown(() => root.deleteSync(recursive: true));
      final database = PetDb(
        pathOverride: '${root.path}/mem.db',
        migrateLegacy: false,
      )..init();
      addTearDown(database.dispose);
      final config = PetConfig(pathOverride: '${root.path}/config.json');
      final memory = PetMemory(database: database, config: config);

      memory.record('user', '继续优化这个项目');
      memory.record('system', '触发主动聊天：整点问候');
      database.addMessage('system', '旧版本遗留的内部触发记录');
      memory.record('assistant', '好，我们继续。');

      expect(memory.summary(), contains('用户：继续优化这个项目'));
      expect(memory.summary(), contains('Amadeus：好，我们继续。'));
      expect(memory.summary(), isNot(contains('触发主动聊天')));
      expect(memory.summary(), isNot(contains('内部触发记录')));
    },
  );

  test('semantic recall excludes unrelated high-importance memories', () {
    final root = Directory.systemTemp.createTempSync('amadeus-memory-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final database = PetDb(
      pathOverride: '${root.path}/mem.db',
      migrateLegacy: false,
    )..init();
    addTearDown(database.dispose);
    final config = PetConfig(pathOverride: '${root.path}/config.json');
    final memory = PetMemory(database: database, config: config);
    database.addMemory(
      '用户偏好安静、低干扰的界面',
      importance: 5,
    );
    database.addMemory(
      '用户计划学习 Rust 异步编程',
      category: 'goal',
      importance: 4,
    );

    expect(memory.relevantMemories('今天天气如何'), isEmpty);
    expect(
      memory.relevantMemories('把这个界面做得更安静一些'),
      contains('低干扰的界面'),
    );
    expect(
      memory.relevantMemories('继续学习 Rust 异步部分'),
      contains('Rust 异步编程'),
    );
    expect(
      memory.relevantMemories('我的目标是什么'),
      contains('Rust 异步编程'),
    );
  });
}
