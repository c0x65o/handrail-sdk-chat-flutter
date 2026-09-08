import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('non-widget testing helpers remain pure Dart', () async {
    final files = <File>[
      ...await Directory('lib/src/testing')
          .list()
          .where(
            (entity) =>
                entity is File &&
                entity.path.endsWith('.dart') &&
                !entity.path.endsWith('flutter_chat_widget_fixtures.dart'),
          )
          .cast<File>()
          .toList(),
    ];

    for (final file in files) {
      expect(
        await file.readAsString(),
        isNot(contains('package:flutter/')),
        reason: '${file.path} imported Flutter.',
      );
    }
  });

  test('testing.dart owns the explicit Flutter fixture boundary', () async {
    final testing = await File('lib/testing.dart').readAsString();
    final widgets = await File(
      'lib/src/testing/flutter_chat_widget_fixtures.dart',
    ).readAsString();

    expect(
      testing,
      contains("export 'src/testing/flutter_chat_widget_fixtures.dart';"),
    );
    expect(widgets, contains("import 'package:flutter/widgets.dart';"));
  });

  test('production libraries never import the testing surface', () async {
    final lib = Directory('lib');
    final violations = <String>[];

    await for (final entity in lib.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final normalized = entity.path.replaceAll('\\', '/');
      if (normalized == 'lib/testing.dart' ||
          normalized.startsWith('lib/src/testing/')) {
        continue;
      }
      final source = await entity.readAsString();
      if (_testingImport.hasMatch(source)) violations.add(normalized);
    }

    expect(
      violations,
      isEmpty,
      reason: 'Production libraries imported package test helpers.',
    );
  });
}

final _testingImport = RegExp(
  r'''(?:import|export|part)\s+['"][^'"]*(?:testing\.dart|src/testing/)''',
);
