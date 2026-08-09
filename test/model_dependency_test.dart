import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/pet_model.dart';

void main() {
  test('model entry rejects a missing referenced dependency', () async {
    final root = await Directory.systemTemp.createTemp('timepet-model-');
    addTearDown(() => root.delete(recursive: true));
    final model = File('${root.path}/kurisu.model.json');
    await model.writeAsString('''
{
  "model": "kurisu.moc",
  "textures": ["textures/texture_00.png"],
  "physics": "kurisu.physics.json"
}
''');
    await File('${root.path}/kurisu.moc').writeAsBytes([1]);

    await expectLater(
      PetModel.importFromFile(model.path, targetRoot: '${root.path}/installed'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test(
    'model package discovers one entry and imports the whole directory',
    () async {
      final root = await Directory.systemTemp.createTemp('timepet-package-');
      addTearDown(() => root.delete(recursive: true));
      final package = Directory('${root.path}/kurisu');
      await package.create();
      await File('${package.path}/kurisu.model.json').writeAsString(
        jsonEncode({
          'model': 'shizuku.moc',
          'textures': ['texture_00.png'],
        }),
      );
      await File('${package.path}/shizuku.moc').writeAsString('moc');
      await File('${package.path}/texture_00.png').writeAsBytes([1, 2, 3]);

      final result = await PetModel.importPackage(
        package.path,
        targetRoot: '${root.path}/installed',
        persistConfig: false,
      );

      expect(result.files, 3);
      expect(File(result.path).existsSync(), isTrue);
      expect(
        File('${root.path}/installed/kurisu/texture_00.png').existsSync(),
        isTrue,
      );
    },
  );

  test('model package rejects multiple entries instead of guessing', () async {
    final root = await Directory.systemTemp.createTemp('timepet-package-');
    addTearDown(() => root.delete(recursive: true));
    await File(
      '${root.path}/a.model.json',
    ).writeAsString(jsonEncode({'model': 'a.moc', 'textures': <String>[]}));
    await File('${root.path}/a.moc').writeAsString('moc');
    await File(
      '${root.path}/b.model.json',
    ).writeAsString(jsonEncode({'model': 'b.moc', 'textures': <String>[]}));
    await File('${root.path}/b.moc').writeAsString('moc');

    expect(() => PetModel.packageEntries(root.path), returnsNormally);
    expect(
      () => PetModel.inspectPackage(root.path),
      throwsA(isA<ArgumentError>()),
    );
  });
}
