import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:handrail_chat/core.dart';
import 'package:handrail_chat/testing.dart'
    show
        FakeChatRealtimeNetwork,
        FakeChatRealtimeSocket,
        FakeChatRealtimeSocketFactory,
        InMemoryApplicationChatStorage;
import 'package:test/test.dart';

const _conversationId = ConversationId('conversation-1');
const _messageId = MessageId('message-1');
const _due1 = IsoTimestamp('2033-02-01T01:00:00.000Z');
const _due2 = IsoTimestamp('2033-02-02T01:00:00.000Z');
final _identity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-1'),
  userId: const UserId('user-1'),
  deviceId: const DeviceId('device-1'),
);
final _otherIdentity = ApplicationChatStorageIdentity(
  tenantId: const TenantId('tenant-1'),
  userId: const UserId('user-2'),
  deviceId: const DeviceId('device-2'),
);

void main() {
  test('atomic contention exhaustion never publishes or dispatches a proposal',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicReminderStorage(backing);
    final diagnostics = <ChatClientDiagnostic>[];
    final fixture = _Fixture(
      storage: storage,
      transport: _ReminderTransport(),
      keys: Queue.of(['uncommitted-key']),
      onStorageDiagnostic: diagnostics.add,
    );
    addTearDown(fixture.dispose);
    await fixture.activate();
    await fixture.initialize();
    storage.rejectExchanges = true;
    expect(
      await fixture.client.setMessageReminder(
        conversationId: _conversationId,
        messageId: _messageId,
        dueAt: _due1,
      ),
      isA<ChatCommandValidationFailure<MessageReminderResult>>(),
    );
    expect(storage.conflicts, maxApplicationChatStorageMutationAttempts);
    expect(fixture.client.queuedMessageReminders, isEmpty);
    expect(fixture.store.messageReminder(_messageId).reminder, isNull);
    expect(fixture.transport.reminderGets, isEmpty);
    expect(fixture.transport.puts, isEmpty);
    expect(await _read(backing, _identity), isNull);
    expect(diagnostics.single.code,
        ChatClientDiagnosticCode.messageReminderIntentsWriteFailed);
    expect(diagnostics.single.toString(), isNot(contains(_due1.value)));
    expect(storage.proposals.whereType<String>().toSet(), hasLength(1),
        reason: 'request identity and enqueue time are stable across retries');
  });

  test('atomic enqueue retries a stale encoded read and keeps both messages',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicReminderStorage(backing);
    final first = _Fixture(
      storage: storage,
      transport: _ReminderTransport(),
      keys: Queue.of(['commits-last']),
    );
    final second = _Fixture(
      storage: _AtomicReminderStorage(backing),
      transport: _ReminderTransport(),
      keys: Queue.of(['commits-first']),
    );
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.activate();
    await second.activate();
    storage.afterRead = (encoded) async {
      expect(encoded, isNull);
      unawaited(second.client.setMessageReminder(
        conversationId: _conversationId,
        messageId: const MessageId('message-2'),
        dueAt: _due2,
      ));
      await _eventually(() => second.client.queuedMessageReminders.length == 1);
      expect(first.client.queuedMessageReminders, isEmpty);
      expect(first.transport.requests, isEmpty);
    };
    unawaited(first.client.setMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due1,
    ));
    await _eventually(() => first.client.queuedMessageReminders.length == 2);
    final record = (await _read(backing, _identity))!;
    expect(record.intents.map((intent) => intent.request.idempotencyKey),
        ['commits-first', 'commits-last']);
    expect(record.intents.map((intent) => intent.enqueueOrder), [1, 2]);
    expect(
        first.client.queuedMessageReminders
            .map((intent) => intent.request.toJson()),
        record.intents.map((intent) => intent.request.toJson()));
    expect(storage.conflicts, 1);
    expect(first.transport.requests, isEmpty);
    expect(second.transport.requests, isEmpty);
  });

  for (final lastOperation in ['set', 'reschedule', 'cancel']) {
    test(
        'atomic competing desired states converge when $lastOperation commits last',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final unrelated = _stored(
          _request('unrelated', 0,
              dueAt: _due1, messageId: const MessageId('message-2')),
          7);
      await backing.replace(_record([unrelated]));
      final storage = _AtomicReminderStorage(backing);
      final last = _Fixture(
        storage: storage,
        transport: _ReminderTransport(),
        keys: Queue.of(['commits-last']),
      );
      final first = _Fixture(
        storage: _AtomicReminderStorage(backing),
        transport: _ReminderTransport(),
        keys: Queue.of(['commits-first']),
      );
      addTearDown(last.dispose);
      addTearDown(first.dispose);
      await last.activate();
      await first.activate();
      late ApplicationChatQueuedMessageReminderIntent firstCommitted;
      storage.beforeExchange = (expected, replacement) async {
        expect(expected, isNotNull);
        expect(replacement, isNotNull);
        unawaited(lastOperation == 'set'
            ? first.client.cancelMessageReminder(
                conversationId: _conversationId, messageId: _messageId)
            : first.client.setMessageReminder(
                conversationId: _conversationId,
                messageId: _messageId,
                dueAt: _due1));
        await _eventually(
            () => first.client.queuedMessageReminders.length == 2);
        firstCommitted = (await _read(backing, _identity))!.intents.last;
      };
      unawaited(switch (lastOperation) {
        'cancel' => last.client.cancelMessageReminder(
            conversationId: _conversationId, messageId: _messageId),
        'reschedule' => last.client.rescheduleMessageReminder(
            conversationId: _conversationId,
            messageId: _messageId,
            dueAt: _due2),
        _ => last.client.setMessageReminder(
            conversationId: _conversationId,
            messageId: _messageId,
            dueAt: _due2),
      });
      await _eventually(() => last.client.queuedMessageReminders.length == 2);
      final committed = (await _read(backing, _identity))!;
      expect(committed.intents.first.toJson(), unrelated.toJson());
      expect(
          committed.intents.last.request.toJson(),
          _request('commits-last', 0,
                  dueAt: lastOperation == 'cancel' ? null : _due2)
              .toJson());
      expect(committed.intents.last.enqueueOrder, firstCommitted.enqueueOrder);
      expect(committed.intents.last.enqueuedAt, firstCommitted.enqueuedAt);
      expect(storage.conflicts, 1);
      expect(last.transport.requests, isEmpty);
    });
  }

  test(
      'failed CAS leaves the previous caller and projection active until commit',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicReminderStorage(backing);
    final response = Completer<HandrailChatHttpResponse>();
    final fixture = _Fixture(
      storage: storage,
      transport: _ReminderTransport(put: (_) => response.future),
      keys: Queue.of(['previous', 'replacement']),
    );
    addTearDown(fixture.dispose);
    await fixture.activate();
    await fixture.initialize();
    var previousCompleted = false;
    final previous = fixture.client
        .setMessageReminder(
          conversationId: _conversationId,
          messageId: _messageId,
          dueAt: _due1,
        )
        .whenComplete(() => previousCompleted = true);
    await _eventually(() => fixture.transport.puts.length == 1);
    final retryStarted = Completer<void>();
    final releaseRetry = Completer<void>();
    addTearDown(() {
      if (!releaseRetry.isCompleted) releaseRetry.complete();
      if (!response.isCompleted) {
        response.complete(_error(403, 'PERMISSION_DENIED'));
      }
    });
    storage.beforeExchange = (expected, replacement) async {
      final current = (await _read(backing, _identity))!;
      await backing.replace(_record([
        ...current.intents,
        _stored(
            _request('unrelated', 0,
                dueAt: _due1, messageId: const MessageId('message-2')),
            2),
      ]));
      storage.beforeExchange = (expected, replacement) async {
        retryStarted.complete();
        await releaseRetry.future;
      };
    };
    final replacement = fixture.client.rescheduleMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due2,
    );
    await retryStarted.future;
    expect(storage.conflicts, 1);
    expect(previousCompleted, isFalse);
    expect(fixture.client.queuedMessageReminders.single.request.idempotencyKey,
        'previous');
    expect(fixture.store.messageReminder(_messageId).dueAt, _due1);
    expect(fixture.transport.puts, hasLength(1));
    releaseRetry.complete();
    expect(await previous, isA<ChatCommandClosed<MessageReminderResult>>());
    await _eventually(() => fixture.client.queuedMessageReminders
        .any((intent) => intent.request.idempotencyKey == 'replacement'));
    expect(
        (await _read(backing, _identity))!
            .intents
            .map((intent) => intent.request.idempotencyKey),
        ['replacement', 'unrelated']);
    await fixture.client.dispose();
    expect(await replacement, isA<ChatCommandClosed<MessageReminderResult>>());
    response.complete(_error(403, 'PERMISSION_DENIED'));
  });

  test('atomic HTTP settlement publishes authority only after storage commits',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _AtomicReminderStorage(backing);
    final started = Completer<void>();
    final release = Completer<void>();
    final fixture = _Fixture(
      storage: storage,
      transport: _ReminderTransport(put: (request) async {
        storage.beforeExchange = (expected, replacement) async {
          expect(expected, isNotNull);
          expect(replacement, isNull);
          started.complete();
          await release.future;
        };
        return _success(_body(request));
      }),
      keys: Queue.of(['settles-after-commit']),
    );
    addTearDown(fixture.dispose);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    await fixture.activate();
    await fixture.initialize();
    var completed = false;
    final pending = fixture.client
        .setMessageReminder(
          conversationId: _conversationId,
          messageId: _messageId,
          dueAt: _due1,
        )
        .whenComplete(() => completed = true);
    await started.future;
    expect(completed, isFalse);
    expect(fixture.client.queuedMessageReminders, hasLength(1));
    expect(fixture.store.messageReminder(_messageId).authoritativeReminder,
        isNull);
    expect(fixture.store.messageReminder(_messageId).isPending, isTrue);
    expect((await _read(backing, _identity))!.intents, hasLength(1));
    release.complete();
    expect(await pending, isA<ChatCommandSuccess<MessageReminderResult>>());
    expect(fixture.client.queuedMessageReminders, isEmpty);
    expect(fixture.store.messageReminder(_messageId).authoritativeRevision, 1);
    expect(fixture.store.messageReminder(_messageId).dueAt, _due1);
    expect(fixture.store.messageReminder(_messageId).isPending, isFalse);
    expect(await _read(backing, _identity), isNull);
  });

  for (final replacementKind in ['request', 'metadata', 'unrelated only']) {
    test('atomic stale settlement preserves $replacementKind on retry',
        () async {
      final backing = InMemoryApplicationChatStorage();
      final storage = _AtomicReminderStorage(backing);
      final fixture = _Fixture(
        storage: storage,
        transport: _ReminderTransport(),
        keys: Queue.of(['same-key']),
      );
      addTearDown(fixture.dispose);
      await fixture.activate();
      final cancellation = ChatCommandCancellationController();
      final pending = fixture.client.setMessageReminder(
        conversationId: _conversationId,
        messageId: _messageId,
        dueAt: _due1,
        cancellationSignal: cancellation.signal,
      );
      await _eventually(
          () => fixture.client.queuedMessageReminders.length == 1);
      final original = (await _read(backing, _identity))!.intents.single;
      final replacement = ApplicationChatQueuedMessageReminderIntent(
        request: replacementKind == 'request'
            ? _request('same-key', 0, dueAt: _due2)
            : original.request,
        enqueueOrder: original.enqueueOrder,
        enqueuedAt: replacementKind == 'metadata'
            ? const IsoTimestamp('2032-02-02T00:00:00.000Z')
            : original.enqueuedAt,
      );
      final unrelated = _stored(
          _request('unrelated', 0,
              dueAt: _due2, messageId: const MessageId('message-2')),
          2);
      storage.beforeExchange = (expected, proposal) async {
        expect(proposal, isNull,
            reason: 'the stale attempt removed its only intent');
        await backing.replace(_record([replacement, unrelated]));
      };
      cancellation.cancel();
      expect(await pending, isA<ChatCommandAborted<MessageReminderResult>>());
      final expected = [
        if (replacementKind != 'unrelated only') replacement,
        unrelated,
      ];
      expect((await _read(backing, _identity))!.intents.map((i) => i.toJson()),
          expected.map((i) => i.toJson()));
      expect(
          fixture.client.queuedMessageReminders.map((i) => i.request.toJson()),
          expected.map((i) => i.request.toJson()));
      expect(storage.conflicts, 1);
      expect(storage.unconditionalRemovals, 0);
      expect(fixture.transport.requests, isEmpty);
    });
  }

  test(
      'atomic malformed quarantine cannot delete a concurrent valid replacement',
      () async {
    final backing = InMemoryApplicationChatStorage();
    backing.putRawRecordForTesting(
        _identity,
        ApplicationChatStorageRecordKind.queuedMessageReminderIntents,
        {'accessToken': 'private-secret', 'dueAt': _due1.value});
    final storage = _AtomicReminderStorage(backing);
    final valid = _record([_stored(_request('valid', 0, dueAt: _due2), 1)]);
    storage.afterRead = (encoded) async {
      expect(encoded, contains('private-secret'));
      await backing.replace(valid);
    };
    final diagnostics = <ChatClientDiagnostic>[];
    final fixture = _Fixture(
      storage: storage,
      transport: _ReminderTransport(),
      onStorageDiagnostic: diagnostics.add,
    );
    addTearDown(fixture.dispose);
    await fixture.activate();
    expect((await _read(backing, _identity))!.toJson(), valid.toJson());
    expect(storage.conflicts, 1);
    expect(storage.unconditionalRemovals, 0);
    expect(fixture.client.queuedMessageReminders, isEmpty);
    expect(diagnostics.single.code,
        ChatClientDiagnosticCode.messageReminderIntentsRejected);
    expect(diagnostics.single.toString(), isNot(contains('private-secret')));
    expect(diagnostics.single.toString(), isNot(contains(_due1.value)));
    final restarted =
        _Fixture(storage: storage, transport: _ReminderTransport());
    addTearDown(restarted.dispose);
    await restarted.activate();
    expect(restarted.client.queuedMessageReminders.single.request.toJson(),
        valid.intents.single.request.toJson());
    expect(restarted.transport.requests, isEmpty);
    expect(fixture.transport.requests, isEmpty);
  });

  for (final dispose in [false, true]) {
    for (final conflict in [false, true]) {
      test('atomic late CAS isolates dispose=$dispose conflict=$conflict',
          () async {
        final backing = InMemoryApplicationChatStorage();
        final storage = _AtomicReminderStorage(backing);
        final fixture = _Fixture(
          storage: storage,
          transport: _ReminderTransport(),
          keys: Queue.of(['old-key']),
        );
        addTearDown(fixture.dispose);
        await fixture.activate();
        final started = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        storage.beforeExchange = (_, __) async {
          started.complete();
          await release.future;
        };
        final pending = fixture.client.setMessageReminder(
          conversationId: _conversationId,
          messageId: _messageId,
          dueAt: _due1,
        );
        await started.future;
        final lifecycle = dispose
            ? fixture.client.dispose()
            : fixture.client.activateStorageIdentity(_otherIdentity);
        final concurrent = _record([
          _stored(_request('concurrent', 0, dueAt: _due2), 1),
        ]);
        if (conflict) await backing.replace(concurrent);
        release.complete();
        expect(await pending, isA<ChatCommandClosed<MessageReminderResult>>());
        await lifecycle;
        expect(fixture.store.messageReminder(_messageId).reminder, isNull);
        expect(fixture.transport.requests, isEmpty);
        if (!dispose) expect(fixture.client.queuedMessageReminders, isEmpty);
        final retained = (await _read(backing, _identity))!;
        expect(retained.intents.single.request.idempotencyKey,
            conflict ? 'concurrent' : 'old-key');
        expect(await _read(backing, _otherIdentity), isNull);
        expect(storage.conflicts, conflict ? 1 : 0);
      });
    }
  }

  test('persists before projection, token access, authority, or dispatch',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final storage = _BlockingReminderStorage(backing);
    final transport = _ReminderTransport();
    var tokenCalls = 0;
    final fixture = _Fixture(
      storage: storage,
      transport: transport,
      keys: Queue.of(['persisted-key']),
      tokenProvider: () async {
        tokenCalls += 1;
        return 'token';
      },
    );
    await fixture.activate();

    final pending = fixture.client.setMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due1,
    );
    await storage.replaceStarted.future;
    expect(fixture.client.queuedMessageReminders, isEmpty);
    expect(fixture.store.messageReminder(_messageId).reminder, isNull);
    expect(tokenCalls, 0);
    expect(transport.requests, isEmpty);

    storage.releaseReplace.complete();
    await _eventually(() => fixture.client.queuedMessageReminders.length == 1);
    expect(fixture.store.messageReminder(_messageId).reminder, isNull,
        reason: 'authority has not been refreshed');
    expect(tokenCalls, 0);
    await fixture.initialize();
    expect(await pending, isA<ChatCommandSuccess<MessageReminderResult>>());
    expect(_body(transport.puts.single)['idempotencyKey'], 'persisted-key');
    expect(await _read(backing, _identity), isNull);
    await fixture.dispose();
  });

  test('restart replays exact set, reschedule, and cancel requests', () async {
    final cases =
        <({MessageReminderRequest request, Map<String, Object?> page})>[
      (
        request: _request('set-key', 0, dueAt: _due1),
        page: _snapshot([]),
      ),
      (
        request: _request('reschedule-key', 1, dueAt: _due2),
        page: _snapshot([_entry(1, _due1)]),
      ),
      (
        request: _request('cancel-key', 1),
        page: _snapshot([_entry(1, _due1)]),
      ),
    ];

    for (final item in cases) {
      final storage = InMemoryApplicationChatStorage();
      await _seed(storage, item.request);
      final transport = _ReminderTransport(authorityPages: [item.page]);
      final fixture = _Fixture(
        storage: storage,
        transport: transport,
        keys: Queue.of(['must-not-be-used']),
      );
      await fixture.activate();
      expect(
        fixture.client.queuedMessageReminders.single.request.toJson(),
        item.request.toJson(),
      );
      await fixture.initialize();
      await _eventually(() => transport.puts.length == 1);
      expect(_body(transport.puts.single), item.request.toJson());
      expect(
        transport.puts.single.headers['Idempotency-Key'],
        item.request.idempotencyKey,
      );
      await _eventually(() => fixture.client.queuedMessageReminders.isEmpty);
      await fixture.dispose();
    }
  });

  test('latest undispatched desired state settles the superseded caller',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final fixture = _Fixture(
      storage: storage,
      transport: _ReminderTransport(),
      keys: Queue.of(['set-key', 'reschedule-key']),
    );
    await fixture.activate();
    final set = fixture.client.setMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due1,
    );
    await _eventually(() => fixture.client.queuedMessageReminders.length == 1);
    final reschedule = fixture.client.rescheduleMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due2,
    );
    expect(await set, isA<ChatCommandClosed<MessageReminderResult>>());
    await _eventually(
      () =>
          fixture.client.queuedMessageReminders.single.request.idempotencyKey ==
          'reschedule-key',
    );
    final retained = await _read(storage, _identity);
    expect(retained?.intents, hasLength(1));
    expect(retained?.intents.single.request.idempotencyKey, 'reschedule-key');
    await fixture.initialize();
    expect(await reschedule, isA<ChatCommandSuccess<MessageReminderResult>>());
    expect(_body(fixture.transport.puts.single)['dueAt'], _due2.toJson());
    await fixture.dispose();
  });

  test('authority equality settles while newer divergence remains conflict',
      () async {
    final equalStorage = InMemoryApplicationChatStorage();
    await _seed(equalStorage, _request('equal-key', 1, dueAt: _due1));
    final equal = _Fixture(
      storage: equalStorage,
      transport: _ReminderTransport(
        authorityPages: [
          _snapshot([_entry(1, _due1)])
        ],
      ),
    );
    await equal.activate();
    await equal.initialize();
    await _eventually(() => equal.client.queuedMessageReminders.isEmpty);
    expect(equal.transport.puts, isEmpty);
    expect(await _read(equalStorage, _identity), isNull);
    await equal.dispose();

    final cancelStorage = InMemoryApplicationChatStorage();
    await _seed(cancelStorage, _request('cancel-equal-key', 1));
    final cancelEqual = _Fixture(
      storage: cancelStorage,
      transport: _ReminderTransport(),
    );
    await cancelEqual.activate();
    await cancelEqual.initialize();
    await _eventually(
      () => cancelEqual.client.queuedMessageReminders.isEmpty,
    );
    expect(cancelEqual.transport.puts, isEmpty);
    expect(await _read(cancelStorage, _identity), isNull);
    await cancelEqual.dispose();

    final conflictStorage = InMemoryApplicationChatStorage();
    await _seed(conflictStorage, _request('conflict-key', 1, dueAt: _due1));
    final conflict = _Fixture(
      storage: conflictStorage,
      transport: _ReminderTransport(
        authorityPages: [
          _snapshot([_entry(2, _due2)])
        ],
      ),
    );
    await conflict.activate();
    await conflict.initialize();
    await _eventually(
      () =>
          conflict.client.queuedMessageReminders.single.status ==
          ChatQueuedMessageReminderStatus.revisionConflict,
    );
    expect(
      conflict.client.queuedMessageReminders.single.status,
      ChatQueuedMessageReminderStatus.revisionConflict,
    );
    expect(conflict.transport.puts, isEmpty);
    expect(conflict.store.messageReminder(_messageId).dueAt, _due2);
    expect((await _read(conflictStorage, _identity))?.intents, hasLength(1));
    await conflict.dispose();
  });

  test('expired set is removed deterministically without authority or dispatch',
      () async {
    final storage = InMemoryApplicationChatStorage();
    await _seed(
      storage,
      _request(
        'expired-key',
        0,
        dueAt: const IsoTimestamp('2031-01-01T00:00:00.000Z'),
      ),
    );
    final fixture = _Fixture(storage: storage, transport: _ReminderTransport());
    await fixture.activate();
    expect(fixture.client.queuedMessageReminders, isEmpty);
    expect(await _read(storage, _identity), isNull);
    await fixture.initialize();
    expect(fixture.transport.reminderGets, isEmpty);
    expect(fixture.transport.puts, isEmpty);
    await fixture.dispose();
  });

  test('transient result is retained and retries with bounded backoff',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final retryGate = Completer<void>();
    final waits = <Duration>[];
    var attempts = 0;
    final transport = _ReminderTransport(put: (request) async {
      attempts += 1;
      if (attempts == 1) throw StateError('offline');
      return _success(_body(request));
    });
    final fixture = _Fixture(
      storage: storage,
      transport: transport,
      keys: Queue.of(['retry-key']),
      retryBackoff: (_) => const Duration(seconds: 60),
      retryWait: (delay, signal) {
        waits.add(delay);
        return retryGate.future;
      },
    );
    await fixture.activate();
    await fixture.initialize();
    final first = await fixture.client.setMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due1,
    );
    expect(first, isA<ChatCommandTransportFailure<MessageReminderResult>>());
    await _eventually(() => waits.isNotEmpty);
    expect(waits.single, const Duration(seconds: 60));
    expect((await _read(storage, _identity))?.intents, hasLength(1));
    retryGate.complete();
    await _eventually(() => attempts == 2);
    await _eventually(() => fixture.client.queuedMessageReminders.isEmpty);
    await fixture.dispose();

    var invalidWaitCalled = false;
    final boundedStorage = InMemoryApplicationChatStorage();
    final bounded = _Fixture(
      storage: boundedStorage,
      transport: _ReminderTransport(
        put: (_) async => const HandrailChatHttpResponse(
          statusCode: 200,
          body: '{}',
        ),
      ),
      keys: Queue.of(['bounded-key']),
      retryBackoff: (_) => const Duration(seconds: 61),
      retryWait: (_, __) async => invalidWaitCalled = true,
    );
    await bounded.activate();
    await bounded.initialize();
    expect(
      await bounded.client.setMessageReminder(
        conversationId: _conversationId,
        messageId: _messageId,
        dueAt: _due1,
      ),
      isA<ChatCommandMalformedResponse<MessageReminderResult>>(),
    );
    expect(invalidWaitCalled, isFalse);
    expect((await _read(boundedStorage, _identity))?.intents, hasLength(1));
    await bounded.dispose();
  });

  test('terminal rejection removes retained intent', () async {
    final storage = InMemoryApplicationChatStorage();
    final fixture = _Fixture(
      storage: storage,
      transport: _ReminderTransport(
        put: (_) async => _error(403, 'PERMISSION_DENIED'),
      ),
      keys: Queue.of(['terminal-key']),
    );
    await fixture.activate();
    await fixture.initialize();
    expect(
      await fixture.client.setMessageReminder(
        conversationId: _conversationId,
        messageId: _messageId,
        dueAt: _due1,
      ),
      isA<ChatCommandAuthenticationFailure<MessageReminderResult>>(),
    );
    expect(await _read(storage, _identity), isNull);
    expect(fixture.store.messageReminder(_messageId).isPending, isFalse);
    await fixture.dispose();
  });

  test('cancellation after dispatch remains durable for later replay',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final putStarted = Completer<void>();
    final putGate = Completer<HandrailChatHttpResponse>();
    final fixture = _Fixture(
      storage: storage,
      transport: _ReminderTransport(put: (_) {
        if (!putStarted.isCompleted) putStarted.complete();
        return putGate.future;
      }),
      keys: Queue.of(['cancelled-key']),
      retryWait: (_, signal) {
        final stopped = Completer<void>();
        signal.onCancelled.listen((_) {
          if (!stopped.isCompleted) stopped.complete();
        });
        return stopped.future;
      },
    );
    await fixture.activate();
    await fixture.initialize();
    final cancellation = ChatCommandCancellationController();
    final pending = fixture.client.setMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due1,
      cancellationSignal: cancellation.signal,
    );
    await putStarted.future;
    cancellation.cancel();
    expect(await pending, isA<ChatCommandAborted<MessageReminderResult>>());
    expect((await _read(storage, _identity))?.intents, hasLength(1));
    putGate.complete(
        _success(_request('cancelled-key', 0, dueAt: _due1).toJson()));
    await fixture.dispose();
  });

  test('background and offline readiness pause authority and replay', () async {
    final storage = InMemoryApplicationChatStorage();
    await _seed(storage, _request('lifecycle-key', 0, dueAt: _due1));
    final network = FakeChatRealtimeNetwork(isOnline: false);
    final socket = FakeChatRealtimeSocket();
    final sockets = FakeChatRealtimeSocketFactory()..enqueueSocket(socket);
    final session = ChatRealtimeSessionTransport(
      endpoint: Uri.parse('https://chat.example.test/api/chat'),
      clientPackageVersion: '0.1.3',
      protocolVersion: handrailChatProtocolVersion,
      tokenProvider: () => 'realtime-token',
      socketFactory: sockets.call,
      network: network,
    );
    final fixture = _Fixture(
      storage: storage,
      transport: _ReminderTransport(),
      realtimeSession: session,
      network: network,
    );
    await fixture.activate();
    await fixture.initialize();
    expect(fixture.transport.reminderGets, isEmpty, reason: 'offline');
    await session.start();
    network.setOnline(true);
    await _eventually(() => sockets.uris.length == 1);
    fixture.client.setApplicationForeground(false);
    socket.emitJson(_acceptedFrame());
    await _eventually(() => session.state is ChatRealtimeConnectedState);
    expect(fixture.transport.reminderGets, isEmpty, reason: 'backgrounded');
    fixture.client.setApplicationForeground(true);
    await _eventually(() => fixture.transport.puts.length == 1);
    await fixture.dispose();
  });

  test(
      'canonical checkpoint excludes pending overlay and corruption quarantines',
      () async {
    final storage = InMemoryApplicationChatStorage();
    final putGate = Completer<HandrailChatHttpResponse>();
    final fixture = _Fixture(
      storage: storage,
      transport: _ReminderTransport(put: (_) => putGate.future),
      keys: Queue.of(['checkpoint-key']),
    );
    await fixture.activate();
    await fixture.initialize();
    final pending = fixture.client.setMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due1,
    );
    await _eventually(() => fixture.transport.puts.length == 1);
    await _eventually(() async {
      final record = await storage.read(
        _identity,
        ApplicationChatStorageRecordKind.normalizedSnapshot,
      );
      return record is ApplicationChatNormalizedSnapshotRecord;
    });
    final checkpoint = await storage.read(
      _identity,
      ApplicationChatStorageRecordKind.normalizedSnapshot,
    ) as ApplicationChatNormalizedSnapshotRecord;
    expect(checkpoint.snapshot.pendingMessageReminderIntents, isEmpty);
    expect(checkpoint.snapshot.currentUserMessageReminders[_messageId], isNull);
    await fixture.client.dispose();
    expect(await pending, isA<ChatCommandClosed<MessageReminderResult>>());
    expect((await _read(storage, _identity))?.intents, hasLength(1));
    putGate.complete(
        _success(_request('checkpoint-key', 0, dueAt: _due1).toJson()));
    await fixture.finishDispose();

    final corruptStorage = InMemoryApplicationChatStorage();
    final raw = ApplicationChatQueuedMessageReminderIntentsRecord(
      identity: _identity,
      intents: [
        ApplicationChatQueuedMessageReminderIntent(
          request: _request('corrupt-key', 0, dueAt: _due1),
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
        ),
      ],
    ).toJson();
    final payload = raw['payload']! as Map<String, Object?>;
    final intents = payload['intents']! as List<Object?>;
    (intents.single as Map<String, Object?>)['accessToken'] = 'secret-value';
    corruptStorage.putRawRecordForTesting(
      _identity,
      ApplicationChatStorageRecordKind.queuedMessageReminderIntents,
      raw,
    );
    final diagnostics = <ChatClientDiagnostic>[];
    final corrupt = _Fixture(
      storage: corruptStorage,
      transport: _ReminderTransport(),
      onStorageDiagnostic: diagnostics.add,
    );
    await corrupt.activate();
    expect(corrupt.client.queuedMessageReminders, isEmpty);
    expect(
      diagnostics.single.code,
      ChatClientDiagnosticCode.messageReminderIntentsRejected,
    );
    expect(diagnostics.single.toString(), isNot(contains('secret-value')));
    expect(await _read(corruptStorage, _identity), isNull);
    await corrupt.dispose();
  });

  test('identity replacement and dispose isolate late storage and HTTP',
      () async {
    final backing = InMemoryApplicationChatStorage();
    final blocking = _BlockingReminderStorage(backing);
    final fixture = _Fixture(
      storage: blocking,
      transport: _ReminderTransport(),
      keys: Queue.of(['old-key']),
    );
    await fixture.activate();
    final pending = fixture.client.setMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due1,
    );
    await blocking.replaceStarted.future;
    final replacement = fixture.client.activateStorageIdentity(_otherIdentity);
    blocking.releaseReplace.complete();
    expect(await pending, isA<ChatCommandClosed<MessageReminderResult>>());
    await replacement;
    expect(fixture.client.queuedMessageReminders, isEmpty);
    expect((await _read(backing, _identity))?.intents, hasLength(1));
    expect(await _read(backing, _otherIdentity), isNull);
    await fixture.dispose();

    final disposeStorage = InMemoryApplicationChatStorage();
    final putGate = Completer<HandrailChatHttpResponse>();
    final disposed = _Fixture(
      storage: disposeStorage,
      transport: _ReminderTransport(put: (_) => putGate.future),
      keys: Queue.of(['dispose-key']),
    );
    await disposed.activate();
    await disposed.initialize();
    final dispatched = disposed.client.setMessageReminder(
      conversationId: _conversationId,
      messageId: _messageId,
      dueAt: _due1,
    );
    await _eventually(() => disposed.transport.puts.length == 1);
    await disposed.client.dispose();
    expect(await dispatched, isA<ChatCommandClosed<MessageReminderResult>>());
    expect((await _read(disposeStorage, _identity))?.intents, hasLength(1));
    putGate
        .complete(_success(_request('dispose-key', 0, dueAt: _due1).toJson()));
    await disposed.finishDispose();
  });
}

final class _Fixture {
  _Fixture({
    required ApplicationChatStorage storage,
    required this.transport,
    Queue<String>? keys,
    HandrailChatAccessTokenProvider? tokenProvider,
    ChatMessageReminderRetryBackoff? retryBackoff,
    ChatMessageReminderRetryWait? retryWait,
    ChatClientDiagnosticCallback? onStorageDiagnostic,
    this.realtimeSession,
    this.network,
  }) : store = NormalizedSnapshotStore() {
    final generatedKeys = keys ?? Queue.of(['generated-key']);
    client = HandrailChatClient(
      apiBaseUri: Uri.parse('https://chat.example.test/api/chat'),
      tokenProvider: tokenProvider ?? () async => 'access-token',
      transport: transport,
      localStorage: storage,
      storageIdentity: _identity,
      normalizedSnapshotStore: store,
      realtimeSession: realtimeSession,
      generateIdempotencyKey: () => generatedKeys.removeFirst(),
      messageReminderClock: () =>
          const IsoTimestamp('2032-02-01T00:00:00.000Z'),
      messageReminderRetryBackoff: retryBackoff,
      messageReminderRetryWait: retryWait,
      commandRetryOptions: const ChatCommandRetryOptions(
        maxAttempts: 1,
        maxAuthenticationRefreshes: 0,
      ),
      onStorageDiagnostic: onStorageDiagnostic,
    );
  }

  final NormalizedSnapshotStore store;
  final _ReminderTransport transport;
  final ChatRealtimeSessionTransport? realtimeSession;
  final FakeChatRealtimeNetwork? network;
  late final HandrailChatClient client;
  bool _disposed = false;

  Future<void> activate() => client.activateStorageIdentity(_identity);

  Future<void> initialize() async {
    expect(await client.initialize(), isA<ChatClientReadyState>());
  }

  Future<void> dispose() async {
    if (!_disposed) {
      _disposed = true;
      await client.dispose();
    }
    await finishDispose();
  }

  Future<void> finishDispose() async {
    _disposed = true;
    await realtimeSession?.dispose();
    await network?.dispose();
    await store.close();
  }
}

final class _ReminderTransport implements HandrailChatHttpTransport {
  _ReminderTransport({
    List<Map<String, Object?>>? authorityPages,
    this.put,
  }) : authorityPages = Queue.of(authorityPages ?? [_snapshot([])]);

  final Queue<Map<String, Object?>> authorityPages;
  final Future<HandrailChatHttpResponse> Function(HandrailChatHttpRequest)? put;
  final List<HandrailChatHttpRequest> requests = [];

  Iterable<HandrailChatHttpRequest> get reminderGets =>
      requests.where((request) =>
          request.method == 'GET' &&
          request.uri.path.endsWith('/message-reminders'));
  Iterable<HandrailChatHttpRequest> get puts =>
      requests.where((request) => request.method == 'PUT');

  @override
  Future<HandrailChatHttpResponse> send(HandrailChatHttpRequest request) async {
    requests.add(request);
    if (request.method == 'GET' && request.uri.path.endsWith('/_meta')) {
      return const HandrailChatHttpResponse(
        statusCode: 200,
        body: _metadataJson,
      );
    }
    if (request.method == 'GET' &&
        request.uri.path.endsWith('/message-reminders')) {
      final page =
          authorityPages.isEmpty ? _snapshot([]) : authorityPages.removeFirst();
      return HandrailChatHttpResponse(statusCode: 200, body: jsonEncode(page));
    }
    final handler = put;
    return handler == null ? _success(_body(request)) : await handler(request);
  }
}

// Controls only the storage boundary; all record validation and CAS semantics
// run through the shared helper and the existing atomic in-memory adapter.
final class _AtomicReminderStorage implements AtomicApplicationChatStorage {
  _AtomicReminderStorage(this.backing);

  final InMemoryApplicationChatStorage backing;
  Future<void> Function(String? encoded)? afterRead;
  Future<void> Function(String? expected, String? replacement)? beforeExchange;
  bool rejectExchanges = false;
  int conflicts = 0;
  int unconditionalRemovals = 0;
  final List<String?> proposals = [];

  @override
  Future<String?> readEncoded(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) async {
    final encoded = await backing.readEncoded(identity, kind);
    if (kind == ApplicationChatStorageRecordKind.queuedMessageReminderIntents) {
      final hook = afterRead;
      afterRead = null;
      await hook?.call(encoded);
    }
    return encoded;
  }

  @override
  Future<bool> compareExchange(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
    String? expected,
    String? replacement,
  ) async {
    final reminder =
        kind == ApplicationChatStorageRecordKind.queuedMessageReminderIntents;
    if (reminder) {
      proposals.add(replacement);
      final hook = beforeExchange;
      beforeExchange = null;
      await hook?.call(expected, replacement);
      if (rejectExchanges) {
        conflicts += 1;
        return false;
      }
    }
    final committed =
        await backing.compareExchange(identity, kind, expected, replacement);
    if (reminder && !committed) conflicts += 1;
    return committed;
  }

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      backing.read(identity, kind);

  @override
  Future<void> replace(ApplicationChatStorageRecord record) =>
      backing.replace(record);

  @override
  Future<void> remove(ApplicationChatStorageIdentity identity,
      ApplicationChatStorageRecordKind kind) {
    if (kind == ApplicationChatStorageRecordKind.queuedMessageReminderIntents) {
      unconditionalRemovals += 1;
    }
    return backing.remove(identity, kind);
  }

  @override
  Future<void> clearForLogout(ApplicationChatStorageIdentity identity) =>
      backing.clearForLogout(identity);

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) =>
      backing.clearForIdentityChange(
        previousIdentity: previousIdentity,
        nextIdentity: nextIdentity,
      );
}

final class _BlockingReminderStorage implements ApplicationChatStorage {
  _BlockingReminderStorage(this.backing);

  final InMemoryApplicationChatStorage backing;
  final Completer<void> replaceStarted = Completer<void>();
  final Completer<void> releaseReplace = Completer<void>();

  @override
  Future<ApplicationChatStorageRecord?> read(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      backing.read(identity, kind);

  @override
  Future<void> replace(ApplicationChatStorageRecord record) async {
    if (record.kind ==
        ApplicationChatStorageRecordKind.queuedMessageReminderIntents) {
      if (!replaceStarted.isCompleted) replaceStarted.complete();
      await releaseReplace.future;
    }
    await backing.replace(record);
  }

  @override
  Future<void> remove(
    ApplicationChatStorageIdentity identity,
    ApplicationChatStorageRecordKind kind,
  ) =>
      backing.remove(identity, kind);

  @override
  Future<void> clearForLogout(
    ApplicationChatStorageIdentity previousIdentity,
  ) =>
      backing.clearForLogout(previousIdentity);

  @override
  Future<void> clearForIdentityChange({
    required ApplicationChatStorageIdentity previousIdentity,
    required ApplicationChatStorageIdentity nextIdentity,
  }) =>
      backing.clearForIdentityChange(
        previousIdentity: previousIdentity,
        nextIdentity: nextIdentity,
      );
}

MessageReminderRequest _request(
  String key,
  int expectedRevision, {
  IsoTimestamp? dueAt,
  MessageId messageId = _messageId,
}) =>
    MessageReminderRequest.fromJson(<String, Object?>{
      'operation': 'message_reminder.v1',
      'intent': dueAt == null ? 'cancel' : 'set',
      'conversationId': _conversationId.toJson(),
      'messageId': messageId.toJson(),
      'expectedReminderRevision': expectedRevision,
      'idempotencyKey': key,
      if (dueAt != null) 'dueAt': dueAt.toJson(),
    });

ApplicationChatQueuedMessageReminderIntent _stored(
  MessageReminderRequest request,
  int order,
) =>
    ApplicationChatQueuedMessageReminderIntent(
      request: request,
      enqueueOrder: order,
      enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
    );

ApplicationChatQueuedMessageReminderIntentsRecord _record(
  List<ApplicationChatQueuedMessageReminderIntent> intents,
) =>
    ApplicationChatQueuedMessageReminderIntentsRecord(
      identity: _identity,
      intents: intents,
    );

Future<void> _seed(
  ApplicationChatStorage storage,
  MessageReminderRequest request,
) =>
    storage.replace(ApplicationChatQueuedMessageReminderIntentsRecord(
      identity: _identity,
      intents: [
        ApplicationChatQueuedMessageReminderIntent(
          request: request,
          enqueueOrder: 1,
          enqueuedAt: const IsoTimestamp('2032-02-01T00:00:00.000Z'),
        ),
      ],
    ));

Future<ApplicationChatQueuedMessageReminderIntentsRecord?> _read(
  ApplicationChatStorage storage,
  ApplicationChatStorageIdentity identity,
) async =>
    await storage.read(
      identity,
      ApplicationChatStorageRecordKind.queuedMessageReminderIntents,
    ) as ApplicationChatQueuedMessageReminderIntentsRecord?;

Map<String, Object?> _snapshot(List<Map<String, Object?>> items) =>
    <String, Object?>{
      'kind': 'message_reminder_list',
      'privacy': 'actor_private',
      'items': items,
      'page': <String, Object?>{'nextCursor': null},
    };

Map<String, Object?> _entry(int revision, IsoTimestamp dueAt) =>
    <String, Object?>{
      'conversationId': _conversationId.toJson(),
      'messageId': _messageId.toJson(),
      'reminderRevision': revision,
      'reminder': CanonicalScheduledMessageReminder(dueAt).toJson(),
    };

HandrailChatHttpResponse _success(Map<String, Object?> body) {
  final request = MessageReminderRequest.fromJson(body);
  final reminder = switch (request) {
    SetMessageReminderRequest(:final dueAt) =>
      CanonicalScheduledMessageReminder(dueAt),
    CancelMessageReminderRequest() => const CanonicalCancelledMessageReminder(),
  };
  return HandrailChatHttpResponse(
    statusCode: 200,
    body: jsonEncode(<String, Object?>{
      'operation': request.operation,
      'intent': request.intent.toJson(),
      'reconciliationStatus': 'applied',
      'conversationId': request.conversationId.toJson(),
      'messageId': request.messageId.toJson(),
      'expectedReminderRevision': request.expectedReminderRevision,
      'idempotencyKey': request.idempotencyKey,
      'reminderRevision': request.expectedReminderRevision + 1,
      'reminder': reminder.toJson(),
    }),
  );
}

HandrailChatHttpResponse _error(int status, String code) =>
    HandrailChatHttpResponse(
      statusCode: status,
      body: jsonEncode(<String, Object?>{
        'error': <String, Object?>{
          'code': code,
          'message': 'request failed',
        },
      }),
    );

Map<String, Object?> _body(HandrailChatHttpRequest request) =>
    (jsonDecode(request.body!) as Map).cast<String, Object?>();

Future<void> _eventually(FutureOr<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 500; attempt += 1) {
    if (await predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition was not reached.');
}

Map<String, Object?> _acceptedFrame() => <String, Object?>{
      'type': 'chat.session.accepted',
      'metadata': jsonDecode(_metadataJson),
      'tenantId': _identity.tenantId.toJson(),
      'actorStreamId': 'user:${_identity.userId.value}',
      'deviceId': _identity.deviceId.toJson(),
      'sessionId': 'session-1',
    };

const _metadataJson = '''
{
  "packageVersion": "0.1.3",
  "protocolVersion": 4,
  "schemaVersion": 1,
  "enabledFeatures": {
    "realtime": true,
    "conversation_snapshot": true
  },
  "supportedProtocolRange": {"minimumVersion": 4, "maximumVersion": 4}
}
''';
