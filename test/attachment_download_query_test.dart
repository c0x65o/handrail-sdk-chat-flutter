import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

import 'fixtures/attachment_transport_fixtures.dart';

final _fixedNow = DateTime.parse(fixtureNow);

void main() {
  group('attachment download request construction', () {
    test('encodes identifiers, authenticates, and returns the opaque result',
        () async {
      const attachmentId = 'attachment/A B?#%';
      const messageId = 'message/A B&?#%';
      const accessToken = 'attachment-download-token';
      final transport = _FakeHttpTransport(
        (_) async => _response(
          200,
          _downloadFixture(
            attachmentId: attachmentId,
            messageId: messageId,
          ),
        ),
      );
      final client = _client(
        transport: transport,
        tokenProvider: () async => accessToken,
      );

      final result = await client.getAttachmentDownload(
        GetAttachmentDownloadInput(
          attachmentId: const AttachmentId(attachmentId),
          messageId: const MessageId(messageId),
        ),
      );

      expect(
        result,
        isA<ChatSnapshotQuerySuccess<GetAttachmentDownloadResult>>(),
      );
      final request = transport.requests.single;
      expect(request.method, 'GET');
      expect(
        request.uri.toString(),
        'https://chat.example.test/api/chat/attachments/'
        'attachment%2FA%20B%3F%23%25/download?'
        'messageId=message%2FA+B%26%3F%23%25',
      );
      expect(request.uri.queryParameters, const {'messageId': messageId});
      expect(request.headers, const <String, String>{
        'Accept': 'application/json',
        'Authorization': 'Bearer $accessToken',
      });
      expect(request.cancellationSignal, isA<ChatCommandCancellationSignal>());

      final value =
          (result as ChatSnapshotQuerySuccess<GetAttachmentDownloadResult>)
              .value;
      expect(value.attachmentId, const AttachmentId(attachmentId));
      expect(value.messageId, const MessageId(messageId));
      expect(value.attachment.status, AttachmentLifecycleStatus.attached);
      expect(value.download.kind, 'opaque_attachment_download');
      expect(
        value.download.descriptor,
        downloadDescriptorFixture['descriptor'],
      );
      await client.dispose();
    });
  });

  group('attachment download outcomes', () {
    test('validates input before authentication', () async {
      var tokenCalls = 0;
      final diagnostics = <ChatSnapshotQueryDiagnostic>[];
      final client = _client(
        transport: _FakeHttpTransport(
          (_) async => throw StateError('transport must not run'),
        ),
        tokenProvider: () async {
          tokenCalls += 1;
          return 'token';
        },
        onDiagnostic: diagnostics.add,
      );

      final result = await client.getAttachmentDownload(
        GetAttachmentDownloadInput(
          attachmentId: const AttachmentId(''),
          messageId: const MessageId(''),
        ),
      );

      expect(
        result,
        isA<ChatSnapshotQueryValidationFailure<GetAttachmentDownloadResult>>(),
      );
      expect(tokenCalls, 0);
      expect(
          diagnostics.single.query, ChatSnapshotQueryName.attachmentDownload);
      expect(
        diagnostics.single.event,
        ChatSnapshotQueryDiagnosticEvent.validationFailed,
      );
      await client.dispose();
    });

    test('rejects mismatched attachment, message, and lifecycle bindings',
        () async {
      final valid = _downloadFixture();
      final invalid = <Map<String, Object?>>[
        {...valid, 'attachmentId': 'attachment-other'},
        {...valid, 'messageId': 'message-other'},
        {
          ...valid,
          'attachment': {
            ...attachedAttachmentFixture,
            'attachmentId': 'attachment-other',
          },
        },
        {
          ...valid,
          'attachment': {
            ...attachedAttachmentFixture,
            'messageId': 'message-other',
          },
        },
        {...valid, 'attachment': finalizedAttachmentFixture},
      ];

      for (final body in invalid) {
        final client = _client(
          transport: _FakeHttpTransport((_) async => _response(200, body)),
        );
        final result = await client.getAttachmentDownload(_input());
        expect(
          result,
          isA<
              ChatSnapshotQueryMalformedResponse<
                  GetAttachmentDownloadResult>>(),
        );
        expect(
          (result as ChatSnapshotQueryMalformedResponse).httpStatus,
          200,
        );
        await client.dispose();
      }
    });

    test('rejects expired descriptors and incorrect descriptor kinds',
        () async {
      for (final descriptor in <Map<String, Object?>>[
        {
          ...downloadDescriptorFixture,
          'expiresAt': fixtureNow,
        },
        {
          ...downloadDescriptorFixture,
          'kind': 'opaque_attachment_upload',
        },
      ]) {
        final client = _client(
          transport: _FakeHttpTransport(
            (_) async => _response(
              200,
              _downloadFixture(download: descriptor),
            ),
          ),
        );

        final result = await client.getAttachmentDownload(_input());

        expect(
          result,
          isA<
              ChatSnapshotQueryMalformedResponse<
                  GetAttachmentDownloadResult>>(),
        );
        await client.dispose();
      }
    });

    test('cancels before authentication and while transport is pending',
        () async {
      final alreadyCancelled = ChatCommandCancellationController()..cancel();
      var tokenCalls = 0;
      final beforeClient = _client(
        transport: _FakeHttpTransport(
          (_) async => throw StateError('transport must not run'),
        ),
        tokenProvider: () async {
          tokenCalls += 1;
          return 'token';
        },
      );
      final before = await beforeClient.getAttachmentDownload(
        _input(),
        options: ChatSnapshotQueryOptions(
          cancellationSignal: alreadyCancelled.signal,
        ),
      );
      expect(
        before,
        isA<ChatSnapshotQueryAborted<GetAttachmentDownloadResult>>(),
      );
      expect(tokenCalls, 0);
      await beforeClient.dispose();

      final pendingResponse = Completer<HandrailChatHttpResponse>();
      final duringCancellation = ChatCommandCancellationController();
      final transport = _FakeHttpTransport((_) => pendingResponse.future);
      final duringClient = _client(transport: transport);
      final during = duringClient.getAttachmentDownload(
        _input(),
        options: ChatSnapshotQueryOptions(
          cancellationSignal: duringCancellation.signal,
        ),
      );
      await _pumpUntil(() => transport.requests.isNotEmpty);
      duringCancellation.cancel();

      expect(
        await during,
        isA<ChatSnapshotQueryAborted<GetAttachmentDownloadResult>>(),
      );
      expect(
        transport.requests.single.cancellationSignal,
        isA<ChatCommandCancellationSignal>()
            .having((signal) => signal.isCancelled, 'isCancelled', isTrue),
      );
      await duringClient.dispose();
    });

    test('maps authentication, rejection, server, and transport failures',
        () async {
      final authenticationTransport = _FakeHttpTransport(
        (_) async => throw StateError('transport must not run'),
      );
      final authenticationClient = _client(
        transport: authenticationTransport,
        tokenProvider: () async => '',
      );
      expect(
        await authenticationClient.getAttachmentDownload(_input()),
        isA<
            ChatSnapshotQueryAuthenticationFailure<
                GetAttachmentDownloadResult>>(),
      );
      expect(authenticationTransport.requests, isEmpty);
      await authenticationClient.dispose();

      for (final expectation in <(int, Matcher)>[
        (
          403,
          isA<
              ChatSnapshotQueryAuthenticationFailure<
                  GetAttachmentDownloadResult>>(),
        ),
        (
          422,
          isA<ChatSnapshotQueryRejected<GetAttachmentDownloadResult>>(),
        ),
        (
          503,
          isA<ChatSnapshotQueryTransportFailure<GetAttachmentDownloadResult>>(),
        ),
      ]) {
        final client = _client(
          transport: _FakeHttpTransport(
            (_) async => HandrailChatHttpResponse(
              statusCode: expectation.$1,
              body: 'untrusted body',
            ),
          ),
        );
        final result = await client.getAttachmentDownload(_input());
        expect(result, expectation.$2);
        expect((result as ChatSnapshotQueryFailure).httpStatus, expectation.$1);
        await client.dispose();
      }

      final transportClient = _client(
        transport: _FakeHttpTransport(
          (_) async => throw StateError('untrusted transport exception'),
        ),
      );
      expect(
        await transportClient.getAttachmentDownload(_input()),
        isA<ChatSnapshotQueryTransportFailure<GetAttachmentDownloadResult>>(),
      );
      await transportClient.dispose();
    });

    test('keeps tokens, bodies, descriptors, URLs, and exceptions redacted',
        () async {
      const tokenSentinel = 'TOKEN_SENTINEL_9cba';
      const bodySentinel = 'BODY_SENTINEL_81ab';
      const descriptorSentinel = 'DESCRIPTOR_SENTINEL_44dc';
      const providerUrlSentinel =
          'https://provider.invalid/private/PROVIDER_URL_SENTINEL_15ef';
      const exceptionSentinel = 'EXCEPTION_SENTINEL_d4c1';
      final diagnostics = <ChatSnapshotQueryDiagnostic>[];
      final rejectedResponse = HandrailChatHttpResponse(
        statusCode: 422,
        body: bodySentinel,
      );
      final rejectedTransport = _FakeHttpTransport(
        (_) async => rejectedResponse,
      );
      final rejectedClient = _client(
        transport: rejectedTransport,
        tokenProvider: () async => tokenSentinel,
        onDiagnostic: diagnostics.add,
      );
      final rejected = await rejectedClient.getAttachmentDownload(_input());

      final exceptionClient = _client(
        transport: _FakeHttpTransport(
          (_) async => throw StateError(exceptionSentinel),
        ),
        onDiagnostic: diagnostics.add,
      );
      final transportFailure =
          await exceptionClient.getAttachmentDownload(_input());

      final successTransport = _FakeHttpTransport(
        (_) async => _response(
          200,
          _downloadFixture(
            download: {
              ...downloadDescriptorFixture,
              'descriptor': '$providerUrlSentinel?$descriptorSentinel',
            },
          ),
        ),
      );
      final successClient = _client(
        transport: successTransport,
        tokenProvider: () async => tokenSentinel,
        onDiagnostic: diagnostics.add,
      );
      final success = await successClient.getAttachmentDownload(_input())
          as ChatSnapshotQuerySuccess<GetAttachmentDownloadResult>;

      final structuralStrings = <String>[
        rejected.toString(),
        transportFailure.toString(),
        rejectedResponse.toString(),
        rejectedTransport.requests.single.toString(),
        success.toString(),
        success.value.toString(),
        success.value.attachment.toString(),
        success.value.download.toString(),
        successTransport.requests.single.toString(),
        ...diagnostics.map((diagnostic) => diagnostic.toString()),
      ];
      for (final text in structuralStrings) {
        expect(text, isNot(contains(tokenSentinel)));
        expect(text, isNot(contains(bodySentinel)));
        expect(text, isNot(contains(descriptorSentinel)));
        expect(text, isNot(contains(providerUrlSentinel)));
        expect(text, isNot(contains(exceptionSentinel)));
      }

      await rejectedClient.dispose();
      await exceptionClient.dispose();
      await successClient.dispose();
    });
  });
}

GetAttachmentDownloadInput _input() => GetAttachmentDownloadInput(
      attachmentId: const AttachmentId('attachment-1'),
      messageId: const MessageId('message-1'),
    );

Map<String, Object?> _downloadFixture({
  String attachmentId = 'attachment-1',
  String messageId = 'message-1',
  Map<String, Object?>? download,
}) =>
    {
      'operation': 'get_attachment_download',
      'attachmentId': attachmentId,
      'messageId': messageId,
      'attachment': {
        ...attachedAttachmentFixture,
        'attachmentId': attachmentId,
        'messageId': messageId,
      },
      'download': download ?? downloadDescriptorFixture,
    };

HandrailChatClient _client({
  required _FakeHttpTransport transport,
  HandrailChatAccessTokenProvider? tokenProvider,
  ChatSnapshotQueryDiagnosticCallback? onDiagnostic,
}) =>
    HandrailChatClient(
      apiBaseUri: Uri.parse(
        'https://chat.example.test/api/chat/?ignored=true#fragment',
      ),
      tokenProvider: tokenProvider ?? () async => 'query-token',
      transport: transport,
      onSnapshotQueryDiagnostic: onDiagnostic,
      attachmentDownloadClock: () => _fixedNow,
    );

final class _FakeHttpTransport implements HandrailChatHttpTransport {
  _FakeHttpTransport(this._send);

  final Future<HandrailChatHttpResponse> Function(
    HandrailChatHttpRequest request,
  ) _send;
  final List<HandrailChatHttpRequest> requests = <HandrailChatHttpRequest>[];

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return _send(request);
  }
}

HandrailChatHttpResponse _response(int status, Object? body) =>
    HandrailChatHttpResponse(statusCode: status, body: jsonEncode(body));

Future<void> _pumpUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}
