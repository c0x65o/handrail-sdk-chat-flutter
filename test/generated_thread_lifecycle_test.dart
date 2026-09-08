import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:handrail_chat/core.dart';

void main() {
  final f = jsonDecode(File('test/shared-fixtures/thread-lifecycle-http.json').readAsStringSync()) as Map<String, dynamic>;
  dynamic roundtrip(Object? value) => jsonDecode(jsonEncode(value));
  for (final entry in f['valid'] as List) {
    test('round trip: ${entry['name']}', () {
      final input = ThreadLifecycleInput.fromJson(roundtrip(entry['input']));
      expect(input.toJson(), entry['input']);
      final result = ThreadLifecycleResult.fromJson(roundtrip(entry['result']), expectedInput: input);
      expect(result.toJson(), entry['result']);
      expect(ThreadLifecycleResult.fromJson(roundtrip(result.toJson()), expectedInput: input).toJson(), entry['result']);
      expect(input.toHttpBody().containsKey('threadId'), false);
      expect(ThreadLifecycleInput.fromHttp(input.threadId.value, roundtrip(input.toHttpBody())).toJson(), input.toJson());
    });
  }
  for (final entry in f['invalidRequests'] as List) {
    test('reject input: ${entry['name']}', () {
      expect(() => ThreadLifecycleInput.fromJson(roundtrip(entry['input'])), throwsA(isA<ThreadLifecycleFormatException>()));
    });
  }
  for (final entry in f['invalidResults'] as List) {
    test('reject result: ${entry['name']}', () {
      final input = ThreadLifecycleInput.fromJson(entry['input']);
      expect(() => ThreadLifecycleResult.fromJson(roundtrip(entry['result']), expectedInput: input), throwsA(isA<ThreadLifecycleFormatException>()));
    });
  }
  test('constructors, non-finite revisions, HTTP identity and normalized trusted fields', () {
    final inputJson = Map<String, Object?>.from(f['valid'][0]['input'] as Map);
    final input = ThreadLifecycleInput.fromJson(inputJson);
    for (final value in [double.nan, double.infinity, double.negativeInfinity]) {
      expect(() => ThreadLifecycleInput.fromJson({...inputJson, 'expectedLifecycleRevision':value}), throwsFormatException);
    }
    expect(() => ThreadLifecycleInput(intent: ThreadLifecycleIntent.close, threadId: const ConversationId(''), expectedLifecycleRevision:1, idempotencyKey:'key'), throwsFormatException);
    expect(() => ThreadLifecycleInput(intent: ThreadLifecycleIntent.close, threadId: const ConversationId('thread-1'), expectedLifecycleRevision:0, idempotencyKey:'key'), throwsFormatException);
    expect(() => ThreadLifecycleInput.fromHttp('thread-1', inputJson), throwsFormatException);
    expect(() => ThreadLifecycleInput.fromHttp('', input.toHttpBody()), throwsFormatException);
    expect(() => ThreadLifecycleInput.fromJson({...inputJson, 'extra':[{'AUTH_ORIZATION':'forged'}]}), throwsA(isA<ThreadLifecycleFormatException>().having((error) => error.code, 'code', 'trusted_identity_field')));
    final before = ThreadLifecycle(revision:7, locked:false);
    expect(() => ThreadLifecycleResult(input: input, reconciliationStatus: ThreadLifecycleReconciliationStatus.applied, previousLifecycle:before, threadLifecycle:before), throwsFormatException);
    expect(threadLifecycleFeature, 'thread_lifecycle_v1');
    expect(threadLifecyclePath, '/conversations/:threadId/lifecycle');
  });
}
