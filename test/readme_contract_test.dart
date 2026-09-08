import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('README documents only current safe public package surfaces', () {
    final readme = File('README.md').readAsStringSync();

    for (final entryPoint in <String>[
      'core.dart',
      'flutter.dart',
      'ui.dart',
      'media.dart',
      'testing.dart',
    ]) {
      expect(
        readme,
        contains("import 'package:handrail_chat/$entryPoint';"),
      );
    }
    for (final symbol in <String>[
      'HandrailChatClient',
      'ChatScope',
      'ConversationStateBuilder',
      'ChatConversationController',
      'ChatTimelineController',
      'HandrailChannelHeader',
      'HandrailMessageTimeline',
      'HandrailMessageComposer',
      'HandrailChatWorkspace',
    ]) {
      expect(readme, contains(symbol), reason: '$symbol must be documented');
    }

    expect(readme, isNot(contains('lib/src/')));
    expect(readme, isNot(contains('Bearer ')));
    expect(readme, isNot(contains('tokenProvider:')));
    expect(readme, isNot(contains('https://erp.example.com')));
    expect(readme, isNot(contains('package bootstrap')));
    expect(readme, isNot(contains('introduced separately')));
    expect(readme, isNot(contains('not part of this package')));
    expect(readme, contains('examples/flutter-erp/README.md'));
  });

  for (final path in ['README.md', 'examples/flutter-erp/README.md']) {
    test('$path documents the shared-writer storage contract', () {
      final readme = _normalizeMarkdown(File(path).readAsStringSync());
      // Match individual guarantees, independent of Markdown line wrapping.
      for (final guarantee in [
        'Stable identity scoping isolates records but does not serialize '
            'separate Flutter engines or processes',
        'Storage shared by concurrent writers must implement '
            'AtomicApplicationChatStorage with a genuinely atomic '
            'compareExchange for the exact identity-and-record-kind key',
        'A legacy ApplicationChatStorage adapter is safe only when the host '
            'guarantees one writer for that identity',
        'ApplicationChatStorageMutator provides a single-runtime legacy '
            'fallback, not coordination across runtimes',
        'Individually atomic replace/remove operations do not make an '
            'unconditional read-plus-replace sequence safe across writers',
        'readEncoded returns the exact stored representation, not a re-encoding',
        'A null expectedEncodedRecord means absence: the key must not exist',
        'A null replacementEncodedRecord conditionally removes the matching value',
        'A non-null replacement must encode a valid record for the supplied '
            'identity and record kind',
        'A comparison mismatch must return false and leave storage unchanged',
        'Quarantine malformed data only by comparing against the exact encoded '
            'value observed with '
            'compareExchange(identity, kind, observedEncoded, null), '
            'preserving any newer replacement',
        'Derive storage scope and ApplicationChatStorageIdentity from the '
            'trusted host login boundary before realtime starts',
        'Never derive scope or identity from access-token contents or an '
            'identity reported by an unaccepted socket',
        'Keep scope, persisted records, and diagnostics free of access tokens, '
            'refresh tokens, push tokens, credentials, and other secrets',
        'Use sanitized diagnostics; never log raw encoded records or adapter '
            'errors that may contain secrets',
        'The ChatRealtimeCursorStorage cursor-scope contract is separate from '
            'the AtomicApplicationChatStorage application storage capability',
        'The ERP cursor adapter does not implement that atomic capability',
      ]) {
        expect(readme, contains(guarantee), reason: '$path: $guarantee');
      }
    });

    test('$path examples avoid token scopes and unconditional mutations', () {
      final readme = File(path).readAsStringSync();
      expect(_advertisesUnsafeMutation(readme), isFalse);
      final examples = RegExp(r'```dart\s*\n([\s\S]*?)```').allMatches(readme);
      for (final example in examples) {
        final code = _normalizeMarkdown(example.group(1)!.replaceAll(
              RegExp(r'^\s*//.*$', multiLine: true),
              '',
            ));
        expect(
          _tokenDerivedScope.hasMatch(code),
          isFalse,
          reason: '$path: scope must come from trusted host identity',
        );
        expect(
          RegExp(r'\.\s*(?:read|readEncoded)\s*\([\s\S]*'
                  r'\.\s*(?:replace|remove)\s*\(')
              .hasMatch(code),
          isFalse,
          reason: '$path: examples must not use unconditional read-plus-write',
        );
      }
    });
  }

  test('guidance checks distinguish warnings and tolerate wrapped examples',
      () {
    expect(
      _advertisesUnsafeMutation('Individually atomic `replace`/`remove` '
          'operations do not make an unconditional read-plus-replace\n'
          'sequence safe across writers.'),
      isFalse,
    );
    expect(
      _advertisesUnsafeMutation('An unconditional read-plus-replace\n'
          'sequence is safe across writers.'),
      isTrue,
    );
    for (final code in [
      'identityScopeKey:\n accessToken,',
      'final cursorStorageScope = decodeJwt(token).subject;',
      'final scope = token.split(".").first;',
    ]) {
      expect(_tokenDerivedScope.hasMatch(_normalizeMarkdown(code)), isTrue);
    }
    expect(
      _tokenDerivedScope.hasMatch(
        'identityScopeKey: signedInAccount.chatPersistenceScope,',
      ),
      isFalse,
    );
  });
}

String _normalizeMarkdown(String text) =>
    text.replaceAll(RegExp(r'[`*]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

// Inspect scope/identity initializers, not legitimate sessionTokenProvider
// wiring. Also reject token decoding that could hide derivation behind an alias.
final _tokenDerivedScope = RegExp(
  r'\b(?:\w*scope\w*|tenantId|userId|deviceId)\s*[:=]\s*[^;,]*'
  r'\b\w*(?:token|jwt)\w*\b|'
  r'\b(?:decode|parse)\w*(?:token|jwt)\w*\s*\(|'
  r'\b(?:token|jwt)\s*\.\s*(?:split|claims|payload)\b',
  caseSensitive: false,
);

bool _advertisesUnsafeMutation(String markdown) {
  // A warning mentioning the unsafe sequence is required, not forbidden.
  // Look for affirmative safety claims in that sequence's sentence instead.
  return _normalizeMarkdown(markdown).split(RegExp(r'[.!?]')).any((sentence) {
    return RegExp(r'(?:unconditional\s+)?read(?:-plus-|-then-|\s*\+\s*)replace',
                caseSensitive: false)
            .hasMatch(sentence) &&
        RegExp(
                r'\b(?:(?:is|are|makes?|remains?)\s+(?:\w+\s+)?safe|'
                r'(?:can|may)\s+safely|safe\s+(?:for|across)\s+'
                r'(?:concurrent|shared|multiple))\b',
                caseSensitive: false)
            .hasMatch(sentence) &&
        !RegExp(r'\b(?:not|never)\s+(?:\w+\s+)?safe\b', caseSensitive: false)
            .hasMatch(sentence);
  });
}
