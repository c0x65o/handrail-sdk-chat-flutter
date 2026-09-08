import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  group('ChatCommandDispatcher validation', () {
    test(
        'validates descriptor, input, path, and idempotency before token access',
        () async {
      var tokenCalls = 0;
      final transport = FakeHttpTransport(
        (_) async => throw StateError('transport must not run'),
      );
      final dispatcher = _dispatcher(
        transport: transport,
        tokenProvider: () async {
          tokenCalls += 1;
          return 'access-token';
        },
      );

      final results = <ChatCommandResult<String>>[
        await dispatcher.dispatch(
          _descriptor(name: 'Invalid Name'),
          const <String, Object?>{'value': 'ok'},
        ),
        await dispatcher.dispatch(
          _descriptor(),
          const <String, Object?>{'value': 7},
        ),
        await dispatcher.dispatch(
          _descriptor(path: '//outside'),
          const <String, Object?>{'value': 'ok'},
        ),
        await dispatcher.dispatch(
          _descriptor(),
          const <String, Object?>{'value': 'ok'},
          options: const ChatCommandDispatchOptions(
            idempotencyKey: 'invalid key',
          ),
        ),
      ];

      expect(
          results.map((result) => result.status), everyElement('validation'));
      expect(tokenCalls, 0);
      expect(transport.requests, isEmpty);
    });

    test('validates generated idempotency keys before token access', () async {
      var tokenCalls = 0;
      final dispatcher = _dispatcher(
        transport: FakeHttpTransport(
          (_) async => throw StateError('transport must not run'),
        ),
        tokenProvider: () async {
          tokenCalls += 1;
          return 'access-token';
        },
        generateIdempotencyKey: () => 'not valid',
      );

      final result = await dispatcher.dispatch(
        _descriptor(),
        const <String, Object?>{'value': 'ok'},
      );

      expect(result, isA<ChatCommandValidationFailure<String>>());
      expect(tokenCalls, 0);
    });
  });

  group('ChatCommandDispatcher requests', () {
    test('supports every command method and uses normalized dynamic paths',
        () async {
      final transport = FakeHttpTransport(
        (_) async => _response(200, <String, Object?>{'result': 'accepted'}),
      );
      final dispatcher = _dispatcher(transport: transport);

      for (final method in ChatCommandMethod.values) {
        final descriptor = ChatCommandDescriptor<Map<String, Object?>,
            Map<String, Object?>, String>.withPathBuilder(
          name: 'test.${method.name}',
          method: method,
          pathBuilder: (input) => '/commands/${input['value']}',
          retrySafety: ChatCommandRetrySafety.never,
          validateInput: (input) {
            final value = input['value'];
            if (value is! String) throw const FormatException();
            return <String, Object?>{'value': value.trim()};
          },
          parseResult: _parseResult,
        );

        final result = await dispatcher.dispatch(
          descriptor,
          const <String, Object?>{'value': ' normalized '},
          options: ChatCommandDispatchOptions(
            idempotencyKey: 'method-${method.name}',
          ),
        );
        expect(result, isA<ChatCommandSuccess<String>>());
      }

      expect(
        transport.requests.map((request) => request.method),
        <String>['POST', 'PUT', 'PATCH', 'DELETE'],
      );
      expect(
        transport.requests.map((request) => request.uri.path),
        everyElement('/api/chat/commands/normalized'),
      );
    });

    test('adds bearer and one idempotency key to every attempt', () async {
      const token = 'sentinel-bearer-token';
      var keyCalls = 0;
      final transport = FakeHttpTransport((request) async {
        if (request.method == 'POST' &&
            request.headers['Authorization'] == 'Bearer $token') {
          return _response(200, <String, Object?>{'result': 'ok'});
        }
        throw StateError('unexpected request');
      });
      final dispatcher = _dispatcher(
        transport: transport,
        tokenProvider: () async => token,
        generateIdempotencyKey: () {
          keyCalls += 1;
          return 'stable-idempotency-key';
        },
      );

      final result = await dispatcher.dispatch(
        _descriptor(),
        const <String, Object?>{'value': 'payload'},
      );

      expect(result, isA<ChatCommandSuccess<String>>());
      expect(keyCalls, 1);
      final request = transport.requests.single;
      expect(request.headers, containsPair('Accept', 'application/json'));
      expect(request.headers, containsPair('Authorization', 'Bearer $token'));
      expect(
        request.headers,
        containsPair('Idempotency-Key', 'stable-idempotency-key'),
      );
      expect(request.headers, containsPair('Content-Type', 'application/json'));
      expect(jsonDecode(request.body!), <String, Object?>{'value': 'payload'});
      expect(request.cancellationSignal, isA<ChatCommandCancellationSignal>());
    });

    test('accepts a strictly parsed domain result from an error status',
        () async {
      final dispatcher = _dispatcher(
        transport: FakeHttpTransport(
          (_) async => _response(
            422,
            <String, Object?>{'existingResult': 'already-applied'},
          ),
        ),
      );
      final descriptor = _descriptor(
        parseErrorResult: (value, status) {
          if (status == 422 &&
              value is Map &&
              value.length == 1 &&
              value['existingResult'] is String) {
            return value['existingResult']! as String;
          }
          return null;
        },
      );

      final result = await dispatcher.dispatch(
        descriptor,
        const <String, Object?>{'value': 'payload'},
      );

      expect(result, isA<ChatCommandSuccess<String>>());
      expect((result as ChatCommandSuccess<String>).value, 'already-applied');
    });
  });

  group('ChatCommandDispatcher retries and authentication', () {
    test(
        'retries failures only for explicitly safe commands with bounded waits',
        () async {
      final delays = <Duration>[];
      var safeAttempt = 0;
      final safeTransport = FakeHttpTransport((_) async {
        safeAttempt += 1;
        if (safeAttempt == 1) throw StateError('network failure');
        if (safeAttempt == 2) return _response(503, _serverError('BUSY'));
        return _response(200, <String, Object?>{'result': 'ok'});
      });
      final safeDispatcher = _dispatcher(
        transport: safeTransport,
        retryOptions: ChatCommandRetryOptions(
          maxAttempts: 3,
          backoff: (retryNumber) => Duration(milliseconds: retryNumber * 7),
          wait: (delay, _) async => delays.add(delay),
        ),
      );

      final safeResult = await safeDispatcher.dispatch(
        _descriptor(retrySafety: ChatCommandRetrySafety.safe),
        const <String, Object?>{'value': 'payload'},
      );

      expect(safeResult, isA<ChatCommandSuccess<String>>());
      expect(safeTransport.requests, hasLength(3));
      expect(delays, const <Duration>[
        Duration(milliseconds: 7),
        Duration(milliseconds: 14),
      ]);
      expect(
        safeTransport.requests
            .map((request) => request.headers['Idempotency-Key'])
            .toSet(),
        <String>{'deterministic-key'},
      );

      for (final response in <Future<HandrailChatHttpResponse> Function()>[
        () => Future<HandrailChatHttpResponse>.error(
              StateError('network failure'),
            ),
        () async => _response(503, _serverError('BUSY')),
      ]) {
        final unsafeTransport = FakeHttpTransport((_) => response());
        final unsafeDispatcher = _dispatcher(
          transport: unsafeTransport,
          retryOptions: ChatCommandRetryOptions(
            wait: (_, __) async => fail('unsafe command scheduled a retry'),
          ),
        );

        final result = await unsafeDispatcher.dispatch(
          _descriptor(retrySafety: ChatCommandRetrySafety.never),
          const <String, Object?>{'value': 'payload'},
        );

        expect(result, isA<ChatCommandTransportFailure<String>>());
        expect(unsafeTransport.requests, hasLength(1));
      }
    });

    test('refreshes a refreshable 401 once without changing idempotency',
        () async {
      var tokenCalls = 0;
      final transport = FakeHttpTransport(
        (_) async => _response(
          401,
          _serverError('TOKEN_EXPIRED', refreshable: true),
        ),
      );
      final dispatcher = _dispatcher(
        transport: transport,
        tokenProvider: () async => 'token-${++tokenCalls}',
      );

      final result = await dispatcher.dispatch(
        _descriptor(retrySafety: ChatCommandRetrySafety.safe),
        const <String, Object?>{'value': 'payload'},
      );

      expect(result, isA<ChatCommandAuthenticationFailure<String>>());
      expect(
          (result as ChatCommandAuthenticationFailure<String>).httpStatus, 401);
      expect(tokenCalls, 2);
      expect(transport.requests, hasLength(2));
      expect(
        transport.requests.map((request) => request.headers['Authorization']),
        <String>['Bearer token-1', 'Bearer token-2'],
      );
      expect(
        transport.requests
            .map((request) => request.headers['Idempotency-Key'])
            .toSet(),
        <String>{'deterministic-key'},
      );
    });

    test('continues successfully after its single authentication refresh',
        () async {
      var tokenCalls = 0;
      var requestCalls = 0;
      final transport = FakeHttpTransport((_) async {
        requestCalls += 1;
        if (requestCalls == 1) {
          return _response(
            401,
            _serverError('TOKEN_EXPIRED', refreshable: true),
          );
        }
        return _response(200, <String, Object?>{'result': 'refreshed'});
      });
      final dispatcher = _dispatcher(
        transport: transport,
        tokenProvider: () async => 'token-${++tokenCalls}',
      );

      final result = await dispatcher.dispatch(
        _descriptor(retrySafety: ChatCommandRetrySafety.never),
        const <String, Object?>{'value': 'payload'},
      );

      expect(result, isA<ChatCommandSuccess<String>>());
      expect((result as ChatCommandSuccess<String>).value, 'refreshed');
      expect(tokenCalls, 2);
      expect(transport.requests, hasLength(2));
    });
  });

  group('ChatCommandDispatcher cancellation', () {
    test('caller cancellation during token resolution is aborted', () async {
      final token = Completer<String>();
      final cancellation = ChatCommandCancellationController();
      final dispatcher = _dispatcher(
        transport: FakeHttpTransport(
          (_) async => throw StateError('transport must not run'),
        ),
        tokenProvider: () => token.future,
      );

      final future = dispatcher.dispatch(
        _descriptor(),
        const <String, Object?>{'value': 'payload'},
        options: ChatCommandDispatchOptions(
          cancellationSignal: cancellation.signal,
        ),
      );
      await _pump();
      cancellation.cancel();

      expect(await future, isA<ChatCommandAborted<String>>());
    });

    test('close during token resolution is closed', () async {
      final token = Completer<String>();
      final dispatcher = _dispatcher(
        transport: FakeHttpTransport(
          (_) async => throw StateError('transport must not run'),
        ),
        tokenProvider: () => token.future,
      );

      final future = dispatcher.dispatch(
        _descriptor(),
        const <String, Object?>{'value': 'payload'},
      );
      await _pump();
      dispatcher.closeActive();

      expect(await future, isA<ChatCommandClosed<String>>());
    });

    test('caller cancellation and close interrupt transport distinctly',
        () async {
      for (final close in <bool>[false, true]) {
        final response = Completer<HandrailChatHttpResponse>();
        final cancellation = ChatCommandCancellationController();
        final transport = FakeHttpTransport((_) => response.future);
        final dispatcher = _dispatcher(transport: transport);
        final future = dispatcher.dispatch(
          _descriptor(),
          const <String, Object?>{'value': 'payload'},
          options: ChatCommandDispatchOptions(
            cancellationSignal: cancellation.signal,
          ),
        );
        await _pumpUntil(() => transport.requests.isNotEmpty);

        if (close) {
          dispatcher.closeActive();
        } else {
          cancellation.cancel();
        }

        expect(
          await future,
          close
              ? isA<ChatCommandClosed<String>>()
              : isA<ChatCommandAborted<String>>(),
        );
      }
    });

    test('caller cancellation and close interrupt response parsing distinctly',
        () async {
      for (final close in <bool>[false, true]) {
        final cancellation = ChatCommandCancellationController();
        late ChatCommandDispatcher dispatcher;
        final descriptor = _descriptor(
          parseResult: (value) {
            if (close) {
              dispatcher.closeActive();
            } else {
              cancellation.cancel();
            }
            return _parseResult(value);
          },
        );
        dispatcher = _dispatcher(
          transport: FakeHttpTransport(
            (_) async => _response(200, <String, Object?>{'result': 'ok'}),
          ),
        );

        final result = await dispatcher.dispatch(
          descriptor,
          const <String, Object?>{'value': 'payload'},
          options: ChatCommandDispatchOptions(
            cancellationSignal: cancellation.signal,
          ),
        );

        expect(
          result,
          close
              ? isA<ChatCommandClosed<String>>()
              : isA<ChatCommandAborted<String>>(),
        );
      }
    });

    test('caller cancellation and close interrupt retry waits distinctly',
        () async {
      for (final close in <bool>[false, true]) {
        final waitStarted = Completer<void>();
        final neverWait = Completer<void>();
        final cancellation = ChatCommandCancellationController();
        final dispatcher = _dispatcher(
          transport: FakeHttpTransport(
            (_) async => _response(503, _serverError('BUSY')),
          ),
          retryOptions: ChatCommandRetryOptions(
            wait: (_, __) {
              if (!waitStarted.isCompleted) waitStarted.complete();
              return neverWait.future;
            },
          ),
        );
        final future = dispatcher.dispatch(
          _descriptor(retrySafety: ChatCommandRetrySafety.safe),
          const <String, Object?>{'value': 'payload'},
          options: ChatCommandDispatchOptions(
            cancellationSignal: cancellation.signal,
          ),
        );
        await waitStarted.future;

        if (close) {
          dispatcher.closeActive();
        } else {
          cancellation.cancel();
        }

        expect(
          await future,
          close
              ? isA<ChatCommandClosed<String>>()
              : isA<ChatCommandAborted<String>>(),
        );
      }
    });
  });

  group('ChatCommandDispatcher response classification', () {
    test('maps malformed status, JSON, result, and error payloads', () async {
      final cases = <HandrailChatHttpResponse>[
        const HandrailChatHttpResponse(statusCode: 99, body: '{}'),
        const HandrailChatHttpResponse(statusCode: 200, body: '{not-json'),
        _response(200, <String, Object?>{'wrong': 'shape'}),
        _response(
          400,
          <String, Object?>{
            'error': <String, Object?>{
              'code': 'BAD',
              'message': 'bad',
              'unexpected': true,
            },
          },
        ),
        _response(
          401,
          <String, Object?>{
            'error': <String, Object?>{
              'code': 'TOKEN_EXPIRED',
              'message': 'expired',
              'refreshable': null,
            },
          },
        ),
      ];

      for (final response in cases) {
        final result = await _dispatcher(
          transport: FakeHttpTransport((_) async => response),
        ).dispatch(
          _descriptor(),
          const <String, Object?>{'value': 'payload'},
        );
        expect(result, isA<ChatCommandMalformedResponse<String>>());
      }

      final parserResult = await _dispatcher(
        transport: FakeHttpTransport(
          (_) async => _response(400, <String, Object?>{'domain': true}),
        ),
      ).dispatch(
        _descriptor(
          parseErrorResult: (_, __) =>
              throw StateError('invalid domain payload'),
        ),
        const <String, Object?>{'value': 'payload'},
      );
      expect(parserResult, isA<ChatCommandMalformedResponse<String>>());
    });

    test('maps HTTP failures to every required non-malformed category',
        () async {
      final cases = <(int, String, Type)>[
        (409, 'CONFLICT', ChatCommandConflict<String>),
        (400, 'FEATURE_DISABLED_BY_HOST', ChatCommandFeatureDisabled<String>),
        (404, 'NOT_FOUND', ChatCommandUnsupported<String>),
        (403, 'FORBIDDEN', ChatCommandAuthenticationFailure<String>),
        (422, 'INVALID_STATE', ChatCommandRejected<String>),
        (500, 'INTERNAL', ChatCommandTransportFailure<String>),
      ];

      for (final (status, code, expectedType) in cases) {
        final result = await _dispatcher(
          transport: FakeHttpTransport(
            (_) async => _response(status, _serverError(code)),
          ),
        ).dispatch(
          _descriptor(),
          const <String, Object?>{'value': 'payload'},
        );
        expect(result.runtimeType, expectedType);
      }
    });
  });

  test('diagnostics and string output cannot reveal transport secrets',
      () async {
    const token = 'SENTINEL_TOKEN';
    const body = 'SENTINEL_BODY';
    const header = 'SENTINEL_HEADER';
    const thrown = 'SENTINEL_THROWN_TEXT';
    final diagnostics = <ChatCommandDiagnostic>[];
    final transport = FakeHttpTransport((_) async {
      throw StateError(thrown);
    });
    final dispatcher = _dispatcher(
      transport: transport,
      tokenProvider: () async => token,
      onDiagnostic: (diagnostic) {
        diagnostics.add(diagnostic);
        throw StateError('diagnostic callback $thrown');
      },
    );

    final result = await dispatcher.dispatch(
      _descriptor(),
      const <String, Object?>{'value': body},
      options: const ChatCommandDispatchOptions(
        idempotencyKey: 'safe-idempotency-key',
      ),
    );
    final request = transport.requests.single;
    final syntheticRequest = HandrailChatHttpRequest(
      method: 'POST',
      uri: Uri.parse(
        'https://$token@chat.example.test/commands?secret=$body#$thrown',
      ),
      headers: const <String, String>{'X-Sensitive': header},
      body: body,
    );
    const response = HandrailChatHttpResponse(statusCode: 500, body: body);
    final strings = <String>[
      result.toString(),
      request.toString(),
      syntheticRequest.toString(),
      response.toString(),
      ...diagnostics.map((diagnostic) => diagnostic.toString()),
    ].join('\n');

    expect(result, isA<ChatCommandTransportFailure<String>>());
    expect(diagnostics, isNotEmpty);
    for (final secret in <String>[token, body, header, thrown]) {
      expect(strings, isNot(contains(secret)));
    }
    expect(strings, isNot(contains('X-Sensitive')));
  });
}

ChatCommandDescriptor<Map<String, Object?>, Map<String, Object?>,
    String> _descriptor({
  String name = 'test.command',
  String path = '/commands',
  ChatCommandMethod method = ChatCommandMethod.post,
  ChatCommandRetrySafety retrySafety = ChatCommandRetrySafety.never,
  ChatCommandResultParser<String> parseResult = _parseResult,
  ChatCommandErrorResultParser<String>? parseErrorResult,
}) =>
    ChatCommandDescriptor<Map<String, Object?>, Map<String, Object?>, String>(
      name: name,
      method: method,
      path: path,
      retrySafety: retrySafety,
      validateInput: (input) {
        final value = input['value'];
        if (value is! String) throw const FormatException();
        return <String, Object?>{'value': value};
      },
      parseResult: parseResult,
      parseErrorResult: parseErrorResult,
    );

String _parseResult(Object? value) {
  if (value is! Map || value.length != 1 || value['result'] is! String) {
    throw const FormatException();
  }
  return value['result']! as String;
}

Map<String, Object?> _serverError(String code, {bool refreshable = false}) =>
    <String, Object?>{
      'error': <String, Object?>{
        'code': code,
        'message': 'Stable server error.',
        if (refreshable) 'refreshable': true,
      },
    };

HandrailChatHttpResponse _response(int status, Object? body) =>
    HandrailChatHttpResponse(statusCode: status, body: jsonEncode(body));

ChatCommandDispatcher _dispatcher({
  required FakeHttpTransport transport,
  HandrailChatAccessTokenProvider? tokenProvider,
  ChatCommandRetryOptions retryOptions = const ChatCommandRetryOptions(),
  ChatCommandIdempotencyKeyGenerator? generateIdempotencyKey,
  ChatCommandDiagnosticCallback? onDiagnostic,
}) =>
    ChatCommandDispatcher(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat/'),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: transport,
      retryOptions: retryOptions,
      generateIdempotencyKey:
          generateIdempotencyKey ?? () => 'deterministic-key',
      onDiagnostic: onDiagnostic,
    );

final class FakeHttpTransport implements HandrailChatHttpTransport {
  FakeHttpTransport(this._send);

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

Future<void> _pump() => Future<void>.delayed(Duration.zero);

Future<void> _pumpUntil(bool Function() condition) async {
  for (var index = 0; index < 50 && !condition(); index += 1) {
    await _pump();
  }
  expect(condition(), isTrue, reason: 'asynchronous phase was not reached');
}
