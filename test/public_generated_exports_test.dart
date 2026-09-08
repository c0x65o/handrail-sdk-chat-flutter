import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('core exposes cross-client generated query contracts', () {
    final source = File('lib/core.dart').readAsStringSync();
    expect(source, contains("export 'src/generated/message_context.dart'"));
    expect(source, contains("export 'src/generated/thread_list.dart'"));
  });
}
