import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:handrail_chat/core.dart';

void main() {
  final fixtures = jsonDecode(File('test/shared-fixtures/reply-style-preference.json').readAsStringSync()) as Map<String, dynamic>;
  final descriptor = jsonDecode(File('contracts/http/reply-style-preference.json').readAsStringSync()) as Map<String, dynamic>;
  final request = Map<String, Object?>.from(fixtures['request'] as Map);
  Matcher errorCode(String code) => isA<ReplyStylePreferenceFormatException>().having((e) => e.code, 'code', code);
  for (final entry in fixtures['reads'] as List) {
    test('read preserves ${entry['name']}', () {
      final before = jsonEncode(entry['wire']);
      final state = ReplyStylePreferenceState.fromJson(entry['wire']);
      expect(state.toJson(), entry['wire']);
      expect(state.resolvedStyle.wireValue, entry['resolved']);
      expect(jsonEncode(entry['wire']), before);
      if (state is SavedReplyStylePreference) expect(state.isSupported, entry['supported']);
    });
  }
  for (final entry in fixtures['invalidReads'] as List) {
    test('reject read ${entry['name']}', () => expect(() => ReplyStylePreferenceState.fromJson(entry['wire']), throwsA(errorCode(entry['code'] as String))));
  }
  for (final entry in fixtures['invalidWrites'] as List) {
    test('reject write ${entry['name']}', () => expect(() => UpdateReplyStylePreferenceInput.fromJson(entry['wire']), throwsA(errorCode(entry['code'] as String))));
  }
  test('supported writes and UTF-8 key limits', () {
    for (final style in ['current', 'discord']) {
      for (final key in ['x' * 255, '${'é' * 127}x', '${'😀' * 63}abc']) {
        final input = {...request, 'style': style, 'idempotencyKey': key, 'baseRevision': 9007199254740990};
        expect(UpdateReplyStylePreferenceInput.fromJson(input).toJson(), input);
      }
    }
    for (final revision in [double.nan, double.infinity, double.negativeInfinity]) {
      expect(() => UpdateReplyStylePreferenceInput.fromJson({...request, 'baseRevision': revision}), throwsA(errorCode('malformed_revision')));
    }
    expect(UpdateReplyStylePreferenceInput.fromJson({...request, 'baseRevision': 1.0}).baseRevision, 1);
  });
  test('GET and mutations reject recursive normalized identity injection', () {
    expect(GetReplyStylePreferenceInput.fromJson({}).toJson(), isEmpty);
    for (final value in [null, [], {'style': 'current'}, {'conversationId': 'c'}]) {
      expect(() => GetReplyStylePreferenceInput.fromJson(value), throwsA(errorCode('malformed_input')));
    }
    for (final alias in descriptor['trustedContextAliases'] as List) {
      final normalized = (alias as String).toUpperCase().split('').join('_.- ');
      for (final injection in [
        {alias: 'spoof'}, {normalized: 'spoof'},
        {'nested': [{'more': {normalized: 'spoof'}}]},
      ]) {
        expect(() => UpdateReplyStylePreferenceInput.fromJson({...request, ...injection}), throwsA(errorCode('trusted_identity_field')));
        expect(() => GetReplyStylePreferenceInput.fromJson(injection), throwsA(errorCode('trusted_identity_field')));
      }
    }
  });
  for (final entry in fixtures['results'] as List) {
    test('result ${entry['name']}', () {
      final expected = UpdateReplyStylePreferenceInput.fromJson(entry['request'] ?? request);
      if (entry['code'] != null) {
        expect(() => UpdateReplyStylePreferenceResult.fromJson(entry['wire'], expectedInput: expected), throwsA(errorCode(entry['code'] as String)));
      } else {
        final parsed = UpdateReplyStylePreferenceResult.fromJson(entry['wire'], expectedInput: expected);
        expect(parsed.toJson(), entry['wire']);
        expect(UpdateReplyStylePreferenceResult.fromJson(jsonDecode(jsonEncode(parsed.toJson())), expectedInput: expected).toJson(), parsed.toJson());
      }
    });
  }
  test('feature defaults false', () {
    expect(replyStylePreferenceFeature, 'reply_style_preference_v1');
    expect(supportsReplyStylePreference(null), isFalse);
    expect(supportsReplyStylePreference({}), isFalse);
    expect(supportsReplyStylePreference({replyStylePreferenceFeature: false}), isFalse);
    expect(supportsReplyStylePreference({replyStylePreferenceFeature: true}), isTrue);
  });
}
