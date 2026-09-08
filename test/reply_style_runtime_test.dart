import 'dart:async';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

const actor = ChatReplyStyleIdentity(
    tenantId: TenantId('tenant-1'), userId: UserId('user-1'));
const absent = {'state': 'absent', 'revision': 0};
Map<String, Object?> saved(int revision, [String style = 'discord']) =>
    {'state': 'saved', 'revision': revision, 'style': style};
Map<String, Object?> metadata([bool? support = true]) => {
      'packageVersion': '0.1.19',
      'protocolVersion': 4,
      'schemaVersion': 1,
      'enabledFeatures': {
        if (support != null) replyStylePreferenceFeature: support
      },
      'supportedProtocolRange': {'minimumVersion': 1, 'maximumVersion': 4},
    };
HandrailChatHttpResponse response(Object? data, [int status = 200]) =>
    HandrailChatHttpResponse(statusCode: status, body: jsonEncode(data));
Map<String, Object?> result(Map<String, dynamic> input,
        {String status = 'applied', Map<String, Object?>? preference}) =>
    {
      'operation': input['operation'],
      'baseRevision': input['baseRevision'],
      'idempotencyKey': input['idempotencyKey'],
      'requestedStyle': input['style'],
      'reconciliationStatus': status,
      'preference': preference ??
          saved(
              (input['baseRevision'] as int) +
                  (status == 'already_requested_state' ? 0 : 1),
              input['style'] as String),
    };
KnownDurableEvent event(int revision,
        {String style = 'discord',
        String? id,
        ChatReplyStyleIdentity identity = actor,
        Map<String, dynamic>? mutation}) =>
    KnownDurableEvent.fromJson({
      'eventId': id ?? 'event-$revision',
      'protocolVersion': 4,
      'tenantId': identity.tenantId.value,
      'streamId': 'user:${identity.userId.value}',
      'type': 'reply.style.updated',
      'occurredAt': '2026-09-06T12:00:00.000Z',
      'payload': {
        'actorUserId': identity.userId.value,
        'preference': saved(revision, style),
        'updatedAt': '2026-09-06T12:00:00.000Z',
        if (mutation != null) 'mutation': mutation,
      },
    },
        trustedIdentity: DurableEventTrustedIdentity(
            tenantId: identity.tenantId, userId: identity.userId));
Future<void> pump() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

typedef Handler = Future<HandrailChatHttpResponse> Function(
    HandrailChatHttpRequest);

class Http implements HandrailChatHttpTransport {
  bool? support = true;
  Object preference = absent;
  Handler? read, write;
  final requests = <HandrailChatHttpRequest>[];
  List<HandrailChatHttpRequest> get reads => requests
      .where((r) =>
          r.method == 'GET' && r.uri.path.endsWith('/preferences/reply-style'))
      .toList();
  List<Map<String, dynamic>> get writes => requests
      .where((r) => r.method == 'PATCH')
      .map((r) => jsonDecode(r.body!) as Map<String, dynamic>)
      .toList();
  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    if (request.uri.path.endsWith('/_meta')) return response(metadata(support));
    expect(request.uri.path, '/api/chat/preferences/reply-style');
    expect(request.uri.query, isEmpty);
    expect(request.headers['Authorization'], 'Bearer token');
    if (request.method == 'GET') {
      expect(request.body, isNull);
      return read == null ? response(preference) : await read!(request);
    }
    final input = jsonDecode(request.body!) as Map<String, dynamic>;
    expect(request.headers['Idempotency-Key'], input['idempotencyKey']);
    return write == null ? response(result(input)) : await write!(request);
  }
}

HandrailChatClient clientFor(
  Http http, {
  ChatReplyStyleConfiguration configuration =
      const ChatReplyStyleConfiguration(),
  ChatRealtimeSessionTransport? realtime,
  String Function()? key,
}) {
  var keys = 0;
  final client = HandrailChatClient(
    apiBaseUri: Uri.parse('https://chat.test/api/chat/'),
    tokenProvider: () async => 'token',
    transport: http,
    replyStyleConfiguration: configuration,
    replyStyleIdentity: actor,
    generateIdempotencyKey: key ?? () => 'style-${++keys}',
    realtimeSession: realtime,
  );
  addTearDown(client.dispose);
  return client;
}

void main() {
  test('capability is independent of identity and preference authorization',
      () async {
    final http = Http();
    final client = HandrailChatClient(
        apiBaseUri: Uri.parse('https://chat.test/api/chat'),
        tokenProvider: () async => 'token',
        transport: http);
    addTearDown(client.dispose);
    expect(
        client.replyStyles.state.capability, ChatReplyStyleCapability.unknown);
    await client.initialize();
    expect(client.replyStyles.state.capability,
        ChatReplyStyleCapability.available);
    expect(client.replyStyles.state.isAvailable, isFalse);
    expect(http.reads, isEmpty);
    await client.replyStyles.activateIdentity(actor);
    http.write = (_) async => response({
          'error': {'code': 'forbidden', 'message': 'denied'}
        }, 403);
    await client.replyStyles.select(ReplyStyle.discord);
    expect(client.replyStyles.state.capability,
        ChatReplyStyleCapability.available);
    expect(client.replyStyles.state.error, ChatReplyStyleError.save);
    expect(client.replyStyles.state.confirmed!.revision, 0);
  });

  test(
      'failed refresh keeps confirmed style but requires authority before editing',
      () async {
    final http = Http()..preference = saved(2);
    final client = clientFor(http);
    await client.initialize();
    http.read = (_) => Future.error(StateError('offline'));
    await client.replyStyles.refresh();
    expect(client.replyStyles.state.effectiveStyle, ReplyStyle.discord);
    expect(client.replyStyles.state.canEdit, isFalse);
    expect(client.replyStyles.state.editingUnavailableReason, contains('Load'));
    client.reduceDurableEvent(event(1));
    expect(client.replyStyles.state.canEdit, isFalse);
    await client.replyStyles.select(ReplyStyle.current);
    expect(http.writes, isEmpty);
    http.read = null;
    await client.replyStyles.refresh();
    expect(client.replyStyles.state.canEdit, isTrue);
  });

  test(
      'replaced loads cannot publish and new clients reload without device cache',
      () async {
    final http = Http();
    final client = clientFor(http);
    await client.initialize();
    final pending = Completer<HandrailChatHttpResponse>();
    http.read = (_) => pending.future;
    final first = client.replyStyles.refresh();
    await pump();
    http.read = null;
    http.preference = saved(4);
    await client.replyStyles.refresh();
    pending.complete(response(saved(8, 'current')));
    await first;
    expect(client.replyStyles.state.confirmed!.toJson(), saved(4));
    await client.dispose();
    final restarted = clientFor(http);
    expect(restarted.replyStyles.state.confirmed, isNull);
    await restarted.initialize();
    expect(restarted.replyStyles.state.confirmed!.toJson(), saved(4));
  });

  final sources = <Object?>[
    null,
    ReplyStyle.current,
    ReplyStyle.discord,
    'future'
  ];
  for (final override in sources) {
    for (final savedStyle in <String?>[
      null,
      'current',
      'discord',
      'future',
      ''
    ]) {
      for (final defaultStyle in sources) {
        test(
            'precedence override=$override saved=$savedStyle default=$defaultStyle',
            () async {
          final http = Http()
            ..preference = savedStyle == null ? absent : saved(3, savedStyle);
          final client = clientFor(http,
              configuration: ChatReplyStyleConfiguration(
                  override: override, defaultStyle: defaultStyle));
          await client.initialize();
          final state = client.replyStyles.state;
          final value =
              override ?? savedStyle ?? defaultStyle ?? ReplyStyle.current;
          final raw = value is ReplyStyle ? value.wireValue : value;
          expect(state.effectiveStyle,
              raw == 'discord' ? ReplyStyle.discord : ReplyStyle.current);
          expect(state.unsupportedValue, raw != 'discord' && raw != 'current');
          expect(
              state.origin,
              override != null
                  ? ChatReplyStyleOrigin.hostOverride
                  : savedStyle != null
                      ? ChatReplyStyleOrigin.saved
                      : defaultStyle != null
                          ? ChatReplyStyleOrigin.hostDefault
                          : ChatReplyStyleOrigin.fallback);
          expect(state.confirmed!.toJson(), http.preference);
          expect(state.canEdit, override == null);
          expect(http.writes, isEmpty);
        });
      }
    }
  }

  test(
      'unresolved loading/read failure and malformed data never become absence',
      () async {
    final http = Http();
    final pending = Completer<HandrailChatHttpResponse>();
    http.read = (_) => pending.future;
    final client = clientFor(http,
        configuration: const ChatReplyStyleConfiguration(
            defaultStyle: ReplyStyle.discord));
    final init = client.initialize();
    await pump();
    expect(client.replyStyles.state.isLoading, isTrue);
    expect(client.replyStyles.state.confirmed, isNull);
    expect(client.replyStyles.state.canEdit, isFalse);
    expect(client.replyStyles.state.effectiveStyle, ReplyStyle.discord);
    await client.replyStyles.select(ReplyStyle.current);
    expect(http.writes, isEmpty);
    pending.completeError(StateError('offline'));
    await init;
    expect(client.replyStyles.state.error, ChatReplyStyleError.read);
    expect(client.replyStyles.state.confirmed, isNull);
    http.read =
        (_) async => response({'state': 'saved', 'revision': 1, 'style': 7});
    await client.replyStyles.refresh();
    expect(client.replyStyles.state.confirmed, isNull);
    http.read = null;
    await client.replyStyles.refresh();
    expect(
        client.replyStyles.state.confirmed, isA<AbsentReplyStylePreference>());
    expect(client.replyStyles.state.canEdit, isTrue);
  });

  for (final support in [null, false]) {
    test(
        'capability $support disables persistence without changing host policy',
        () async {
      final http = Http()..support = support;
      final client = clientFor(http,
          configuration: const ChatReplyStyleConfiguration(
              defaultStyle: ReplyStyle.discord));
      await client.initialize();
      expect(client.replyStyles.state.isAvailable, isFalse);
      expect(
          client.replyStyles.state.unavailableReason, contains('unavailable'));
      expect(client.replyStyles.state.confirmed, isNull);
      expect(client.replyStyles.state.effectiveStyle, ReplyStyle.discord);
      await client.replyStyles.select(ReplyStyle.current);
      expect(http.reads, isEmpty);
      expect(http.writes, isEmpty);
    });
  }

  test('save retains confirmed style; override does not overwrite saved state',
      () async {
    final http = Http();
    final pending = Completer<HandrailChatHttpResponse>();
    http.write = (_) => pending.future;
    final client = clientFor(http);
    await client.initialize();
    final save = client.replyStyles.select(ReplyStyle.discord);
    await pump();
    expect(client.replyStyles.state.isSaving, isTrue);
    expect(client.replyStyles.state.requestedStyle, ReplyStyle.discord);
    expect(client.replyStyles.state.effectiveStyle, ReplyStyle.current);
    pending.complete(response(result(http.writes.single)));
    await save;
    expect(client.replyStyles.state.effectiveStyle, ReplyStyle.discord);
    expect(client.replyStyles.state.requestedStyle, isNull);
    client.replyStyles.configure(
        const ChatReplyStyleConfiguration(override: ReplyStyle.current));
    await client.replyStyles.select(ReplyStyle.current);
    expect(http.writes, hasLength(1));
    expect(client.replyStyles.state.confirmed!.toJson(), saved(1));
    expect(client.replyStyles.state.editingUnavailableReason,
        contains('enforced'));
    expect(client.replyStyles.state.effectiveStyle, ReplyStyle.current);
    client.replyStyles.configure(const ChatReplyStyleConfiguration());
    expect(client.replyStyles.state.effectiveStyle, ReplyStyle.discord);
  });

  test(
      'failure reconciles before exact explicit replay, without automatic writes',
      () async {
    final http = Http()
      ..write = (_) => Future.error(StateError('lost response'));
    final client = clientFor(http);
    await client.initialize();
    await client.replyStyles.select(ReplyStyle.discord);
    expect(http.writes, hasLength(1));
    final input = http.writes.single;
    expect(client.replyStyles.state.error, ChatReplyStyleError.save);
    expect(client.replyStyles.state.requestedStyle, ReplyStyle.discord);
    expect(client.replyStyles.state.effectiveStyle, ReplyStyle.current);
    http.preference = saved(2, 'current');
    http.write = (_) async => response(result(input, status: 'replayed'));
    await client.replyStyles.retry();
    expect(http.writes, [input, input]);
    expect(http.requests.map((r) => r.method),
        ['GET', 'GET', 'PATCH', 'GET', 'PATCH']);
    expect(client.replyStyles.state.confirmed!.toJson(), saved(2, 'current'));
    expect(client.replyStyles.state.requestedStyle, isNull);
  });

  test('conflict retains request; explicit retry rebases with a new key',
      () async {
    final http = Http();
    http.write = (r) async => response(
        result(jsonDecode(r.body!),
            status: 'preference_revision_conflict',
            preference: saved(4, 'future')),
        409);
    final client = clientFor(http);
    await client.initialize();
    await client.replyStyles.select(ReplyStyle.discord);
    expect(client.replyStyles.state.error, ChatReplyStyleError.conflict);
    expect(client.replyStyles.state.confirmed!.toJson(), saved(4, 'future'));
    expect(client.replyStyles.state.requestedStyle, ReplyStyle.discord);
    http.preference = saved(5, 'current');
    http.write = null;
    await client.replyStyles.retry();
    expect(http.writes.last['baseRevision'], 5);
    expect(http.writes.last['idempotencyKey'],
        isNot(http.writes.first['idempotencyKey']));
    expect(client.replyStyles.state.confirmed!.toJson(), saved(6));
  });

  for (final status in ['applied', 'replayed', 'already_requested_state']) {
    test('canonical success $status', () async {
      final http = Http()..preference = saved(2);
      http.write =
          (r) async => response(result(jsonDecode(r.body!), status: status));
      final client = clientFor(http);
      await client.initialize();
      await client.replyStyles.select(ReplyStyle.discord);
      expect(client.replyStyles.state.error, isNull);
      expect(client.replyStyles.state.confirmed!.revision,
          status == 'already_requested_state' ? 2 : 3);
    });
  }

  for (final field in [
    'idempotencyKey',
    'baseRevision',
    'requestedStyle',
    'operation',
    'httpStatus'
  ]) {
    test('rejects mismatched response $field', () async {
      final http = Http();
      http.write = (r) async {
        final data = result(jsonDecode(r.body!));
        if (field != 'httpStatus')
          data[field] = field == 'baseRevision' ? 8 : 'other';
        return response(data, field == 'httpStatus' ? 409 : 200);
      };
      final client = clientFor(http);
      await client.initialize();
      await client.replyStyles.select(ReplyStyle.discord);
      expect(client.replyStyles.state.error, ChatReplyStyleError.save);
      expect(client.replyStyles.state.confirmed!.revision, 0);
      expect(client.replyStyles.state.requestedStyle, ReplyStyle.discord);
    });
  }

  test('event ordering, duplicates, private actor and tenant isolation',
      () async {
    final client = clientFor(Http());
    await client.initialize();
    expect(client.reduceDurableEvent(event(3)).status,
        DurableEventReductionStatus.applied);
    expect(client.reduceDurableEvent(event(3)).status,
        DurableEventReductionStatus.duplicate);
    expect(client.reduceDurableEvent(event(2, style: 'current')).status,
        DurableEventReductionStatus.stale);
    for (final other in [
      const ChatReplyStyleIdentity(
          tenantId: TenantId('tenant-2'), userId: UserId('user-1')),
      const ChatReplyStyleIdentity(
          tenantId: TenantId('tenant-1'), userId: UserId('user-2')),
    ]) {
      expect(() => client.reduceDurableEvent(event(9, identity: other)),
          throwsA(isA<DurableEventReductionError>()));
    }
    expect(client.replyStyles.state.confirmed!.toJson(), saved(3));
    client.reduceDurableEvent(event(4, style: 'future'));
    expect(client.replyStyles.state.unsupportedValue, isTrue);
    expect(client.replyStyles.state.confirmed!.toJson(), saved(4, 'future'));
  });

  test('older loads and responses cannot regress a newer private event',
      () async {
    final http = Http();
    final client = clientFor(http);
    await client.initialize();
    final read = Completer<HandrailChatHttpResponse>();
    http.read = (_) => read.future;
    final loading = client.replyStyles.refresh();
    client.reduceDurableEvent(event(4));
    read.complete(response(absent));
    await loading;
    final write = Completer<HandrailChatHttpResponse>();
    http.write = (_) => write.future;
    final saving = client.replyStyles.select(ReplyStyle.current);
    await pump();
    client.reduceDurableEvent(event(6));
    expect(client.replyStyles.state.requestedStyle, ReplyStyle.current);
    write.complete(response(result(http.writes.single)));
    await saving;
    expect(client.replyStyles.state.confirmed!.toJson(), saved(6));
    expect(client.replyStyles.state.requestedStyle, isNull);
  });

  test('only an exact mutation event acknowledges; event wins over failed HTTP',
      () async {
    final http = Http();
    final pending = Completer<HandrailChatHttpResponse>();
    http.write = (_) => pending.future;
    final client = clientFor(http);
    await client.initialize();
    final saving = client.replyStyles.select(ReplyStyle.discord);
    await pump();
    final input = http.writes.single;
    client.reduceDurableEvent(event(1,
        mutation: {...input, 'idempotencyKey': 'unrelated'}, id: 'unrelated'));
    expect(client.replyStyles.state.isSaving, isTrue);
    expect(client.replyStyles.state.requestedStyle, ReplyStyle.discord);
    client.reduceDurableEvent(event(2, style: 'current'));
    client.reduceDurableEvent(event(1, mutation: input, id: 'exact'));
    expect(client.replyStyles.state.requestedStyle, isNull);
    pending.completeError(StateError('response lost'));
    await saving;
    expect(client.replyStyles.state.error, isNull);
    expect(client.replyStyles.state.confirmed!.toJson(), saved(2, 'current'));
  });

  test('read failure during retry preserves input and does not write',
      () async {
    final http = Http()..write = (_) => Future.error(StateError('offline'));
    final client = clientFor(http);
    await client.initialize();
    await client.replyStyles.select(ReplyStyle.discord);
    http.read = (_) => Future.error(StateError('offline'));
    await client.replyStyles.retry();
    expect(http.writes, hasLength(1));
    expect(client.replyStyles.state.requestedStyle, ReplyStyle.discord);
    http.read = null;
    http.write = null;
    await client.replyStyles.retry();
    expect(http.writes.last, http.writes.first);
  });

  test('changed selection and rebased input never reuse an issued key',
      () async {
    final http = Http()..write = (_) => Future.error(StateError('offline'));
    final client = clientFor(http);
    await client.initialize();
    await client.replyStyles.select(ReplyStyle.discord);
    http.write = null;
    await client.replyStyles.select(ReplyStyle.current);
    expect(http.writes.last['style'], 'current');
    expect(http.writes.last['idempotencyKey'],
        isNot(http.writes.first['idempotencyKey']));
    final collisionHttp = Http();
    final collision = clientFor(collisionHttp, key: () => 'constant');
    await collision.initialize();
    await collision.replyStyles.select(ReplyStyle.discord);
    await collision.replyStyles.select(ReplyStyle.current);
    expect(collision.replyStyles.state.error, ChatReplyStyleError.validation);
    expect(collisionHttp.writes, hasLength(1));
  });

  for (final other in [
    const ChatReplyStyleIdentity(
        tenantId: TenantId('tenant-2'), userId: UserId('user-1')),
    const ChatReplyStyleIdentity(
        tenantId: TenantId('tenant-1'), userId: UserId('user-2')),
  ]) {
    for (final operation in ['read', 'save', 'retry']) {
      test('$operation in flight is invalidated across $other', () async {
        final http = Http();
        final client = clientFor(http);
        await client.initialize();
        final pending = Completer<HandrailChatHttpResponse>();
        late Future<ChatReplyStyleState> work;
        if (operation == 'save') {
          http.write = (_) => pending.future;
          work = client.replyStyles.select(ReplyStyle.discord);
        } else {
          if (operation == 'retry') {
            http.write = (_) => Future.error(StateError('lost'));
            await client.replyStyles.select(ReplyStyle.discord);
          }
          http.read = (_) => pending.future;
          work = operation == 'retry'
              ? client.replyStyles.retry()
              : client.replyStyles.refresh();
        }
        await pump();
        final oldRequest = http.requests.last;
        http.read = null;
        http.preference = saved(2, 'current');
        await client.replyStyles.activateIdentity(other);
        expect(
            (oldRequest.cancellationSignal! as ChatCommandCancellationSignal)
                .isCancelled,
            isTrue);
        pending.complete(response(
            operation == 'save' ? result(http.writes.first) : saved(10)));
        await work;
        await client.replyStyles.retry();
        expect(client.replyStyles.state.identity!.tenantId, other.tenantId);
        expect(client.replyStyles.state.identity!.userId, other.userId);
        expect(
            client.replyStyles.state.confirmed!.toJson(), saved(2, 'current'));
        expect(client.replyStyles.state.requestedStyle, isNull);
        expect(http.writes.length, operation == 'read' ? 0 : 1);
      });
    }
  }

  test(
      'logout detaches state; disposed streams close and late reads cannot publish',
      () async {
    final http = Http();
    final client = clientFor(http);
    await client.initialize();
    final states = <ChatReplyStyleState>[];
    var closed = false;
    final subscription = client.replyStyles.states
        .listen(states.add, onDone: () => closed = true);
    await pump();
    expect(states.first.confirmed, isA<AbsentReplyStylePreference>());
    await client.replyStyles.activateIdentity(null);
    expect(client.replyStyles.state.confirmed, isNull);
    expect(client.replyStyles.state.canEdit, isFalse);
    await client.replyStyles.activateIdentity(actor);
    final pending = Completer<HandrailChatHttpResponse>();
    http.read = (_) => pending.future;
    final loading = client.replyStyles.refresh();
    await pump();
    await client.dispose();
    pending.complete(response(saved(10)));
    await loading;
    await pump();
    expect(closed, isTrue);
    expect(states.last.isDisposed, isTrue);
    expect(client.replyStyles.state.confirmed, isNull);
    final count = http.requests.length;
    await client.replyStyles.refresh();
    await client.replyStyles.retry();
    await client.replyStyles.select(ReplyStyle.discord);
    expect(http.requests.length, count);
    await subscription.cancel();
  });
}
