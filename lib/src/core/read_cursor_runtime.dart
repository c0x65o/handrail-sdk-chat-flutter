part of '../handrail_chat_client.dart';

/// Authored fields accepted by [HandrailChatClient.markRead].
final class ChatMarkReadInput {
  const ChatMarkReadInput({
    required this.conversationId,
    required this.throughSequence,
    this.idempotencyKey,
  });

  final ConversationId conversationId;
  final MessageSequence throughSequence;

  /// Optional caller-owned key. Synchronously coalesced advances retain the
  /// first logical intent's key and share its eventual result.
  final String? idempotencyKey;
}

/// Authored fields accepted by [HandrailChatClient.markUnread].
final class ChatMarkUnreadInput {
  const ChatMarkUnreadInput({
    required this.conversationId,
    required this.fromSequence,
    this.idempotencyKey,
  });

  final ConversationId conversationId;
  final MessageSequence fromSequence;
  final String? idempotencyKey;
}

/// A host-authorized other-member cursor used only for one receipt selection.
final class DirectMessageReceiptInput {
  const DirectMessageReceiptInput({
    required this.conversationId,
    required this.otherMemberReadState,
    required this.messageSequence,
  });

  final ConversationId conversationId;
  final ConversationReadState otherMemberReadState;
  final MessageSequence messageSequence;
}

/// Bounded delay policy for retrying a retained read-cursor intent.
typedef ChatReadCursorRetryBackoff = Duration Function(int retryNumber);

/// Cancellation-aware wait used between retained read-cursor retries.
typedef ChatReadCursorRetryWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);

/// Authority for one viewer/thread within the caller's current tenant scope.
///
/// Membership and following must be established for this exact identity. Null
/// means unknown; missing map entries do not establish false or a zero cursor.
final class ThreadSummaryViewerBasis {
  const ThreadSummaryViewerBasis({
    required this.expectedUserId,
    required this.expectedThreadId,
    required this.membershipActive,
    required this.following,
    this.cursor,
    this.sequenceCoverage,
  });

  final UserId expectedUserId;
  final ConversationId expectedThreadId;
  final bool? membershipActive;
  final bool? following;

  /// Supply only an authoritative cursor, never an optimistic projection.
  final ConversationReadState? cursor;
  final ThreadSummarySequenceCoverage? sequenceCoverage;
}

/// Explicit proof of persisted contiguous sequence coverage for a thread.
///
/// [complete] may be true only when coverage from 1 through [latestSequence]
/// is established (0 denotes an established empty stream). Reply counts,
/// partial pages, optimistic replies and a latest sequence alone cannot prove
/// this. Omit coverage or set [complete] false when it is unknown or invalidated.
final class ThreadSummarySequenceCoverage {
  const ThreadSummarySequenceCoverage({
    required this.threadId,
    required this.complete,
    required this.latestSequence,
  });

  final ConversationId threadId;
  final bool complete;
  final MessageSequence latestSequence;
}

/// Pure viewer projection; shared facts never supply unread authority.
NormalizedThreadSummary projectThreadSummaryForViewer(
  ThreadSummaryFacts facts,
  ThreadSummaryViewerBasis basis,
) {
  int? unreadCount;
  if (basis.expectedThreadId == facts.threadId) {
    if (basis.membershipActive == false && basis.following == false) {
      unreadCount = 0;
    } else if (basis.membershipActive == true || basis.following == true) {
      final cursor = basis.cursor;
      final coverage = basis.sequenceCoverage;
      if (cursor != null &&
          cursor.userId == basis.expectedUserId &&
          cursor.conversationId == basis.expectedThreadId &&
          coverage != null &&
          coverage.complete &&
          coverage.threadId == basis.expectedThreadId &&
          coverage.latestSequence.value >= 0) {
        unreadCount = max(
          0,
          coverage.latestSequence.value -
              _effectiveReadSequence(
                cursor.lastReadSequence.value,
                cursor.manualUnreadFromSequence?.value,
              ),
        );
      }
    }
  }
  return NormalizedThreadSummary(
    threadId: facts.threadId,
    replyCount: facts.replyCount,
    participantIds: facts.participantIds,
    lastReplyAt: facts.lastReplyAt,
    unreadCount: unreadCount,
  );
}

int _effectiveReadSequence(int lastReadSequence, int? marker) =>
    marker == null ? lastReadSequence : min(lastReadSequence, marker - 1);

/// Derives unread count from the current cursor and latest known sequence.
int? selectConversationUnreadCount(
  NormalizedSnapshotState state,
  ConversationId conversationId,
) {
  final readState = state.currentUserReadStates[conversationId];
  final latest = state.conversationMetadata[conversationId]?.latestSequence;
  if (readState == null || latest == null) return null;
  final effectiveRead = _effectiveReadSequence(
    readState.lastReadSequence.value,
    readState.manualUnreadFromSequence?.value,
  );
  return max(0, latest.value - effectiveRead);
}

/// Returns the first unread sequence, including an explicit manual boundary.
MessageSequence? selectFirstUnreadSequence(
  NormalizedSnapshotState state,
  ConversationId conversationId,
) {
  final readState = state.currentUserReadStates[conversationId];
  final latest = state.conversationMetadata[conversationId]?.latestSequence;
  if (readState == null || latest == null) return null;
  final effectiveRead = _effectiveReadSequence(
    readState.lastReadSequence.value,
    readState.manualUnreadFromSequence?.value,
  );
  return effectiveRead < latest.value
      ? MessageSequence(effectiveRead + 1)
      : null;
}

/// Returns the exact first unread message only when that row is hydrated.
MessageTimelineMessage? selectFirstUnreadMessage(
  NormalizedSnapshotState state,
  ConversationId conversationId,
) {
  final first = selectFirstUnreadSequence(state, conversationId);
  final timeline = state.timelines[conversationId];
  if (first == null || timeline == null) return null;
  for (final messageId in timeline.messageIds) {
    final message = state.messages[messageId];
    if (message?.sequence == first) return message;
  }
  return null;
}

/// Returns the explicit manual-unread boundary, if one is active.
MessageSequence? selectManualUnreadFromSequence(
  NormalizedSnapshotState state,
  ConversationId conversationId,
) =>
    state.currentUserReadStates[conversationId]?.manualUnreadFromSequence;

/// Derives a one-to-one DM receipt without retaining the supplied cursor.
///
/// Channels, group DMs, threads, the current user's cursor, and cursors for a
/// different conversation intentionally return no value.
bool? selectDirectMessageOtherUserRead(
  NormalizedSnapshotState state,
  DirectMessageReceiptInput input,
) {
  final conversation = state.conversations[input.conversationId];
  final current = state.currentUserReadStates[input.conversationId];
  final other = input.otherMemberReadState;
  if (conversation?.type != ConversationType.direct ||
      current == null ||
      other.conversationId != input.conversationId ||
      other.userId == current.userId) {
    return null;
  }
  return other.lastReadSequence.value >= input.messageSequence.value;
}

final class _QueuedReadCursorMutation {
  _QueuedReadCursorMutation({
    required this.input,
    required this.completers,
    required this.phase,
  });

  ReadCursorMutationInput input;
  final List<Completer<ChatCommandResult<ReadCursorMutationResult>>> completers;
  _ReadCursorMutationPhase phase;
  _DurableReadCursorMutation? durable;
  Future<bool>? settlement;
  ChatCommandCancellationController? cancellation;
}

enum _ReadCursorMutationPhase { pending, persisting, persisted, retryPaused }

final class _ReadCursorPersistenceScope {
  const _ReadCursorPersistenceScope({
    required this.identity,
    required this.generation,
  });

  final ApplicationChatStorageIdentity identity;
  final int generation;
}

final class _DurableReadCursorMutation {
  const _DurableReadCursorMutation({
    required this.scope,
    required this.intent,
  });

  final _ReadCursorPersistenceScope scope;
  final ApplicationChatQueuedReadCursorIntent intent;
}

final class _ReadCursorConversationQueue {
  _ReadCursorConversationQueue({required this.canonical});

  ConversationReadState canonical;
  final List<_QueuedReadCursorMutation> mutations = [];
  _QueuedReadCursorMutation? active;
  bool scheduled = false;
  bool persistenceScheduled = false;
  bool persisting = false;
  bool retryWaiting = false;
  int retryNumber = 0;
  ChatCommandCancellationController? retryCancellation;
}

final class _ReadCursorRuntime {
  _ReadCursorRuntime({
    required this.store,
    required this.dispatcher,
    required this.generateIdempotencyKey,
    this.storage,
    ApplicationChatStorageIdentity? initialIdentity,
    ChatReadCursorRetryBackoff? retryBackoff,
    ChatReadCursorRetryWait? retryWait,
    this.lifecycleManaged = false,
    bool deferInitialRetainedLoad = false,
    void Function(void Function())? schedule,
  })  : _retryBackoff = retryBackoff ?? _defaultReadCursorRetryBackoff,
        _retryWait = retryWait ?? _defaultReadCursorRetryWait,
        _schedule = schedule ?? scheduleMicrotask {
    _readStateSubscription =
        store.currentUserReadStateChanges.listen(_observeStoreReadState);
    if (initialIdentity != null) {
      if (deferInitialRetainedLoad) {
        _identity = initialIdentity;
        _retainedLoaded = storage == null;
      } else {
        unawaited(activate(initialIdentity));
      }
    }
  }

  final NormalizedSnapshotStore store;
  final ChatCommandDispatcher dispatcher;
  final ChatCommandIdempotencyKeyGenerator generateIdempotencyKey;
  final ApplicationChatStorage? storage;
  final ChatReadCursorRetryBackoff _retryBackoff;
  final ChatReadCursorRetryWait _retryWait;
  final bool lifecycleManaged;
  final void Function(void Function()) _schedule;
  final Map<ConversationId, _ReadCursorConversationQueue> _queues = {};
  late final StreamSubscription<ConversationSnapshotReadState>
      _readStateSubscription;
  var _suppressStoreObservation = 0;
  Future<void> _storageTail = Future<void>.value();
  ApplicationChatStorageIdentity? _identity;
  Future<void>? _retainedLoad;
  final List<ApplicationChatQueuedReadCursorIntent> _waitingRetained = [];
  bool _retainedLoaded = false;
  bool _metadataReady = false;
  bool _connectivityOnline = false;
  bool _realtimeConnected = false;
  bool _applicationForeground = true;
  var _epoch = 0;
  var _closed = false;

  bool get _isDispatchReady =>
      !_closed &&
      _applicationForeground &&
      (!lifecycleManaged ||
          (_metadataReady && _connectivityOnline && _realtimeConnected));

  Future<void> activate(ApplicationChatStorageIdentity identity) {
    if (_closed) return Future<void>.value();
    if (_identity == identity) return _ensureRetainedLoaded();
    final previousIdentity = _identity;
    _abandonQueues(
      restoreProjection: true,
      projectionIdentity: previousIdentity,
    );
    _identity = identity;
    _retainedLoaded = storage == null;
    return _ensureRetainedLoaded();
  }

  Future<void> ensureLoaded() => _ensureRetainedLoaded();

  void updateReadiness({
    required bool metadataReady,
    required bool connectivityOnline,
    required bool realtimeConnected,
    required bool applicationForeground,
  }) {
    if (_closed) return;
    final wasReady = _isDispatchReady;
    _metadataReady = metadataReady;
    _connectivityOnline = connectivityOnline;
    _realtimeConnected = realtimeConnected;
    _applicationForeground = applicationForeground;
    final ready = _isDispatchReady;
    if (!ready) {
      for (final queue in _queues.values) {
        queue.active?.cancellation?.cancel();
        queue.retryCancellation?.cancel();
      }
      return;
    }
    unawaited(_ensureRetainedLoaded());
    _attachAvailableRetained();
    if (!wasReady) {
      for (final queue in _queues.values) {
        queue.retryNumber = 0;
        queue.retryCancellation?.cancel();
        if (queue.mutations.isNotEmpty &&
            queue.mutations.first.phase ==
                _ReadCursorMutationPhase.retryPaused) {
          queue.mutations.first.phase = _ReadCursorMutationPhase.persisted;
        }
        _schedulePump(queue);
        _schedulePersistence(queue);
      }
    }
  }

  Future<ChatCommandResult<ReadCursorMutationResult>> markRead(
    ChatMarkReadInput authored,
  ) =>
      _enqueue(authored);

  Future<ChatCommandResult<ReadCursorMutationResult>> markUnread(
    ChatMarkUnreadInput authored,
  ) =>
      _enqueue(authored);

  /// Accepts a generated private read-cursor event when it advances the
  /// current user's canonical baseline.
  bool reconcileEvent(ReadCursorUpdatedEvent event) {
    if (_closed) return false;
    final payload = event.payload;
    final current = store.state.currentUserReadStates[payload.conversationId];
    if (current == null || payload.readState.userId != current.userId) {
      return false;
    }
    final queue = _queues[payload.conversationId];
    final baseline = queue?.canonical ?? _wireReadState(current);
    _QueuedReadCursorMutation? matching;
    if (queue != null) {
      for (final mutation in <_QueuedReadCursorMutation>[
        if (queue.active case final active?) active,
        ...queue.mutations,
      ]) {
        if (_isDurableReadCursorPhase(mutation.phase) &&
            mutation.settlement == null &&
            _mutationMatchesEvent(mutation, event)) {
          matching = mutation;
          break;
        }
      }
    }
    final accepted = _acceptsCanonical(payload.readState, baseline);
    if (accepted) {
      if (queue == null) {
        _writeProjection(
          payload.readState,
          authoritativeReadState: payload.readState,
        );
      } else {
        queue.canonical = payload.readState;
        _project(queue);
      }
    }
    if (matching != null && queue != null) {
      _settleFromEvent(queue, matching, payload);
    }
    return accepted || matching != null;
  }

  Future<ChatCommandResult<ReadCursorMutationResult>> _enqueue(
    Object authored,
  ) {
    if (_closed) {
      return Future.value(
        const ChatCommandClosed<ReadCursorMutationResult>(),
      );
    }
    late final _ReadCursorConversationQueue queue;
    late final ReadCursorMutationInput input;
    try {
      final conversationId = switch (authored) {
        ChatMarkReadInput(:final conversationId) => conversationId,
        ChatMarkUnreadInput(:final conversationId) => conversationId,
        _ => throw const FormatException(),
      };
      final identity = _identity;
      final current = store.state.currentUserReadStates[conversationId];
      final latest =
          store.state.conversationMetadata[conversationId]?.latestSequence;
      if (current == null || latest == null) throw const FormatException();
      if (storage != null) {
        final tenantId = store.state.conversations[conversationId]?.tenantId;
        if (identity == null ||
            identity.userId != current.userId ||
            tenantId != identity.tenantId) {
          throw const FormatException();
        }
      }
      queue = _queueFor(conversationId);
      final requestedKey = switch (authored) {
        ChatMarkReadInput(:final idempotencyKey) => idempotencyKey,
        ChatMarkUnreadInput(:final idempotencyKey) => idempotencyKey,
        _ => null,
      };
      final key = requestedKey ?? generateIdempotencyKey();
      input = switch (authored) {
        ChatMarkReadInput(:final throughSequence) => MarkReadInput(
            conversationId: conversationId,
            throughSequence: throughSequence,
            idempotencyKey: key,
          ),
        ChatMarkUnreadInput(:final fromSequence) => MarkUnreadInput(
            conversationId: conversationId,
            fromSequence: fromSequence,
            idempotencyKey: key,
          ),
        _ => throw const FormatException(),
      };
      input.validateAgainst(
        currentReadState: _projectionFor(queue, includeUnpersisted: true),
        latestSequence: latest,
      );
    } catch (_) {
      return Future.value(
        const ChatCommandValidationFailure<ReadCursorMutationResult>(),
      );
    }

    final completer = Completer<ChatCommandResult<ReadCursorMutationResult>>();
    final last = queue.mutations.isEmpty ? null : queue.mutations.last;
    if (input is MarkReadInput &&
        last?.input is MarkReadInput &&
        last!.phase ==
            (storage == null
                ? _ReadCursorMutationPhase.persisted
                : _ReadCursorMutationPhase.pending)) {
      final previous = last.input as MarkReadInput;
      if (input.throughSequence.value > previous.throughSequence.value) {
        last.input = MarkReadInput(
          conversationId: previous.conversationId,
          throughSequence: input.throughSequence,
          idempotencyKey: previous.idempotencyKey,
        );
      }
      last.completers.add(completer);
    } else {
      queue.mutations.add(
        _QueuedReadCursorMutation(
          input: input,
          completers: [completer],
          phase: storage == null
              ? _ReadCursorMutationPhase.persisted
              : _ReadCursorMutationPhase.pending,
        ),
      );
    }
    if (storage == null) {
      _project(queue);
      _schedulePump(queue);
    } else {
      _schedulePersistence(queue);
    }
    return completer.future;
  }

  _ReadCursorConversationQueue _queueFor(ConversationId conversationId) {
    final existing = _queues[conversationId];
    if (existing != null) return existing;
    final readState = store.state.currentUserReadStates[conversationId];
    if (readState == null) throw const FormatException();
    final created = _ReadCursorConversationQueue(
      canonical: _wireReadState(readState),
    );
    _queues[conversationId] = created;
    return created;
  }

  Future<void> _ensureRetainedLoaded() {
    if (_closed || storage == null || _identity == null || _retainedLoaded) {
      return Future<void>.value();
    }
    final active = _retainedLoad;
    if (active != null) return active;
    final identity = _identity!;
    final generation = _epoch;
    late final Future<void> load;
    load = _loadRetained(identity, generation).whenComplete(() {
      if (identical(_retainedLoad, load)) _retainedLoad = null;
    });
    _retainedLoad = load;
    return load;
  }

  Future<void> _loadRetained(
    ApplicationChatStorageIdentity identity,
    int generation,
  ) async {
    final configuredStorage = storage;
    if (configuredStorage == null) return;
    final scope = _ReadCursorPersistenceScope(
      identity: identity,
      generation: generation,
    );
    try {
      final candidate = await _serializedStorage(() async {
        if (!_isActiveScope(scope)) return null;
        if (configuredStorage is AtomicApplicationChatStorage) {
          return ApplicationChatStorageMutator(configuredStorage)
              .mutate<ApplicationChatQueuedReadCursorIntentsRecord>(
            identity,
            ApplicationChatStorageRecordKind.queuedReadCursorIntents,
            (current) => current,
          );
        }
        try {
          final stored = await configuredStorage.read(
            identity,
            ApplicationChatStorageRecordKind.queuedReadCursorIntents,
          );
          if (stored == null) return null;
          if (stored is! ApplicationChatQueuedReadCursorIntentsRecord ||
              stored.identity != identity) {
            throw const FormatException(
              'Stored read-cursor queue has the wrong scope.',
            );
          }
          return stored;
        } on FormatException {
          return ApplicationChatStorageMutator(configuredStorage)
              .mutate<ApplicationChatQueuedReadCursorIntentsRecord>(
            identity,
            ApplicationChatStorageRecordKind.queuedReadCursorIntents,
            (current) => current,
          );
        }
      });
      if (!_isActiveScope(scope)) return;
      _waitingRetained
        ..clear()
        ..addAll(candidate?.intents ?? const []);
      _retainedLoaded = true;
      _attachAvailableRetained();
      for (final queue in _queues.values) {
        _schedulePersistence(queue);
        _schedulePump(queue);
      }
    } on FormatException {
      if (!_isActiveScope(scope)) return;
      _waitingRetained.clear();
      _retainedLoaded = true;
      for (final queue in _queues.values) {
        _schedulePersistence(queue);
      }
    } catch (_) {
      // Application-owned storage failures retain the durable record. A later
      // readiness transition or repeated activation may retry the read.
    }
  }

  void _attachAvailableRetained() {
    if (_closed || !_retainedLoaded || _waitingRetained.isEmpty) return;
    final identity = _identity;
    if (identity == null) return;
    final scope = _ReadCursorPersistenceScope(
      identity: identity,
      generation: _epoch,
    );
    final remaining = <ApplicationChatQueuedReadCursorIntent>[];
    for (final intent in _waitingRetained) {
      final conversationId = intent.request.conversationId;
      final current = store.state.currentUserReadStates[conversationId];
      final tenantId = store.state.conversations[conversationId]?.tenantId;
      final metadata = store.state.conversationMetadata[conversationId];
      if (current == null ||
          metadata == null ||
          current.userId != identity.userId ||
          tenantId != identity.tenantId) {
        remaining.add(intent);
        continue;
      }
      final currentCanonical = _wireReadState(current);
      final baseline = _acceptsCanonical(
        intent.acknowledgedReadState,
        currentCanonical,
      )
          ? intent.acknowledgedReadState
          : currentCanonical;
      final queue = _queues.putIfAbsent(
        conversationId,
        () => _ReadCursorConversationQueue(canonical: baseline),
      );
      if (_acceptsCanonical(baseline, queue.canonical)) {
        queue.canonical = baseline;
      }
      final insertionIndex = queue.mutations.indexWhere(
        (mutation) => mutation.phase != _ReadCursorMutationPhase.persisted,
      );
      queue.mutations.insert(
        insertionIndex < 0 ? queue.mutations.length : insertionIndex,
        _QueuedReadCursorMutation(
          input: intent.request,
          completers: const [],
          phase: _ReadCursorMutationPhase.persisted,
        )..durable = _DurableReadCursorMutation(scope: scope, intent: intent),
      );
      _project(queue);
      _schedulePump(queue);
    }
    _waitingRetained
      ..clear()
      ..addAll(remaining);
  }

  void _schedulePersistence(_ReadCursorConversationQueue queue) {
    if (_closed ||
        storage == null ||
        !_retainedLoaded ||
        queue.persistenceScheduled ||
        queue.persisting ||
        queue.active != null ||
        queue.mutations.isEmpty ||
        queue.mutations.first.phase != _ReadCursorMutationPhase.pending) {
      return;
    }
    queue.persistenceScheduled = true;
    final scheduledEpoch = _epoch;
    _schedule(() => unawaited(_persistNext(queue, scheduledEpoch)));
  }

  Future<void> _persistNext(
    _ReadCursorConversationQueue queue,
    int scheduledEpoch,
  ) async {
    queue.persistenceScheduled = false;
    final configuredStorage = storage;
    if (_closed ||
        configuredStorage == null ||
        scheduledEpoch != _epoch ||
        queue.persisting ||
        queue.active != null ||
        queue.mutations.isEmpty) {
      return;
    }
    final mutation = queue.mutations.first;
    if (mutation.phase != _ReadCursorMutationPhase.pending) return;
    final identity = _identity;
    final current =
        store.state.currentUserReadStates[mutation.input.conversationId];
    final latest = store.state
        .conversationMetadata[mutation.input.conversationId]?.latestSequence;
    final tenantId =
        store.state.conversations[mutation.input.conversationId]?.tenantId;
    if (identity == null ||
        current == null ||
        latest == null ||
        current.userId != identity.userId ||
        tenantId != identity.tenantId) {
      queue.mutations.remove(mutation);
      _complete(
        mutation,
        const ChatCommandValidationFailure<ReadCursorMutationResult>(),
      );
      _schedulePersistence(queue);
      return;
    }

    final scope = _ReadCursorPersistenceScope(
      identity: identity,
      generation: scheduledEpoch,
    );
    mutation.phase = _ReadCursorMutationPhase.persisting;
    queue.persisting = true;
    try {
      final intent = await _serializedStorage(() async {
        if (!_isActiveScope(scope)) throw StateError('Inactive read scope.');
        final committed = await ApplicationChatStorageMutator(configuredStorage)
            .mutate<ApplicationChatQueuedReadCursorIntentsRecord>(
          identity,
          ApplicationChatStorageRecordKind.queuedReadCursorIntents,
          (record) {
            final previousOrder = record == null || record.intents.isEmpty
                ? 0
                : record.intents.last.enqueueOrder;
            if (previousOrder >= 9007199254740991) {
              throw StateError('Read-cursor enqueue order is exhausted.');
            }
            final baseline = _latestAcknowledgedReadState(
              record?.intents ?? const [],
              mutation.input.conversationId,
              queue.canonical,
            );
            mutation.input.validateAgainst(
              currentReadState: baseline,
              latestSequence: latest,
            );
            final candidate = ApplicationChatQueuedReadCursorIntent(
              request: mutation.input,
              acknowledgedReadState: baseline,
              enqueueOrder: previousOrder + 1,
              enqueuedAt:
                  IsoTimestamp(DateTime.now().toUtc().toIso8601String()),
            );
            return ApplicationChatQueuedReadCursorIntentsRecord(
              identity: identity,
              intents: <ApplicationChatQueuedReadCursorIntent>[
                ...?record?.intents,
                candidate,
              ],
            );
          },
        );
        if (!_isActiveScope(scope)) throw StateError('Inactive read scope.');
        final stored = committed == null || committed.intents.isEmpty
            ? null
            : committed.intents.last;
        if (stored == null ||
            stored.request.operation != mutation.input.operation ||
            stored.request.conversationId != mutation.input.conversationId) {
          throw const FormatException(
            'Persisted read-cursor intent could not be correlated.',
          );
        }
        return stored;
      });
      if (!_isActiveScope(scope) || !_mutationIsAttached(queue, mutation)) {
        return;
      }
      mutation.input = intent.request;
      mutation.durable = _DurableReadCursorMutation(
        scope: scope,
        intent: intent,
      );
      mutation.phase = _ReadCursorMutationPhase.persisted;
      _project(queue);
      _schedulePump(queue);
    } catch (_) {
      if (_isActiveScope(scope) && _mutationIsAttached(queue, mutation)) {
        _removeMutation(queue, mutation);
        _project(queue);
        _complete(
          mutation,
          const ChatCommandValidationFailure<ReadCursorMutationResult>(),
        );
      }
    } finally {
      queue.persisting = false;
      _schedulePersistence(queue);
    }
  }

  Future<bool> _settleDurableMutation(
    _QueuedReadCursorMutation mutation,
  ) async {
    final configuredStorage = storage;
    final durable = mutation.durable;
    if (configuredStorage == null || durable == null) return true;
    final pending = mutation.settlement;
    if (pending != null) return pending;

    final operation = _serializedStorage(() async {
      if (!_isActiveScope(durable.scope)) return false;
      var settled = false;
      await ApplicationChatStorageMutator(configuredStorage)
          .mutate<ApplicationChatQueuedReadCursorIntentsRecord>(
        durable.scope.identity,
        ApplicationChatStorageRecordKind.queuedReadCursorIntents,
        (record) {
          settled = false;
          if (record == null) {
            settled = true;
            return null;
          }
          final index = record.intents.indexWhere(
            (intent) =>
                intent.request.idempotencyKey ==
                durable.intent.request.idempotencyKey,
          );
          if (index < 0) {
            settled = true;
            return record;
          }
          if (!_sameStoredReadCursorIntent(
            record.intents[index],
            durable.intent,
          )) {
            return record;
          }
          settled = true;
          final remaining = record.intents.toList()..removeAt(index);
          return remaining.isEmpty
              ? null
              : ApplicationChatQueuedReadCursorIntentsRecord(
                  identity: durable.scope.identity,
                  intents: remaining,
                );
        },
      );
      return settled && _isActiveScope(durable.scope);
    }).catchError((Object _) => false);
    mutation.settlement = operation;
    final settled = await operation;
    if (!settled && identical(mutation.settlement, operation)) {
      mutation.settlement = null;
    }
    return settled;
  }

  void _settleFromEvent(
    _ReadCursorConversationQueue queue,
    _QueuedReadCursorMutation mutation,
    ReadCursorUpdatedPayload payload,
  ) {
    final observedEpoch = _epoch;
    final durable = mutation.durable;
    if (durable == null) return;
    final settlement = _settleDurableMutation(mutation);
    unawaited(settlement.then((settled) {
      if (!settled ||
          _closed ||
          observedEpoch != _epoch ||
          !_isActiveScope(durable.scope) ||
          !_mutationIsAttached(queue, mutation)) {
        return;
      }
      mutation.cancellation?.cancel();
      mutation.cancellation = null;
      _removeMutation(queue, mutation);
      queue.retryNumber = 0;
      queue.retryCancellation?.cancel();
      _project(queue);
      _complete(
        mutation,
        ChatCommandSuccess<ReadCursorMutationResult>(
          ReadCursorMutationResult(
            operation: payload.operation,
            reconciliationStatus: ReadCursorReconciliationStatus.applied,
            idempotencyKey: mutation.input.idempotencyKey,
            conversationId: payload.conversationId,
            readState: payload.readState,
            latestSequence: payload.latestSequence,
            unreadCount: payload.unreadCount,
          ),
        ),
      );
      _schedulePump(queue);
      _schedulePersistence(queue);
    }));
  }

  Future<T> _serializedStorage<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _storageTail = _storageTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  bool _isActiveScope(_ReadCursorPersistenceScope scope) =>
      !_closed && _epoch == scope.generation && _identity == scope.identity;

  bool _mutationIsAttached(
    _ReadCursorConversationQueue queue,
    _QueuedReadCursorMutation mutation,
  ) =>
      identical(queue.active, mutation) || queue.mutations.contains(mutation);

  void _removeMutation(
    _ReadCursorConversationQueue queue,
    _QueuedReadCursorMutation mutation,
  ) {
    if (identical(queue.active, mutation)) {
      queue.active = null;
    } else {
      queue.mutations.remove(mutation);
    }
  }

  void _schedulePump(_ReadCursorConversationQueue queue) {
    if (_closed ||
        !_isDispatchReady ||
        queue.scheduled ||
        queue.active != null ||
        queue.retryWaiting ||
        queue.mutations.isEmpty ||
        queue.mutations.first.phase != _ReadCursorMutationPhase.persisted ||
        queue.mutations.first.settlement != null) {
      return;
    }
    queue.scheduled = true;
    final scheduledEpoch = _epoch;
    _schedule(() => unawaited(_pump(queue, scheduledEpoch)));
  }

  Future<void> _pump(
    _ReadCursorConversationQueue queue,
    int scheduledEpoch,
  ) async {
    queue.scheduled = false;
    if (_closed ||
        scheduledEpoch != _epoch ||
        !_isDispatchReady ||
        queue.active != null) {
      return;
    }
    final mutation = queue.mutations.isEmpty ||
            queue.mutations.first.phase != _ReadCursorMutationPhase.persisted ||
            queue.mutations.first.settlement != null
        ? null
        : queue.mutations.removeAt(0);
    if (mutation == null) return;
    queue.active = mutation;
    final cancellation = ChatCommandCancellationController();
    mutation.cancellation = cancellation;

    final input = mutation.input;
    var result = input is MarkReadInput
        ? await dispatcher.dispatch(
            _markReadDescriptor(input),
            input,
            options: ChatCommandDispatchOptions(
              idempotencyKey: input.idempotencyKey,
              cancellationSignal: cancellation.signal,
            ),
          )
        : await dispatcher.dispatch(
            _markUnreadDescriptor(input as MarkUnreadInput),
            input,
            options: ChatCommandDispatchOptions(
              idempotencyKey: input.idempotencyKey,
              cancellationSignal: cancellation.signal,
            ),
          );
    if (_closed ||
        scheduledEpoch != _epoch ||
        !identical(queue.active, mutation)) {
      return;
    }

    if (result
        case ChatCommandSuccess<ReadCursorMutationResult>(:final value)) {
      if (!_mutationMatchesResult(mutation, value) ||
          value.readState.userId != queue.canonical.userId) {
        result = const ChatCommandMalformedResponse<ReadCursorMutationResult>();
      } else if (_acceptsCanonical(value.readState, queue.canonical)) {
        queue.canonical = value.readState;
        _writeProjection(
          value.readState,
          authoritativeReadState: value.readState,
        );
      }
    }
    final terminal = _isTerminalReadCursorResult(result);
    if (result is ChatCommandSuccess<ReadCursorMutationResult> || terminal) {
      await _settleDurableMutation(mutation);
      if (_closed ||
          scheduledEpoch != _epoch ||
          !identical(queue.active, mutation)) {
        return;
      }
    }
    if (terminal) {
      final baseline = mutation.durable?.intent.acknowledgedReadState;
      if (baseline != null && !_canonicalIsNewer(queue.canonical, baseline)) {
        queue.canonical = baseline;
      }
    }
    if (result is! ChatCommandSuccess<ReadCursorMutationResult> &&
        !terminal &&
        mutation.durable != null) {
      mutation.cancellation = null;
      mutation.phase = _ReadCursorMutationPhase.retryPaused;
      queue.active = null;
      queue.mutations.insert(0, mutation);
      _project(queue);
      _complete(mutation, result);
      _scheduleRetry(queue, scheduledEpoch);
      return;
    }
    queue.retryNumber = 0;
    mutation.cancellation = null;
    queue.active = null;
    _project(queue);
    _complete(mutation, result);
    _schedulePump(queue);
    _schedulePersistence(queue);
  }

  void _observeStoreReadState(ConversationSnapshotReadState readState) {
    if (_closed || _suppressStoreObservation > 0) return;
    _attachAvailableRetained();
    final queue = _queues[readState.conversationId];
    if (queue == null) return;
    final candidate = _wireReadState(readState);
    if (candidate.userId != queue.canonical.userId ||
        !_acceptsCanonical(candidate, queue.canonical)) {
      _project(queue);
      return;
    }
    queue.canonical = candidate;
    _project(queue);
    _schedulePump(queue);
  }

  void _scheduleRetry(
    _ReadCursorConversationQueue queue,
    int scheduledEpoch,
  ) {
    if (_closed || scheduledEpoch != _epoch || queue.retryWaiting) return;
    queue.retryNumber += 1;
    late final Duration delay;
    try {
      delay = _retryBackoff(queue.retryNumber);
      if (delay.isNegative || delay > const Duration(seconds: 60)) return;
    } catch (_) {
      return;
    }
    final cancellation = ChatCommandCancellationController();
    queue.retryCancellation = cancellation;
    queue.retryWaiting = true;
    unawaited(_waitForRetry(queue, scheduledEpoch, delay, cancellation));
  }

  Future<void> _waitForRetry(
    _ReadCursorConversationQueue queue,
    int scheduledEpoch,
    Duration delay,
    ChatCommandCancellationController cancellation,
  ) async {
    final cancelled = Completer<void>();
    var ownsWait = false;
    final subscription = cancellation.signal.onCancelled.listen((_) {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    if (cancellation.signal.isCancelled && !cancelled.isCompleted) {
      cancelled.complete();
    }
    try {
      await Future.any<void>([
        Future<void>.sync(() => _retryWait(delay, cancellation.signal)),
        cancelled.future,
      ]);
    } catch (_) {
      // Cancellation and scheduler failures both pause until readiness changes.
    } finally {
      await subscription.cancel();
      if (identical(queue.retryCancellation, cancellation)) {
        queue.retryCancellation = null;
        queue.retryWaiting = false;
        ownsWait = true;
      }
    }
    if (!ownsWait) return;
    if (_closed || scheduledEpoch != _epoch || !_isDispatchReady) return;
    if (queue.mutations.isNotEmpty &&
        queue.mutations.first.phase == _ReadCursorMutationPhase.retryPaused) {
      queue.mutations.first.phase = _ReadCursorMutationPhase.persisted;
    }
    _schedulePump(queue);
  }

  void _project(_ReadCursorConversationQueue queue) {
    _writeProjection(
      _projectionFor(queue),
      authoritativeReadState: queue.canonical,
    );
  }

  ConversationReadState _projectionFor(
    _ReadCursorConversationQueue queue, {
    bool includeUnpersisted = false,
  }) {
    var projected = queue.canonical;
    for (final mutation in <_QueuedReadCursorMutation>[
      if (queue.active case final active?) active,
      ...queue.mutations,
    ]) {
      if (!includeUnpersisted &&
          mutation.phase != _ReadCursorMutationPhase.persisted) {
        continue;
      }
      final input = mutation.input;
      if (input is MarkReadInput) {
        if (input.throughSequence.value < projected.lastReadSequence.value) {
          continue;
        }
        projected = ConversationReadState(
          conversationId: projected.conversationId,
          userId: projected.userId,
          lastReadSequence: input.throughSequence,
          updatedAt: projected.updatedAt,
        );
      } else if (input is MarkUnreadInput) {
        if (input.fromSequence.value > projected.lastReadSequence.value) {
          continue;
        }
        projected = ConversationReadState(
          conversationId: projected.conversationId,
          userId: projected.userId,
          lastReadSequence: projected.lastReadSequence,
          manualUnreadFromSequence: input.fromSequence,
          updatedAt: projected.updatedAt,
        );
      }
    }
    return projected;
  }

  void _writeProjection(
    ConversationReadState readState, {
    ConversationReadState? authoritativeReadState,
  }) {
    _suppressStoreObservation += 1;
    try {
      store.projectCurrentUserReadState(
        readState,
        authoritativeReadState: authoritativeReadState,
      );
    } on StateError {
      // An externally owned normalized store may close before the client.
    } finally {
      _suppressStoreObservation -= 1;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_readStateSubscription.cancel());
    _abandonQueues(
      restoreProjection: true,
      projectionIdentity: _identity,
    );
    _identity = null;
    _waitingRetained.clear();
    _retainedLoaded = false;
  }

  void _abandonQueues({
    required bool restoreProjection,
    ApplicationChatStorageIdentity? projectionIdentity,
  }) {
    _epoch += 1;
    for (final queue in _queues.values) {
      final pending = <_QueuedReadCursorMutation>[
        if (queue.active case final active?) active,
        ...queue.mutations,
      ];
      queue.active?.cancellation?.cancel();
      queue.retryCancellation?.cancel();
      queue.active = null;
      queue.mutations.clear();
      queue.scheduled = false;
      queue.persistenceScheduled = false;
      queue.persisting = false;
      queue.retryWaiting = false;
      queue.retryNumber = 0;
      queue.retryCancellation = null;
      if (restoreProjection) {
        final current =
            store.state.currentUserReadStates[queue.canonical.conversationId];
        final tenantId =
            store.state.conversations[queue.canonical.conversationId]?.tenantId;
        if ((current == null || current.userId == queue.canonical.userId) &&
            (projectionIdentity == null ||
                (projectionIdentity.userId == queue.canonical.userId &&
                    tenantId == projectionIdentity.tenantId))) {
          _writeProjection(
            queue.canonical,
            authoritativeReadState: queue.canonical,
          );
        }
      }
      for (final mutation in pending) {
        _complete(
          mutation,
          const ChatCommandClosed<ReadCursorMutationResult>(),
        );
      }
    }
    _queues.clear();
    _waitingRetained.clear();
    _retainedLoad = null;
    _retainedLoaded = storage == null;
  }
}

Duration _defaultReadCursorRetryBackoff(int retryNumber) {
  final exponent = retryNumber <= 1 ? 0 : (retryNumber - 1).clamp(0, 5);
  return Duration(seconds: 1 << exponent);
}

Future<void> _defaultReadCursorRetryWait(
  Duration delay,
  ChatCommandCancellationSignal _,
) =>
    Future<void>.delayed(delay);

ChatCommandDescriptor<MarkReadInput, MarkReadInput, ReadCursorMutationResult>
    _markReadDescriptor(MarkReadInput expected) =>
        ChatCommandDescriptor.withPathBuilder(
          name: 'conversation.mark_read',
          method: ChatCommandMethod.patch,
          pathBuilder: (request) =>
              '/conversations/${Uri.encodeComponent(request.conversationId.value)}/read-cursor',
          retrySafety: ChatCommandRetrySafety.safe,
          validateInput: (request) {
            final parsed = ReadCursorMutationInput.fromJson(request.toJson());
            if (parsed is! MarkReadInput) throw const FormatException();
            return parsed;
          },
          parseResult: (value) => ReadCursorMutationResult.fromJson(
            value,
            expectedInput: expected,
          ),
        );

ChatCommandDescriptor<MarkUnreadInput, MarkUnreadInput,
    ReadCursorMutationResult> _markUnreadDescriptor(
  MarkUnreadInput expected,
) =>
    ChatCommandDescriptor.withPathBuilder(
      name: 'conversation.mark_unread',
      method: ChatCommandMethod.patch,
      pathBuilder: (request) =>
          '/conversations/${Uri.encodeComponent(request.conversationId.value)}/read-cursor',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (request) {
        final parsed = ReadCursorMutationInput.fromJson(request.toJson());
        if (parsed is! MarkUnreadInput) throw const FormatException();
        return parsed;
      },
      parseResult: (value) => ReadCursorMutationResult.fromJson(
        value,
        expectedInput: expected,
      ),
    );

ConversationReadState _wireReadState(ConversationSnapshotReadState state) =>
    ConversationReadState.fromJson(state.toJson());

bool _canonicalIsNewer(
  ConversationReadState candidate,
  ConversationReadState current,
) =>
    candidate.lastReadSequence.value > current.lastReadSequence.value ||
    (candidate.lastReadSequence == current.lastReadSequence &&
        DateTime.parse(candidate.updatedAt.value)
            .isAfter(DateTime.parse(current.updatedAt.value)));

bool _sameReadState(
  ConversationReadState left,
  ConversationReadState right,
) =>
    left.conversationId == right.conversationId &&
    left.userId == right.userId &&
    left.lastReadSequence == right.lastReadSequence &&
    left.manualUnreadFromSequence == right.manualUnreadFromSequence &&
    left.updatedAt == right.updatedAt;

bool _acceptsCanonical(
  ConversationReadState candidate,
  ConversationReadState current,
) =>
    candidate.conversationId == current.conversationId &&
    candidate.userId == current.userId &&
    (_canonicalIsNewer(candidate, current) ||
        _sameReadState(candidate, current));

ConversationReadState _latestAcknowledgedReadState(
  List<ApplicationChatQueuedReadCursorIntent> intents,
  ConversationId conversationId,
  ConversationReadState localCanonical,
) {
  var latest = localCanonical;
  for (final intent in intents) {
    final acknowledged = intent.acknowledgedReadState;
    if (intent.request.conversationId == conversationId &&
        _acceptsCanonical(acknowledged, latest)) {
      latest = acknowledged;
    }
  }
  return latest;
}

bool _isDurableReadCursorPhase(_ReadCursorMutationPhase phase) =>
    phase == _ReadCursorMutationPhase.persisted ||
    phase == _ReadCursorMutationPhase.retryPaused;

bool _mutationMatchesEvent(
  _QueuedReadCursorMutation mutation,
  ReadCursorUpdatedEvent event,
) {
  final input = mutation.input;
  final payload = event.payload;
  if (payload.operation != input.operation ||
      payload.conversationId != input.conversationId) {
    return false;
  }
  return switch (input) {
    MarkReadInput(:final throughSequence) =>
      payload.readState.lastReadSequence == throughSequence,
    MarkUnreadInput(:final fromSequence) =>
      payload.readState.manualUnreadFromSequence == fromSequence,
  };
}

bool _mutationMatchesResult(
  _QueuedReadCursorMutation mutation,
  ReadCursorMutationResult result,
) {
  final input = mutation.input;
  if (result.operation != input.operation ||
      result.conversationId != input.conversationId ||
      result.idempotencyKey != input.idempotencyKey) {
    return false;
  }
  return switch (input) {
    MarkReadInput(:final throughSequence) =>
      result.readState.lastReadSequence == throughSequence,
    MarkUnreadInput(:final fromSequence) =>
      result.readState.manualUnreadFromSequence == fromSequence,
  };
}

bool _sameStoredRequest(
  ReadCursorMutationInput left,
  ReadCursorMutationInput right,
) {
  if (left.operation != right.operation ||
      left.conversationId != right.conversationId ||
      left.idempotencyKey != right.idempotencyKey) {
    return false;
  }
  return switch ((left, right)) {
    (
      MarkReadInput(:final throughSequence),
      MarkReadInput(throughSequence: final other),
    ) =>
      throughSequence == other,
    (
      MarkUnreadInput(:final fromSequence),
      MarkUnreadInput(fromSequence: final other),
    ) =>
      fromSequence == other,
    _ => false,
  };
}

bool _sameStoredReadCursorIntent(
  ApplicationChatQueuedReadCursorIntent left,
  ApplicationChatQueuedReadCursorIntent right,
) =>
    left.contractVersion == right.contractVersion &&
    left.enqueueOrder == right.enqueueOrder &&
    left.enqueuedAt == right.enqueuedAt &&
    _sameReadState(
      left.acknowledgedReadState,
      right.acknowledgedReadState,
    ) &&
    _sameStoredRequest(left.request, right.request);

bool _isTerminalReadCursorResult(
  ChatCommandResult<ReadCursorMutationResult> result,
) =>
    result is ChatCommandValidationFailure<ReadCursorMutationResult> ||
    result is ChatCommandAuthenticationFailure<ReadCursorMutationResult> ||
    result is ChatCommandConflict<ReadCursorMutationResult> ||
    result is ChatCommandFeatureDisabled<ReadCursorMutationResult> ||
    result is ChatCommandUnsupported<ReadCursorMutationResult> ||
    result is ChatCommandRejected<ReadCursorMutationResult>;

void _complete(
  _QueuedReadCursorMutation mutation,
  ChatCommandResult<ReadCursorMutationResult> result,
) {
  for (final completer in mutation.completers) {
    if (!completer.isCompleted) completer.complete(result);
  }
}
