import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:handrail_chat/core.dart';

void main() {
  final fixtures = jsonDecode(File('test/shared-fixtures/message-context.json').readAsStringSync()) as Map<String, dynamic>;
  final request = MessageContextRequest.fromJson(fixtures['request']);
  for (final entry in fixtures['results'] as List) {
    test('${entry['name']} round trip retains canonical identity and metadata', () {
      final before = jsonEncode(entry['wire']);
      final result = MessageContextResult.fromJson(entry['wire'], expectedRequest: request);
      expect(result.toJson(), entry['wire']);
      expect(MessageContextResult.fromJson(jsonDecode(jsonEncode(result.toJson())), expectedRequest: request).toJson(), result.toJson());
      expect(jsonEncode(entry['wire']), before);
    });
  }
  for (final entry in fixtures['invalidRequests'] as List) {
    test('request rejects ${entry['name']}', () => expect(() => MessageContextRequest.fromJson(entry['wire']), throwsA(isA<MessageContextFormatException>())));
  }
  for (final entry in fixtures['invalidResults'] as List) {
    test('result rejects ${entry['name']}', () => expect(() => MessageContextResult.fromJson(entry['wire'], expectedRequest: request), throwsA(isA<MessageContextFormatException>())));
  }
  test('all statuses validate the expected request identity', () {
    for (final entry in fixtures['results'] as List) {
      for (final expected in [
        MessageContextRequest(conversationId: request.conversationId, messageId: const MessageId('other')),
        MessageContextRequest(conversationId: const ConversationId('other'), messageId: request.messageId),
      ]) {
        expect(() => MessageContextResult.fromJson(entry['wire'], expectedRequest: expected), throwsA(isA<MessageContextFormatException>()));
      }
    }
  });
  test('safe sequence endpoints and non-finite numbers', () {
    for (final sequence in [1, 9007199254740991]) {
      final wire = jsonDecode(jsonEncode(fixtures['results'][0]['wire'])) as Map<String, dynamic>;
      wire['sequence'] = sequence;
      wire['message']['sequence'] = sequence;
      expect((MessageContextResult.fromJson(wire, expectedRequest: request) as AvailableMessageContext).sequence.value, sequence);
    }
    for (final sequence in [double.nan, double.infinity, double.negativeInfinity]) {
      final wire = {...fixtures['results'][0]['wire'] as Map, 'sequence': sequence};
      expect(() => MessageContextResult.fromJson(wire, expectedRequest: request), throwsA(isA<MessageContextFormatException>()));
    }
  });
  test('unavailable has no existence reason; transport rejection remains an error', () async {
    final unavailable = MessageContextResult.fromJson(fixtures['results'][2]['wire'], expectedRequest: request);
    expect(unavailable, isA<UnavailableMessageContext>());
    expect(unavailable.toJson(), {'status': 'unavailable', ...request.toJson()});
    final timeout = StateError('timeout');
    await expectLater(Future<Object?>.error(timeout).then((body) => MessageContextResult.fromJson(body, expectedRequest: request)), throwsA(same(timeout)));
    expect(() => MessageContextResult.fromJson(timeout, expectedRequest: request), throwsA(isA<MessageContextFormatException>()));
  });
  test('request round trip and bounded Unicode identifiers', () {
    expect(request.toJson(), fixtures['request']);
    for (final id in ['${'é' * 127}x', 'x' * 255]) {
      expect(MessageContextRequest.fromJson({...request.toJson(), 'messageId': id}).messageId.value, id);
    }
    expect(() => MessageContextRequest.fromJson({...request.toJson(), 'messageId': 'é' * 128}), throwsA(isA<MessageContextFormatException>()));
  });
}
