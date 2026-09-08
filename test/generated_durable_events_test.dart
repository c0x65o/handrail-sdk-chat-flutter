import 'dart:convert';
import 'dart:io';

import 'package:handrail_chat/src/generated/durable_events.dart';
import 'package:handrail_chat/src/generated/identifiers.dart';
import 'package:handrail_chat/src/generated/realtime_session.dart';
import 'package:test/test.dart';

void main() {
  late Map<String, Object?> fixtures;
  late Map<String, Object?> replies;
  late DurableEventTrustedIdentity trustedIdentity;

  setUpAll(() async {
    fixtures = _map(jsonDecode(await File(
      'conformance-tests/durable-events/fixtures.json',
    ).readAsString()));
    replies = _map(jsonDecode(await File(
      'conformance-tests/durable-events/reply-references.json',
    ).readAsString()));
    final identity = _map(fixtures['trustedIdentity']);
    trustedIdentity = DurableEventTrustedIdentity(
      tenantId: TenantId(identity['tenantId']! as String),
      userId: UserId(identity['userId']! as String),
    );
  });

  Map<String, Object?> threadEvent() =>
      _map(_roundTrip((fixtures['valid']! as List)
          .firstWhere((value) => _map(value)['type'] == 'thread.created')));

  final lifecycle = _map(jsonDecode(
      File('conformance-tests/thread-lifecycle.json')
          .readAsStringSync()));
  Map<String, Object?> lifecycleEvent(String kind) =>
      _map(_roundTrip((fixtures['valid']! as List).firstWhere(
          (value) => _map(value)['type'] == 'thread.lifecycle.$kind')));
  void rejectLifecycle(Map<String, Object?> wire,
      [String code = 'incoherent_payload']) {
    expect(
        () =>
            KnownDurableEvent.fromJson(wire, trustedIdentity: trustedIdentity),
        throwsA(isA<DurableEventFormatException>()
            .having((error) => error.code.wireValue, 'code', code)));
  }

  for (final kind in ['updated', 'changed']) {
    test('thread.lifecycle.$kind round trips and strictly binds its own stream',
        () {
      for (final state in lifecycle['valid']! as List) {
        final wire = lifecycleEvent(kind);
        final payload = _map(wire['payload']);
        if (kind == 'updated') {
          payload['threadLifecycle'] = state;
        } else {
          payload['revision'] = _map(state)['revision'];
        }
        final parsed =
            KnownDurableEvent.fromJson(wire, trustedIdentity: trustedIdentity);
        expect(parsed.toJson(), wire);
        expect(
            KnownDurableEvent.fromJson(_roundTrip(parsed.toJson()),
                    trustedIdentity: trustedIdentity)
                .toJson(),
            wire);
        expect(() => parsed.payload.data['threadId'] = 'changed',
            throwsUnsupportedError);
        final opposite = kind == 'updated'
            ? payload['parentConversationId']
            : payload['threadId'];
        for (final stream in [
          opposite,
          'unrelated',
          'user:user-1',
          'user:user-2'
        ]) {
          rejectLifecycle(
              {...wire, 'streamId': stream},
              (stream! as String).startsWith('user:')
                  ? 'private_stream_mismatch'
                  : 'incoherent_payload');
        }
        rejectLifecycle(
            {...wire, 'tenantId': 'other-tenant'}, 'tenant_mismatch');
      }
    });

    test(
        'thread.lifecycle.$kind rejects malformed metadata, identities and private extras',
        () {
      final field = kind == 'updated' ? 'threadLifecycle' : 'revision';
      final invalid =
          lifecycle[kind == 'updated' ? 'invalid' : 'invalidRevisions']!
              as List;
      for (final value in invalid) {
        final wire = lifecycleEvent(kind);
        _map(wire['payload'])[field] = value;
        rejectLifecycle(wire);
      }
      for (final field in [
        'threadId',
        'parentConversationId',
        kind == 'updated' ? 'threadLifecycle' : 'revision'
      ]) {
        final wire = lifecycleEvent(kind);
        _map(wire['payload']).remove(field);
        rejectLifecycle(wire);
      }
      for (final field in ['threadId', 'parentConversationId']) {
        for (final value in [null, '', ' spaced ', 7]) {
          final wire = lifecycleEvent(kind);
          _map(wire['payload'])[field] = value;
          rejectLifecycle(wire);
        }
      }
      final same = lifecycleEvent(kind);
      _map(same['payload']).addAll({
        'threadId': same['streamId'],
        'parentConversationId': same['streamId']
      });
      rejectLifecycle(same);
      for (final entry in _map(lifecycle['privateExtras']).entries) {
        final wire = lifecycleEvent(kind);
        _map(wire['payload'])[entry.key] = entry.value;
        rejectLifecycle(wire);
      }
      if (kind == 'changed') {
        final wire = lifecycleEvent(kind);
        _map(wire['payload'])['threadLifecycle'] =
            (lifecycle['valid']! as List).first;
        rejectLifecycle(wire);
      }
    });
  }

  for (final type in ['conversation.created', 'thread.created']) {
    Map<String, Object?> conversationEvent() {
      final wire = threadEvent();
      wire['type'] = type;
      if (type == 'conversation.created')
        _map(wire['payload']).remove('rootThreadSummary');
      return wire;
    }

    test('$type lifecycle preserves names, archive and legacy absence', () {
      for (final state in [null, ...lifecycle['valid']! as List]) {
        for (final archived in [false, true]) {
          final wire = conversationEvent();
          _map(_map(wire['payload'])['conversation']).addAll({
            'name': 'Launch 🚀',
            if (state != null) 'threadLifecycle': state,
            if (archived) 'archivedAt': wire['occurredAt'],
            if (archived) 'archivedByUserId': 'archiver',
          });
          final parsed = KnownDurableEvent.fromJson(wire,
              trustedIdentity: trustedIdentity);
          expect(parsed.toJson(), wire);
          expect(
              KnownDurableEvent.fromJson(_roundTrip(parsed.toJson()),
                      trustedIdentity: trustedIdentity)
                  .toJson(),
              wire);
        }
      }
    });
    test('$type rejects malformed lifecycle and retains tenant checks', () {
      for (final state in lifecycle['invalid']! as List) {
        final wire = conversationEvent();
        _map(_map(wire['payload'])['conversation'])['threadLifecycle'] = state;
        rejectLifecycle(wire);
      }
      final wire = conversationEvent();
      _map(_map(wire['payload'])['conversation']).addAll({
        'threadLifecycle': (lifecycle['valid']! as List).first,
        'tenantId': 'other-tenant'
      });
      rejectLifecycle(wire, 'tenant_mismatch');
    });
  }
  test('conversation.created rejects lifecycle on every non-thread', () {
    for (final type in ['channel', 'direct', 'group_direct']) {
      final wire = _map(_roundTrip((fixtures['valid']! as List).firstWhere(
          (value) => _map(value)['type'] == 'conversation.created')));
      _map(_map(wire['payload'])['conversation']).addAll({
        'type': type,
        'visibility': 'private',
        'threadLifecycle': (lifecycle['valid']! as List).first
      });
      rejectLifecycle(wire);
    }
  });

  final names = _map(jsonDecode(
      File('conformance-tests/thread-names.json').readAsStringSync()));

  test('thread.created retains supplied names and legacy omission', () {
    for (final visibility in ['public', 'private']) {
      for (final name in [null, ...names['valid']! as List]) {
        final wire = threadEvent();
        final conversation = _map(_map(wire['payload'])['conversation']);
        conversation['visibility'] = visibility;
        if (name != null) conversation['name'] = name;
        final event =
            KnownDurableEvent.fromJson(wire, trustedIdentity: trustedIdentity);
        expect(event.toJson(), wire);
        final retained = _map(event.payload.data['conversation']);
        expect(retained.containsKey('name'), name != null);
        expect(retained['name'], name);
        expect(
            KnownDurableEvent.fromJson(_roundTrip(event.toJson()),
                    trustedIdentity: trustedIdentity)
                .toJson(),
            wire);
        expect(() => retained['name'] = 'changed', throwsUnsupportedError);
      }
    }
  });

  void rejectsThread(Map<String, Object?> wire) {
    expect(
        () =>
            KnownDurableEvent.fromJson(wire, trustedIdentity: trustedIdentity),
        throwsA(isA<DurableEventFormatException>()
            .having(
                (error) => error.code.wireValue, 'code', 'incoherent_payload')
            .having((error) => error.message, 'message',
                'The durable event payload is malformed or incoherent with its stream.')));
  }

  test('thread.created rejects invalid supplied names with stable errors', () {
    for (final name in names['invalid']! as List) {
      final wire = threadEvent();
      _map(_map(wire['payload'])['conversation'])['name'] = name;
      rejectsThread(wire);
    }
  });

  test(
      'named thread.created retains parent, root, visibility and routing invariants',
      () {
    final patches = <Map<String, Object?>>[
      for (final field in ['parentConversationId', 'rootMessageId'])
        for (final value in <Object?>[null, '', 7]) {field: value},
      {'visibility': 'invited'},
      {'visibility': null},
      {'id': 'other-thread'},
    ];
    for (final patch in patches) {
      final wire = threadEvent();
      _map(_map(wire['payload'])['conversation'])
          .addAll({'name': 'Launch 🚀', ...patch});
      rejectsThread(wire);
    }
    for (final field in ['parentConversationId', 'rootMessageId']) {
      final wire = threadEvent();
      _map(_map(wire['payload'])['conversation'])
        ..['name'] = 'Launch 🚀'
        ..remove(field);
      rejectsThread(wire);
    }
  });

  test('strictly round-trips one shared fixture for every registry entry', () {
    final valid = fixtures['valid']! as List<Object?>;
    expect(valid, hasLength(21));
    expect(
      valid.map((value) => _map(value)['type']).toSet(),
      chatDurableEventTypeValues.toSet(),
    );
    for (final value in valid) {
      final wire = _map(_roundTrip(value));
      final event = KnownDurableEvent.fromJson(
        wire,
        trustedIdentity: trustedIdentity,
      );
      expect(event.toJson(), wire, reason: event.type);
    }
  });

  test('rejects unknown, tenant, private stream/actor, and entity mismatches',
      () {
    final rejections = _map(fixtures['rejections']);
    for (final value in rejections.values) {
      final fixture = _map(value);
      expect(
        () => KnownDurableEvent.fromJson(
          _roundTrip(fixture['event']),
          trustedIdentity: trustedIdentity,
        ),
        throwsA(
          isA<DurableEventFormatException>().having(
            (error) => error.code.wireValue,
            'code',
            fixture['code'],
          ),
        ),
      );
    }
  });

  for (final type in [
    'message.created',
    'message.updated',
    'message.deleted'
  ]) {
    for (final destination in ['conversation-1', 'thread-1']) {
      Map<String, Object?> messageEvent() {
        final fixture = (fixtures['valid']! as List).firstWhere(
          (value) => _map(value)['type'] == type,
        );
        final wire = _map(_roundTrip(fixture));
        wire['streamId'] = destination;
        _map(_map(wire['payload'])['message'])['conversationId'] = destination;
        return wire;
      }

      test('$type round-trips legacy and reply messages in $destination', () {
        final references = <Object?>[
          null,
          for (final id in replies['validIds']! as List)
            for (final notify in [true, false])
              {'messageId': id, 'notifyAuthor': notify},
        ];
        for (final reply in references) {
          final wire = messageEvent();
          final message = _map(_map(wire['payload'])['message']);
          if (reply != null) message['replyTo'] = _roundTrip(reply);
          final event = KnownDurableEvent.fromJson(wire,
              trustedIdentity: trustedIdentity);
          expect(event.toJson(), wire);
          expect(event.type, type);
          expect(event.streamId, destination);
          expect(
              KnownDurableEvent.fromJson(_roundTrip(event.toJson()),
                      trustedIdentity: trustedIdentity)
                  .toJson(),
              wire);
          final parsedMessage = _map(event.payload.data['message']);
          if (reply != null) {
            expect(
                () => _map(parsedMessage['replyTo'])['messageId'] =
                    'changed-source',
                throwsUnsupportedError);
            _map(message['replyTo'])['messageId'] = 'changed-source';
            final copy = _map(_map(event.toJson()['payload'])['message']);
            _map(copy['replyTo'])['notifyAuthor'] = 'changed';
            expect(parsedMessage['replyTo'], reply);
          } else {
            expect(parsedMessage.containsKey('replyTo'), isFalse);
          }
        }
      });

      test('$type rejects malformed reply references in $destination', () {
        for (final reply in replies['invalidReferences']! as List) {
          final wire = messageEvent();
          _map(_map(wire['payload'])['message'])['replyTo'] = reply;
          _expectRejection(wire, trustedIdentity,
              DurableEventParseErrorCode.incoherentPayload);
        }
      });

      test(
          '$type retains tenant and stream checks with replies in $destination',
          () {
        for (final notify in [true, false]) {
          for (final entry in <(String, Object?, DurableEventParseErrorCode)>[
            (
              'tenantId',
              'other-tenant',
              DurableEventParseErrorCode.tenantMismatch
            ),
            (
              'message.tenantId',
              'other-tenant',
              DurableEventParseErrorCode.tenantMismatch
            ),
            (
              'streamId',
              'source-message',
              DurableEventParseErrorCode.incoherentPayload
            ),
            (
              'message.conversationId',
              'other-conversation',
              DurableEventParseErrorCode.incoherentPayload
            ),
            (
              'streamId',
              'user:user-1',
              DurableEventParseErrorCode.privateStreamMismatch
            ),
            (
              'streamId',
              'user:user-2',
              DurableEventParseErrorCode.privateStreamMismatch
            ),
          ]) {
            final wire = messageEvent();
            final message = _map(_map(wire['payload'])['message']);
            message['replyTo'] = {
              'messageId': 'source-message',
              'notifyAuthor': notify
            };
            if (entry.$1.startsWith('message.')) {
              message[entry.$1.substring('message.'.length)] = entry.$2;
            } else {
              wire[entry.$1] = entry.$2;
            }
            _expectRejection(wire, trustedIdentity, entry.$3);
          }
        }
      });
    }
  }

  final replyStyles = _map(jsonDecode(
      File('conformance-tests/durable-events/reply-style-updated.json')
          .readAsStringSync()));
  Map<String, Object?> replyStyleEvent() => _map(_roundTrip((fixtures['valid']!
          as List)
      .firstWhere((value) => _map(value)['type'] == 'reply.style.updated')));
  for (final value in replyStyles['valid']! as List) {
    final fixture = _map(value);
    test('reply.style.updated round-trips ${fixture['name']}', () {
      final wire = replyStyleEvent();
      wire['payload'] = _roundTrip(fixture['payload']);
      final parsed =
          KnownDurableEvent.fromJson(wire, trustedIdentity: trustedIdentity);
      expect(parsed, isA<ReplyStyleUpdatedDurableEvent>());
      expect(parsed.payload, isA<ReplyStyleUpdatedPayload>());
      expect(parsed.toJson(), wire);
      expect(
          KnownDurableEvent.fromJson(_roundTrip(parsed.toJson()),
                  trustedIdentity: trustedIdentity)
              .toJson(),
          wire);
      expect(() => _map(parsed.payload.data['preference'])['style'] = 'changed',
          throwsUnsupportedError);
      if (parsed.payload.data.containsKey('mutation')) {
        expect(() => _map(parsed.payload.data['mutation'])['style'] = 'changed',
            throwsUnsupportedError);
      }
      _map(_map(wire['payload'])['preference'])['style'] =
          'changed-after-parse';
      expect(parsed.payload.toJson(), fixture['payload']);
    });
  }
  final styleRejections = replyStyles['rejections']! as List;
  for (var index = 0; index < styleRejections.length; index++) {
    final fixture = _map(styleRejections[index]);
    test('reply.style.updated rejects $index: ${fixture['path']}', () {
      final wire = replyStyleEvent();
      final parts = (fixture['path']! as String).split('.');
      final key = parts.removeLast();
      var target = wire;
      for (final part in parts) {
        target = _map(target[part]);
      }
      if (fixture['remove'] == true) {
        target.remove(key);
      } else {
        target[key] = fixture['value'];
      }
      _expectRejection(
          wire,
          trustedIdentity,
          DurableEventParseErrorCode.values
              .firstWhere((code) => code.wireValue == fixture['code']));
    });
  }

  test('generic ChatEvent still represents an unknown future event', () {
    final future =
        _map(_map(_map(fixtures['rejections'])['unknownType'])['event']);
    final generic = ChatEvent.fromJson(
      _roundTrip(future),
      trustedTenantId: trustedIdentity.tenantId,
    );
    expect(generic.type, 'future.event');
    expect(generic.payload, isEmpty);
    expect(
      () => KnownDurableEvent.fromJson(
        future,
        trustedIdentity: trustedIdentity,
      ),
      throwsA(
        isA<DurableEventFormatException>().having(
          (error) => error.code,
          'code',
          DurableEventParseErrorCode.unknownEventType,
        ),
      ),
    );
  });
}

void _expectRejection(Map<String, Object?> wire,
    DurableEventTrustedIdentity identity, DurableEventParseErrorCode code) {
  const messages = {
    DurableEventParseErrorCode.incoherentPayload:
        'The durable event payload is malformed or incoherent with its stream.',
    DurableEventParseErrorCode.tenantMismatch:
        'The durable event does not belong to the trusted tenant.',
    DurableEventParseErrorCode.privateStreamMismatch:
        'The durable event does not belong to the trusted private user stream.',
  };
  expect(
    () => KnownDurableEvent.fromJson(wire, trustedIdentity: identity),
    throwsA(isA<DurableEventFormatException>()
        .having((error) => error.code, 'code', code)
        .having(
            (error) => error.message, 'payload-safe message', messages[code])),
  );
}

Object? _roundTrip(Object? value) => jsonDecode(jsonEncode(value));
Map<String, Object?> _map(Object? value) =>
    (value! as Map).cast<String, Object?>();
