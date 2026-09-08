import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/src/handrail_chat_client.dart';
import 'package:test/test.dart';

void main() {
  group('HandrailChatClient initialization', () {
    test('requests resolved metadata and emits idle, initializing, ready',
        () async {
      const accessToken = 'metadata-access-token';
      final requested = <String, bool>{
        'attachments': true,
        'notifications': true,
        'realtime': false,
        'media': true,
      };
      final transport = FakeHttpTransport(
        (_) async => HandrailChatHttpResponse(
          statusCode: 200,
          body: jsonEncode(_metadata()),
        ),
      );
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse(
          'https://chat.example.test/api/chat/?ignored=true#fragment',
        ),
        tokenProvider: () async => accessToken,
        requestedCapabilities: requested,
        transport: transport,
      );
      requested['attachments'] = false;

      expect(client.states.isBroadcast, isTrue);
      final transitions = client.states.take(3).toList();
      expect(client.state, isA<ChatClientIdleState>());

      final state = await client.initialize();

      expect(state, isA<ChatClientReadyState>());
      final ready = state as ChatClientReadyState;
      expect(
        (await transitions).map((value) => value.state),
        <String>['idle', 'initializing', 'ready'],
      );
      expect(transport.requests, hasLength(1));
      final request = transport.requests.single;
      expect(request.method, 'GET');
      expect(
        request.uri,
        Uri.parse('https://chat.example.test/api/chat/_meta'),
      );
      expect(request.headers['Accept'], 'application/json');
      expect(
        request.headers['Authorization'] == 'Bearer $accessToken',
        isTrue,
        reason: 'The Authorization header did not use the provider token.',
      );
      expect(request.toString().contains(accessToken), isFalse);
      expect(client.toString().contains(accessToken), isFalse);

      expect(ready.metadata.packageVersion, '0.1.3');
      expect(ready.negotiatedCapabilities, <String, bool>{
        'attachments': true,
        'notifications': false,
        'realtime': false,
        'media': false,
      });
      expect(
        () => ready.negotiatedCapabilities['attachments'] = false,
        throwsUnsupportedError,
      );
      expect(
        () => client.requestedCapabilities['attachments'] = false,
        throwsUnsupportedError,
      );
      expect(await client.states.first, same(ready));
      await client.dispose();
    });

    test('treats malformed JSON and semantically invalid metadata as malformed',
        () async {
      final bodies = <String>[
        '{not-json',
        jsonEncode(_metadata(packageVersion: '   ')),
        jsonEncode(_metadata(schemaVersion: -1)),
        jsonEncode(
          _metadata(
            supportedProtocolRange: <String, Object?>{
              'minimumVersion': 5,
              'maximumVersion': 6,
            },
          ),
        ),
        jsonEncode(<String, Object?>{..._metadata(), 'unexpected': true}),
        jsonEncode(
          _metadata(
            enabledFeatures: <String, Object?>{'   ': true},
          ),
        ),
      ];

      for (final body in bodies) {
        final client = HandrailChatClient(
          apiBaseUri: Uri.parse('/api/chat'),
          tokenProvider: () async => 'malformed-token',
          transport: FakeHttpTransport(
            (_) async => HandrailChatHttpResponse(
              statusCode: 200,
              body: body,
            ),
          ),
        );

        final state = await client.initialize();

        expect(state, isA<ChatClientErrorState>());
        final error = state as ChatClientErrorState;
        expect(
            error.diagnostic.code, ChatClientDiagnosticCode.malformedMetadata);
        expect(
          error.diagnostic.message,
          'The chat server returned invalid metadata.',
        );
        expect(state.toString().contains('malformed-token'), isFalse);
        expect(error.diagnostic.toString().contains(body), isFalse);
        await client.dispose();
      }
    });

    test('token-provider failure is stable and does not expose thrown text',
        () async {
      const secret = 'provider-secret-value';
      final transport = FakeHttpTransport(
        (_) async => throw StateError('transport must not be called'),
      );
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('/api/chat'),
        tokenProvider: () => Future<String>.error(
          StateError('provider failed with $secret'),
        ),
        transport: transport,
      );
      final transitions = client.states.take(3).toList();

      final state = await client.initialize();

      expect(state, isA<ChatClientErrorState>());
      final error = state as ChatClientErrorState;
      expect(error.diagnostic.code, ChatClientDiagnosticCode.accessTokenFailed);
      expect(
        error.diagnostic.message,
        'Chat credentials could not be obtained.',
      );
      expect(transport.requests, isEmpty);
      expect(state.toString().contains(secret), isFalse);
      expect(error.diagnostic.toString().contains(secret), isFalse);
      expect(
        (await transitions).map((value) => value.state),
        <String>['idle', 'initializing', 'error'],
      );
      await client.dispose();
    });

    test('transport failure does not expose token or thrown text', () async {
      const accessToken = 'transport-access-token';
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('/api/chat'),
        tokenProvider: () async => accessToken,
        transport: FakeHttpTransport(
          (_) async => throw StateError('request failed with $accessToken'),
        ),
      );

      final state = await client.initialize();

      expect(state, isA<ChatClientErrorState>());
      final error = state as ChatClientErrorState;
      expect(
        error.diagnostic.code,
        ChatClientDiagnosticCode.metadataRequestFailed,
      );
      expect(state.toString().contains(accessToken), isFalse);
      expect(error.diagnostic.toString().contains(accessToken), isFalse);
      await client.dispose();
    });

    test('non-2xx errors include status but never the response body', () async {
      const accessToken = 'unauthorized-access-token';
      const responseBody = 'sensitive upstream response body';
      const response = HandrailChatHttpResponse(
        statusCode: 503,
        body: responseBody,
      );
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('/api/chat'),
        tokenProvider: () async => accessToken,
        transport: FakeHttpTransport((_) async => response),
      );

      final state = await client.initialize();

      expect(state, isA<ChatClientErrorState>());
      final error = state as ChatClientErrorState;
      expect(
        error.diagnostic.code,
        ChatClientDiagnosticCode.metadataRequestFailed,
      );
      expect(error.diagnostic.httpStatus, 503);
      expect(error.diagnostic.toString(), contains('503'));
      expect(error.diagnostic.toString().contains(responseBody), isFalse);
      expect(error.diagnostic.toString().contains(accessToken), isFalse);
      expect(response.toString().contains(responseBody), isFalse);
      await client.dispose();
    });

    test('unsupported protocol requires refresh with canonical message',
        () async {
      final client = HandrailChatClient(
        apiBaseUri: Uri.parse('/api/chat'),
        tokenProvider: () async => 'unsupported-protocol-token',
        transport: FakeHttpTransport(
          (_) async => HandrailChatHttpResponse(
            statusCode: 200,
            body: jsonEncode(
              _metadata(
                protocolVersion: 6,
                supportedProtocolRange: <String, Object?>{
                  'minimumVersion': 5,
                  'maximumVersion': 6,
                },
              ),
            ),
          ),
        ),
      );

      final state = await client.initialize();

      expect(state, isA<ChatClientRefreshRequiredState>());
      final refreshRequired = state as ChatClientRefreshRequiredState;
      expect(refreshRequired.reason, 'unsupportedProtocol');
      expect(refreshRequired.message, handrailChatRefreshRequiredMessage);
      expect(
        refreshRequired.message,
        'Chat was updated; refresh to continue.',
      );
      expect(refreshRequired.requestedProtocolVersion, 4);
      await client.dispose();
    });
  });

  test('protocol compatibility window is current and immediately previous', () {
    final range = createSupportedProtocolRange(handrailChatProtocolVersion);

    expect(range.minimumVersion, 3);
    expect(range.maximumVersion, 4);
    expect(isProtocolSupported(3, range), isTrue);
    expect(isProtocolSupported(4, range), isTrue);
    expect(isProtocolSupported(2, range), isFalse);
    expect(createSupportedProtocolRange(1).minimumVersion, 1);
  });
}

Map<String, Object?> _metadata({
  String packageVersion = '0.1.3',
  int protocolVersion = 4,
  int schemaVersion = 7,
  Map<String, Object?> enabledFeatures = const <String, Object?>{
    'attachments': true,
    'notifications': false,
    'realtime': true,
  },
  Map<String, Object?> supportedProtocolRange = const <String, Object?>{
    'minimumVersion': 3,
    'maximumVersion': 4,
  },
}) =>
    <String, Object?>{
      'packageVersion': packageVersion,
      'protocolVersion': protocolVersion,
      'schemaVersion': schemaVersion,
      'enabledFeatures': enabledFeatures,
      'supportedProtocolRange': supportedProtocolRange,
    };

final class FakeHttpTransport implements HandrailChatHttpTransport {
  FakeHttpTransport(this._send);

  final Future<HandrailChatHttpResponse> Function(
    HandrailChatHttpRequest request,
  ) _send;
  final List<HandrailChatHttpRequest> requests = <HandrailChatHttpRequest>[];

  @override
  Future<HandrailChatHttpResponse> send(
    HandrailChatHttpRequest request,
  ) {
    requests.add(request);
    return _send(request);
  }
}
