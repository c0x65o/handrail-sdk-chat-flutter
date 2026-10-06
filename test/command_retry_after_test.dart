import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_chat/core.dart';

// Exercise the shipped host adapter, which belongs to the separate example package.
// ignore: avoid_relative_lib_imports
import '../examples/flutter-erp/lib/erp_chat_host.dart'
    show ErpChatHttpTransport;

final descriptor = ChatCommandDescriptor<Object?, Object?, Object?>(
  name: 'fixture.command',
  method: ChatCommandMethod.post,
  path: '/commands',
  retrySafety: ChatCommandRetrySafety.safe,
  validateInput: (x) => x,
  parseResult: (x) => x,
);
final epoch = DateTime.utc(2026, 10, 6, 19);
HandrailChatHttpResponse reply(int status, [String? header]) =>
    HandrailChatHttpResponse(
      statusCode: status,
      body: '{}',
      headers: {if (header != null) 'ReTrY-AfTeR': header},
    );

class FixtureTransport implements HandrailChatHttpTransport {
  FixtureTransport(this.handler);
  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)
      handler;
  final requests = <HandrailChatHttpRequest>[];
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) {
    requests.add(request);
    return handler(request);
  }
}

class Fixture {
  Fixture(
      Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest) send,
      {ChatCommandWait? wait}) {
    transport = FixtureTransport(send);
    dispatcher = ChatCommandDispatcher(
      apiBaseUri: Uri.parse('https://fixture.invalid'),
      tokenProvider: () async => 'fixture-token',
      transport: transport,
      generateIdempotencyKey: () => 'fixture-key',
      retryOptions: ChatCommandRetryOptions(
          now: () => time,
          wait: wait ??
              (delay, _) async {
                waits.add(delay);
                time = time.add(delay);
              }),
    );
  }
  DateTime time = epoch;
  final waits = <Duration>[];
  late final FixtureTransport transport;
  late final ChatCommandDispatcher dispatcher;
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'expected asynchronous phase');
}

void main() {
  for (final entry in <String?, int>{
    '0': 100,
    'Tue, 06 Oct 2026 18:00:00 GMT': 100,
    '60': 60000,
    'Tue, 06 Oct 2026 19:02:00 GMT': 120000,
    null: 60000,
    'garbage': 60000,
    '-1': 60000,
    'Infinity': 60000,
    '9' * 400: 60000
  }.entries) {
    test(
        'Retry-After ${entry.key?.substring(0, entry.key!.length.clamp(0, 40))}',
        () async {
      var attempts = 0;
      final f =
          Fixture((_) async => reply(++attempts == 1 ? 429 : 200, entry.key));
      expect(
          (await f.dispatcher.dispatch(descriptor, {'content': 'fixture'}))
              .status,
          'success');
      expect(f.time.difference(epoch).inMilliseconds, entry.value);
      expect(
          f.waits.every(
              (d) => d > Duration.zero && d <= const Duration(seconds: 60)),
          isTrue);
      expect(
          f.transport.requests.map((r) => r.headers['Idempotency-Key']).toSet(),
          hasLength(1));
      expect(f.transport.requests.map((r) => r.body).toSet(), hasLength(1));
    });
  }
  for (final headers in [
    ['10', '30'],
    ['30', '10']
  ]) {
    test(
        'overlap $headers extends waiting and new commands; success cannot shorten cooldown',
        () async {
      final responses = <Completer<HandrailChatHttpResponse>>[];
      final waits = <({Duration delay, Completer<void> done})>[];
      final f = Fixture((_) {
        final c = Completer<HandrailChatHttpResponse>();
        responses.add(c);
        return c.future;
      }, wait: (delay, _) {
        final c = Completer<void>();
        waits.add((delay: delay, done: c));
        return c.future;
      });
      final a = f.dispatcher.dispatch(descriptor, {'id': 'a'}),
          b = f.dispatcher.dispatch(descriptor, {'id': 'b'}),
          c = f.dispatcher.dispatch(descriptor, {'id': 'c'});
      await until(() => responses.length == 3);
      responses[0].complete(reply(429, headers[0]));
      await until(() => waits.length == 1);
      responses[1].complete(reply(429, headers[1]));
      responses[2].complete(reply(200));
      await c;
      await until(() => waits.length == 2);
      final d = f.dispatcher.dispatch(descriptor, {'id': 'd'});
      await until(() => waits.length == 3);
      f.time = f.time.add(const Duration(seconds: 10));
      waits[0].done.complete();
      await until(() => waits.length == 4);
      expect(responses, hasLength(3));
      expect(waits[3].delay, const Duration(seconds: 20));
      f.time = f.time.add(const Duration(seconds: 20));
      for (final w in waits.skip(1)) {
        w.done.complete();
      }
      await until(() => responses.length == 6);
      for (final r in responses.skip(3)) {
        r.complete(reply(200));
      }
      expect((await Future.wait([a, b, d])).map((r) => r.status),
          everyElement('success'));
    });
  }
  for (final mode in ['abort', 'close']) {
    test('$mode during cooldown prevents retry', () async {
      final started = Completer<void>();
      final cancellation = ChatCommandCancellationController();
      final f = Fixture((_) async => reply(429, '120'), wait: (_, __) {
        started.complete();
        return Completer<void>().future;
      });
      final result = f.dispatcher.dispatch(descriptor, {},
          options: ChatCommandDispatchOptions(
              cancellationSignal: cancellation.signal));
      await started.future;
      if (mode == 'abort') {
        cancellation.cancel();
      } else {
        f.dispatcher.closeActive();
      }
      expect((await result).status, mode == 'abort' ? 'aborted' : 'closed');
      expect(f.transport.requests, hasLength(1));
    });
  }
  test('bounded attempts retain cooldown for the next command', () async {
    final f = Fixture((_) async => reply(429, '2'));
    expect((await f.dispatcher.dispatch(descriptor, {})).status, 'transport');
    expect(f.transport.requests, hasLength(3));
    expect(f.waits.map((d) => d.inSeconds), [2, 2]);
    expect((await f.dispatcher.dispatch(descriptor, {})).status, 'transport');
    expect(f.transport.requests, hasLength(6));
    expect(f.waits.map((d) => d.inSeconds), [2, 2, 2, 2, 2]);
  });
  test(
      'lost acknowledgement and 429 keep one identity and successful side effect',
      () async {
    var attempts = 0;
    final accepted = <String?, String?>{};
    final f = Fixture((request) async {
      attempts++;
      if (attempts == 2) return reply(429, '10');
      accepted.putIfAbsent(
          request.headers['Idempotency-Key'], () => request.body);
      if (attempts == 1) throw StateError('fixture lost acknowledgement');
      return reply(200);
    });
    expect(
        (await f.dispatcher.dispatch(descriptor, {'content': 'once'})).status,
        'success');
    expect(accepted, hasLength(1));
    expect(f.transport.requests, hasLength(3));
    expect(f.waits.map((d) => d.inMilliseconds), [100, 10000]);
    expect(
        f.transport.requests.map((r) => r.headers['Idempotency-Key']).toSet(),
        hasLength(1));
  });
  test(
      'late old-identity response after close cannot impose cooldown on reused dispatcher',
      () async {
    final oldResponse = Completer<HandrailChatHttpResponse>();
    var calls = 0;
    final f = Fixture(
        (_) => ++calls == 1 ? oldResponse.future : Future.value(reply(200)));
    final old = f.dispatcher.dispatch(descriptor, {},
        options:
            const ChatCommandDispatchOptions(idempotencyKey: 'old-identity'));
    await until(() => calls == 1);
    f.dispatcher.closeActive();
    expect((await old).status, 'closed');
    oldResponse.complete(reply(429, '120'));
    expect(
        (await f.dispatcher.dispatch(descriptor, {},
                options: const ChatCommandDispatchOptions(
                    idempotencyKey: 'new-identity')))
            .status,
        'success');
    expect(f.waits, isEmpty);
    expect(
        f.transport.requests.last.headers['Idempotency-Key'], 'new-identity');
  });
  test(
      'actual HTTP headers propagate through shipped ERP adapter and public dispatcher',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var attempts = 0;
    final subscription = server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = ++attempts == 1 ? 429 : 200;
      request.response.headers.set('Retry-After', '2');
      request.response.write('{}');
      await request.response.close();
    });
    final transport = ErpChatHttpTransport();
    var time = epoch;
    final waits = <Duration>[];
    final dispatcher = ChatCommandDispatcher(
        apiBaseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        tokenProvider: () async => 'fixture-token',
        transport: transport,
        generateIdempotencyKey: () => 'fixture-key',
        retryOptions: ChatCommandRetryOptions(
            now: () => time,
            wait: (delay, _) async {
              waits.add(delay);
              time = time.add(delay);
            }));
    try {
      expect((await dispatcher.dispatch(descriptor, {})).status, 'success');
      expect(waits, [const Duration(seconds: 2)]);
      expect(attempts, 2);
    } finally {
      dispatcher.closeActive();
      transport.close();
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
