import 'dart:convert';
import 'dart:io';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  test('ServerHandshakeMetadata matches every shared metadata fixture',
      () async {
    final fixturesDirectory = Directory(
      'conformance-tests/realtime-metadata',
    );
    final fixtureFiles = fixturesDirectory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList()
      ..sort((left, right) => left.path.compareTo(right.path));

    expect(fixtureFiles, isNotEmpty, reason: 'expected metadata fixtures');

    for (final file in fixtureFiles) {
      final fixture =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final expected = fixture['expected'];
      expect(
        expected,
        anyOf('accept', 'reject'),
        reason: '${file.path} must declare an accept or reject outcome',
      );

      var outcome = 'accept';
      try {
        ServerHandshakeMetadata.fromJson(fixture['metadata']);
      } on FormatException {
        outcome = 'reject';
      }

      expect(outcome, expected, reason: fixture['id'] as String? ?? file.path);
    }
  });
}
