part of '../handrail_chat_client.dart';

// Handwritten counterpart of parseConversationDraftSnapshot in the shared
// private-user-state snapshot contract. Draft content uses the generated parser.
ChatDraftProjection _parseDraftSnapshot(
    Object? value, ConversationId expected) {
  if (value is! Map<String, dynamic> ||
      value.length != 7 ||
      !value.keys.toSet().containsAll(const {
        'kind',
        'privacy',
        'conversationId',
        'state',
        'canonicalRevision',
        'canonicalUpdatedAt',
        'content',
      }) ||
      value['kind'] != 'conversation_draft' ||
      value['privacy'] != 'actor_private' ||
      ConversationId.fromJson(value['conversationId']) != expected) {
    throw const FormatException('Invalid private draft snapshot.');
  }
  final revision = value['canonicalRevision'];
  if (revision is! int || revision < 0 || revision > 9007199254740991) {
    throw const FormatException('Invalid draft revision.');
  }
  final updatedAt = value['canonicalUpdatedAt'] == null
      ? null
      : IsoTimestamp.fromJson(value['canonicalUpdatedAt']);
  if (updatedAt != null &&
      (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$')
              .hasMatch(updatedAt.value) ||
          DateTime.tryParse(updatedAt.value) == null)) {
    throw const FormatException('Invalid draft timestamp.');
  }
  if ((revision == 0) != (updatedAt == null)) {
    throw const FormatException('Invalid draft timestamp/revision.');
  }
  final CanonicalDraftState draft;
  if (value['state'] == 'present') {
    final content = value['content'];
    if (revision == 0 ||
        content is! Map<String, dynamic> ||
        content.length != 2 ||
        content['privacy'] != 'actor_private' ||
        !content.containsKey('value')) {
      throw const FormatException('Invalid private draft content.');
    }
    draft = CanonicalReplacedDraft(
        content: DraftContent.fromJson(content['value']));
  } else if (value['state'] == 'absent' && value['content'] == null) {
    draft = const CanonicalClearDraftTombstone();
  } else {
    throw const FormatException('Invalid draft state.');
  }
  return ChatDraftProjection(
    conversationId: expected,
    revision: revision,
    updatedAt: updatedAt,
    draft: draft,
    isPending: false,
  );
}

/// Creates one stable device mutation identity for an authored draft change.
typedef ChatDraftDeviceMutationIdGenerator = String Function();

/// Bounded delay policy for retrying an ambiguously completed retained draft.
typedef ChatRetainedDraftRetryBackoff = Duration Function(int retryNumber);

/// Cancellation-aware wait used between retained-draft retries.
typedef ChatRetainedDraftRetryWait = Future<void> Function(
  Duration delay,
  ChatCommandCancellationSignal cancellationSignal,
);

/// A cancellable callback scheduled by [ChatDraftMutationScheduler].
abstract interface class ChatDraftMutationTimer {
  void cancel();
}

/// Framework-neutral scheduling boundary used for optional draft debounce.
abstract interface class ChatDraftMutationScheduler {
  ChatDraftMutationTimer schedule(Duration delay, void Function() callback);
}

/// Authored fields shared by replace and clear draft mutations.
sealed class ChatSynchronizeDraftInput {
  const ChatSynchronizeDraftInput({
    required this.conversationId,
    required this.baseRevision,
    this.deviceMutationId,
    this.idempotencyKey,
  });

  final ConversationId conversationId;
  final int baseRevision;

  /// Optional caller-owned identity. When omitted, one is generated once for
  /// this logical mutation and retained across scheduling and safe retries.
  final String? deviceMutationId;

  /// Optional caller-owned idempotency key with the same stability guarantee.
  final String? idempotencyKey;
}

/// Authored replacement of one conversation's current-user draft.
final class ChatReplaceDraftInput extends ChatSynchronizeDraftInput {
  const ChatReplaceDraftInput({
    required super.conversationId,
    required super.baseRevision,
    required this.content,
    super.deviceMutationId,
    super.idempotencyKey,
  });

  final DraftContent content;
}

/// Authored clear of one conversation's current-user draft.
final class ChatClearDraftInput extends ChatSynchronizeDraftInput {
  const ChatClearDraftInput({
    required super.conversationId,
    required super.baseRevision,
    super.deviceMutationId,
    super.idempotencyKey,
  });
}

/// Independent completion boundaries for one validated logical draft mutation.
/// Obtain both futures from one call; do not synchronize the input twice.
final class ChatDraftSynchronization {
  const ChatDraftSynchronization._({
    required this.localPersistence,
    required this.remoteSettlement,
  });

  factory ChatDraftSynchronization._rejected(
    ChatDraftNotPersistedReason reason,
    ChatCommandResult<SynchronizeDraftResult> remoteResult,
  ) =>
      ChatDraftSynchronization._(
        localPersistence: Future.value(ChatDraftNotPersisted(reason)),
        remoteSettlement: Future.value(remoteResult),
      );

  /// Settles after verified local storage, or with an explicit non-durable
  /// outcome. Never waits for network readiness or server acceptance.
  final Future<ChatDraftLocalPersistenceResult> localPersistence;

  /// The existing synchronizeDraft command result, including validation,
  /// transport, cancellation, and closure outcomes. May remain pending offline.
  final Future<ChatCommandResult<SynchronizeDraftResult>> remoteSettlement;
}

/// Local persistence outcome only; this is never evidence of server acceptance.
sealed class ChatDraftLocalPersistenceResult {
  const ChatDraftLocalPersistenceResult();
}

/// The exact [request] was written and verified under the still-current
/// [identity] and its activation generation before this result was completed.
/// This is a point-in-time acknowledgment: later edits, remote settlement,
/// cancellation, or identity changes can replace or remove the stored intent.
final class ChatDraftLocallyPersisted extends ChatDraftLocalPersistenceResult {
  const ChatDraftLocallyPersisted._({
    required this.request,
    required this.identity,
  });

  /// Validated request, including the once-generated mutation and idempotency
  /// identities used by the same mutation's remote dispatch and safe retries.
  final SynchronizeDraftInput request;
  final ApplicationChatStorageIdentity identity;
}

/// No durability claim can be made for this mutation. An interrupted write
/// may still finish in the old scope; this result does not assert its absence.
final class ChatDraftNotPersisted extends ChatDraftLocalPersistenceResult {
  const ChatDraftNotPersisted(this.reason);

  final ChatDraftNotPersistedReason reason;
}

/// Why local persistence could not be acknowledged.
enum ChatDraftNotPersistedReason {
  /// No storage adapter; legacy remote synchronization still proceeds.
  storageUnavailable,

  /// Storage is configured but no trusted storage identity is active.
  identityUnavailable,

  /// The storage write or verification of the exact intent failed.
  storageFailure,

  /// The trusted identity or its activation generation changed before the ack.
  identityChanged,

  /// Authored input or generated mutation identities failed validation.
  validationFailure,

  /// Cancellation was requested before local persistence was acknowledged.
  aborted,

  /// The client was disposed before local persistence was acknowledged.
  closed,
}

/// Immutable latest-local draft state for one conversation.
final class ChatDraftProjection {
  const ChatDraftProjection({
    required this.conversationId,
    required this.revision,
    required this.draft,
    required this.isPending,
    this.updatedAt,
    this.conflict,
  });

  final ConversationId conversationId;

  /// The canonical revision, or the authored mutation's proposed revision
  /// while [isPending] is true.
  final int revision;
  final IsoTimestamp? updatedAt;
  final CanonicalDraftState draft;
  final bool isPending;

  /// Present when a retained local draft is based on older canonical state.
  ///
  /// [draft] remains the retained local content until the application resolves
  /// the conflict explicitly.
  final ChatDraftConflict? conflict;
}

/// Renderer-safe retained-draft conflict metadata.
final class ChatDraftConflict {
  const ChatDraftConflict({
    required this.baseRevision,
    required this.canonicalRevision,
    required this.canonicalDraft,
  });

  final int baseRevision;
  final int canonicalRevision;
  final CanonicalDraftState canonicalDraft;
}

final class _DraftCanonicalState {
  const _DraftCanonicalState({
    required this.revision,
    required this.updatedAt,
    required this.draft,
  });

  factory _DraftCanonicalState.fromResult(SynchronizeDraftResult result) =>
      _DraftCanonicalState(
        revision: result.canonicalRevision,
        updatedAt: result.canonicalUpdatedAt,
        draft: result.draft,
      );

  final int revision;
  final IsoTimestamp? updatedAt;
  final CanonicalDraftState draft;
}

final class _DraftMutationIntent {
  _DraftMutationIntent({
    required this.request,
    required this.cancellationSignal,
    required this.generation,
    this.retained = false,
  });

  SynchronizeDraftInput request;
  final ChatCommandCancellationSignal? cancellationSignal;
  final int generation;
  final bool retained;
  final Completer<ChatCommandResult<SynchronizeDraftResult>> completer =
      Completer<ChatCommandResult<SynchronizeDraftResult>>();
  final Completer<ChatDraftLocalPersistenceResult> localPersistence =
      Completer<ChatDraftLocalPersistenceResult>();

  void completeLocalPersistence(ChatDraftLocalPersistenceResult result) {
    if (!localPersistence.isCompleted) localPersistence.complete(result);
  }

  StreamSubscription<void>? cancellationSubscription;
  _PersistedDraftMutation? durable;
  Future<bool>? settlement;
  bool cancellationRequested = false;
  bool dispatched = false;
  bool settledByEvent = false;
  int retryNumber = 0;
  ChatCommandCancellationController? recoveryCancellation;
}

final class _DraftPersistenceScope {
  const _DraftPersistenceScope({
    required this.identity,
    required this.generation,
  });

  final ApplicationChatStorageIdentity identity;
  final int generation;
}

final class _PersistedDraftMutation {
  const _PersistedDraftMutation({
    required this.scope,
    required this.intent,
  });

  final _DraftPersistenceScope scope;
  final ApplicationChatQueuedDraftIntent intent;
}

final class _DraftConversationLane {
  _DraftCanonicalState? canonical;
  _DraftMutationIntent? retained;
  final List<_DraftMutationIntent> queued = [];
  _DraftMutationIntent? active;
  ChatDraftMutationTimer? timer;
  var scheduleGeneration = 0;
  var draining = false;
  ChatDraftConflict? conflict;
}

final class _DraftRuntime {
  _DraftRuntime({
    required this.dispatcher,
    required this.generateDeviceMutationId,
    required this.generateIdempotencyKey,
    required this.scheduler,
    required this.debounce,
    this.storage,
    required this.store,
    ApplicationChatStorageIdentity? initialIdentity,
    ChatRetainedDraftRetryBackoff? retainedRetryBackoff,
    ChatRetainedDraftRetryWait? retainedRetryWait,
    this.lifecycleManaged = false,
    this.onStorageDiagnostic,
  }) {
    if (debounce.isNegative) {
      throw ArgumentError.value(
          debounce, 'draftDebounce', 'must not be negative');
    }
    _identity = initialIdentity;
    _retainedRetryBackoff =
        retainedRetryBackoff ?? _defaultRetainedDraftRetryBackoff;
    _retainedRetryWait = retainedRetryWait ?? _defaultRetainedDraftRetryWait;
    _snapshotSubscription = store.acceptedCommitChanges.listen((_) {
      _observeAuthoritativeDrafts();
    });
  }

  final ChatCommandDispatcher dispatcher;
  final ChatDraftDeviceMutationIdGenerator generateDeviceMutationId;
  final ChatCommandIdempotencyKeyGenerator generateIdempotencyKey;
  final ChatDraftMutationScheduler scheduler;
  final Duration debounce;
  final ApplicationChatStorage? storage;
  final NormalizedSnapshotStore store;
  final bool lifecycleManaged;
  final void Function(String code, String message)? onStorageDiagnostic;
  late final ChatRetainedDraftRetryBackoff _retainedRetryBackoff;
  late final ChatRetainedDraftRetryWait _retainedRetryWait;
  late final StreamSubscription<NormalizedSnapshotState> _snapshotSubscription;
  final Map<ConversationId, _DraftConversationLane> _lanes = {};
  final Map<ConversationId, ChatDraftProjection> _projections = {};
  final Map<ConversationId, StreamController<ChatDraftProjection?>>
      _controllers = {};
  final Set<Future<void>> _drains = {};
  final Set<_DraftMutationIntent> _pendingPersistence = {};
  Future<void> _storageTail = Future<void>.value();
  ApplicationChatStorageIdentity? _identity;
  Future<void>? _retainedLoad;
  bool _retainedLoaded = false;
  bool _metadataReady = false;
  bool _connectivityOnline = false;
  bool _realtimeConnected = false;
  bool _applicationForeground = true;
  var _generation = 0;
  var _closed = false;

  ChatDraftProjection? draftFor(ConversationId conversationId) =>
      _projections[conversationId];

  void hydrate(ChatDraftProjection snapshot) {
    if (_closed) return;
    final lane = _lanes.putIfAbsent(
      snapshot.conversationId,
      _DraftConversationLane.new,
    );
    _refreshRetainedLane(snapshot.conversationId, lane);
    if (_acceptCanonical(
        lane,
        _DraftCanonicalState(
          revision: snapshot.revision,
          updatedAt: snapshot.updatedAt,
          draft: snapshot.draft,
        ))) {
      _project(snapshot.conversationId, lane);
    }
  }

  Stream<ChatDraftProjection?> statesFor(ConversationId conversationId) {
    if (_closed) {
      return Stream<ChatDraftProjection?>.value(_projections[conversationId]);
    }
    final controller = _controllers.putIfAbsent(
      conversationId,
      () => StreamController<ChatDraftProjection?>.broadcast(sync: true),
    );
    return Stream<ChatDraftProjection?>.multi(
      (events) {
        events.add(_projections[conversationId]);
        final subscription = controller.stream.listen(
          events.add,
          onError: events.addError,
          onDone: events.close,
        );
        events.onCancel = subscription.cancel;
      },
      isBroadcast: true,
    );
  }

  bool get _isDispatchReady =>
      !_closed &&
      _applicationForeground &&
      (!lifecycleManaged ||
          (_metadataReady && _connectivityOnline && _realtimeConnected));

  Future<void> activate(
    ApplicationChatStorageIdentity identity, {
    required int generation,
    bool loadRetained = true,
  }) {
    if (_closed) return Future<void>.value();
    if (_identity == identity && _generation == generation) {
      return loadRetained ? _ensureRetainedLoaded() : Future<void>.value();
    }
    _invalidateActiveState();
    _identity = identity;
    _generation = generation;
    _retainedLoaded = storage == null;
    return loadRetained ? _ensureRetainedLoaded() : Future<void>.value();
  }

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
    if (!_isDispatchReady) {
      for (final lane in _lanes.values) {
        lane.timer?.cancel();
        lane.timer = null;
        lane.active?.recoveryCancellation?.cancel();
        for (final intent in lane.queued) {
          intent.recoveryCancellation?.cancel();
        }
      }
      return;
    }
    unawaited(_ensureRetainedLoaded());
    _observeAuthoritativeDrafts();
    if (!wasReady) {
      for (final lane in _lanes.values) {
        _schedule(lane, reset: false);
      }
    }
  }

  Future<void> _ensureRetainedLoaded() {
    if (_closed || storage == null || _identity == null || _retainedLoaded) {
      return Future<void>.value();
    }
    final active = _retainedLoad;
    if (active != null) return active;
    final scope = _DraftPersistenceScope(
      identity: _identity!,
      generation: _generation,
    );
    late final Future<void> load;
    load = _loadRetained(scope).whenComplete(() {
      if (identical(_retainedLoad, load)) _retainedLoad = null;
    });
    _retainedLoad = load;
    return load;
  }

  Future<void> _loadRetained(_DraftPersistenceScope scope) async {
    final configuredStorage = storage;
    if (configuredStorage == null) return;
    try {
      ApplicationChatQueuedDraftIntentsRecord? record;
      try {
        record = await _readRetainedRecord(configuredStorage, scope);
      } on FormatException {
        if (!_isActiveScope(scope)) return;
        _diagnoseStorage(
          ChatClientDiagnosticCode.draftIntentsRejected,
          'The stored draft intent record was rejected and quarantined.',
        );
        try {
          // The mutator conditionally quarantined only the exact malformed
          // value it read. Re-read so a racing valid replacement is retained.
          record = await _readRetainedRecord(configuredStorage, scope);
        } on FormatException {
          if (!_isActiveScope(scope)) return;
          _diagnoseStorage(
            ChatClientDiagnosticCode.draftIntentsQuarantineFailed,
            'The rejected draft intent record could not be quarantined.',
          );
          _retainedLoaded = true;
          return;
        }
      }
      if (!_isActiveScope(scope)) return;
      _retainedLoaded = true;
      for (final stored
          in record?.intents ?? const <ApplicationChatQueuedDraftIntent>[]) {
        if (!_isActiveScope(scope)) return;
        final intent = _DraftMutationIntent(
          request: stored.request,
          cancellationSignal: null,
          generation: scope.generation,
          retained: true,
        )..durable = _PersistedDraftMutation(scope: scope, intent: stored);
        final lane = _lanes.putIfAbsent(
          stored.request.conversationId,
          _DraftConversationLane.new,
        );
        lane.queued.add(intent);
        _refreshRetainedLane(stored.request.conversationId, lane);
      }
    } catch (_) {
      if (_isActiveScope(scope)) {
        _diagnoseStorage(
          ChatClientDiagnosticCode.draftIntentsReadFailed,
          'The stored draft intents could not be read.',
        );
      }
    }
  }

  Future<ApplicationChatQueuedDraftIntentsRecord?> _readRetainedRecord(
    ApplicationChatStorage configuredStorage,
    _DraftPersistenceScope scope,
  ) =>
      _serializedStorage(() async {
        if (!_isActiveScope(scope)) return null;
        final record = await ApplicationChatStorageMutator(configuredStorage)
            .mutate<ApplicationChatQueuedDraftIntentsRecord>(
          scope.identity,
          ApplicationChatStorageRecordKind.queuedDraftIntents,
          (current) => current,
        );
        if (!_isActiveScope(scope)) return null;
        return record;
      });

  void _diagnoseStorage(String code, String message) {
    try {
      onStorageDiagnostic?.call(code, message);
    } catch (_) {
      // Diagnostics cannot destabilize retained private state.
    }
  }

  void _observeAuthoritativeDrafts() {
    if (_closed || !_retainedLoaded) return;
    for (final entry in _lanes.entries) {
      _refreshRetainedLane(entry.key, entry.value);
    }
  }

  void _refreshRetainedLane(
    ConversationId conversationId,
    _DraftConversationLane lane,
  ) {
    final revision = store.state.draftRevisions[conversationId];
    final draft = store.state.currentUserDrafts[conversationId];
    if (revision == null || draft == null) return;
    _acceptCanonical(
      lane,
      _DraftCanonicalState(revision: revision, updatedAt: null, draft: draft),
    );
    final retained = lane.queued.where((intent) => intent.retained).toList();
    for (final intent in retained) {
      if (revision < intent.request.baseRevision) return;
      if (revision > intent.request.baseRevision) {
        lane.conflict = ChatDraftConflict(
          baseRevision: intent.request.baseRevision,
          canonicalRevision: revision,
          canonicalDraft: draft,
        );
        lane.queued.remove(intent);
        lane.retained = intent;
      }
    }
    _project(conversationId, lane);
    _schedule(lane, reset: false);
  }

  ChatDraftSynchronization synchronize(
    ChatSynchronizeDraftInput authored, {
    ChatCommandCancellationSignal? cancellationSignal,
  }) {
    if (_closed) {
      return ChatDraftSynchronization._rejected(
        ChatDraftNotPersistedReason.closed,
        const ChatCommandClosed<SynchronizeDraftResult>(),
      );
    }

    late final SynchronizeDraftInput request;
    try {
      final deviceMutationId =
          authored.deviceMutationId ?? generateDeviceMutationId();
      final idempotencyKey =
          authored.idempotencyKey ?? generateIdempotencyKey();
      final json = <String, Object?>{
        'operation': draftMutationOperation,
        'intent': authored is ChatReplaceDraftInput ? 'replace' : 'clear',
        'conversationId': authored.conversationId.toJson(),
        'baseRevision': authored.baseRevision,
        'deviceMutationId': deviceMutationId,
        'idempotencyKey': idempotencyKey,
        if (authored case ChatReplaceDraftInput(:final content))
          'content': content.toJson(),
      };
      request = SynchronizeDraftInput.fromJson(json);
    } catch (_) {
      return ChatDraftSynchronization._rejected(
        ChatDraftNotPersistedReason.validationFailure,
        const ChatCommandValidationFailure<SynchronizeDraftResult>(),
      );
    }

    if (cancellationSignal?.isCancelled == true) {
      return ChatDraftSynchronization._rejected(
        ChatDraftNotPersistedReason.aborted,
        const ChatCommandAborted<SynchronizeDraftResult>(),
      );
    }

    final configuredStorage = storage;
    final identity = _identity;
    if (configuredStorage != null && identity == null) {
      return ChatDraftSynchronization._rejected(
        ChatDraftNotPersistedReason.identityUnavailable,
        const ChatCommandTransportFailure<SynchronizeDraftResult>(),
      );
    }

    final lane = _lanes.putIfAbsent(
      request.conversationId,
      _DraftConversationLane.new,
    );
    final intent = _DraftMutationIntent(
      request: request,
      cancellationSignal: cancellationSignal,
      generation: _generation,
    );
    if (cancellationSignal != null) {
      intent.cancellationSubscription =
          cancellationSignal.onCancelled.listen((_) {
        intent.cancellationRequested = true;
        intent.completeLocalPersistence(
          const ChatDraftNotPersisted(ChatDraftNotPersistedReason.aborted),
        );
        if (!intent.dispatched) {
          unawaited(_cancelBeforeDispatch(lane, intent));
        }
      });
    }
    if (configuredStorage == null) {
      intent.completeLocalPersistence(
        const ChatDraftNotPersisted(
          ChatDraftNotPersistedReason.storageUnavailable,
        ),
      );
      _attachPersistedIntent(lane, intent);
    } else {
      final scope = _DraftPersistenceScope(
        identity: identity!,
        generation: _generation,
      );
      _pendingPersistence.add(intent);
      unawaited(_persistAndAttach(lane, intent, scope));
    }
    return ChatDraftSynchronization._(
      localPersistence: intent.localPersistence.future,
      remoteSettlement: intent.completer.future,
    );
  }

  Future<void> _persistAndAttach(
    _DraftConversationLane lane,
    _DraftMutationIntent intent,
    _DraftPersistenceScope scope,
  ) async {
    try {
      final persisted = await _persistIntent(scope, intent.request);
      if (!_isActiveScope(scope) || intent.generation != _generation) {
        return;
      }
      intent.durable = _PersistedDraftMutation(
        scope: scope,
        intent: persisted,
      );
      intent.request = persisted.request;
      intent.completeLocalPersistence(
        intent.cancellationRequested ||
                intent.cancellationSignal?.isCancelled == true
            ? const ChatDraftNotPersisted(ChatDraftNotPersistedReason.aborted)
            : ChatDraftLocallyPersisted._(
                request: persisted.request,
                identity: scope.identity,
              ),
      );
      if (intent.settledByEvent) {
        await _settleDurableMutation(intent);
        return;
      }
      if (intent.completer.isCompleted) return;
      if (intent.cancellationRequested ||
          intent.cancellationSignal?.isCancelled == true) {
        await _cancelBeforeDispatch(lane, intent);
        return;
      }
      _attachPersistedIntent(lane, intent);
    } catch (_) {
      intent.completeLocalPersistence(ChatDraftNotPersisted(
        _closed
            ? ChatDraftNotPersistedReason.closed
            : !_isActiveScope(scope)
                ? ChatDraftNotPersistedReason.identityChanged
                : ChatDraftNotPersistedReason.storageFailure,
      ));
      if (intent.generation == _generation &&
          !_closed &&
          !intent.completer.isCompleted) {
        await intent.cancellationSubscription?.cancel();
        intent.completer.complete(
          const ChatCommandTransportFailure<SynchronizeDraftResult>(),
        );
      }
    } finally {
      _pendingPersistence.remove(intent);
      if (intent.settledByEvent) {
        await intent.cancellationSubscription?.cancel();
      }
    }
  }

  void _attachPersistedIntent(
    _DraftConversationLane lane,
    _DraftMutationIntent intent,
  ) {
    if (_closed || intent.generation != _generation) return;
    final retained = lane.retained;
    if (retained != null && !identical(retained, intent)) {
      lane.retained = null;
    }
    lane.queued.add(intent);
    _project(intent.request.conversationId, lane);
    _schedule(lane, reset: true);
  }

  Future<ApplicationChatQueuedDraftIntent> _persistIntent(
    _DraftPersistenceScope scope,
    SynchronizeDraftInput request,
  ) {
    final configuredStorage = storage!;
    return _serializedStorage(() async {
      if (!_isActiveScope(scope)) throw StateError('Inactive draft scope.');
      final committed = await ApplicationChatStorageMutator(configuredStorage)
          .mutate<ApplicationChatQueuedDraftIntentsRecord>(
        scope.identity,
        ApplicationChatStorageRecordKind.queuedDraftIntents,
        (record) {
          final intents =
              record?.intents ?? const <ApplicationChatQueuedDraftIntent>[];
          final previousOrder = intents.isEmpty ? 0 : intents.last.enqueueOrder;
          if (previousOrder >= 9007199254740991) {
            throw StateError('Draft intent enqueue order is exhausted.');
          }
          return ApplicationChatQueuedDraftIntentsRecord(
            identity: scope.identity,
            intents: <ApplicationChatQueuedDraftIntent>[
              ...intents,
              ApplicationChatQueuedDraftIntent(
                request: request,
                enqueueOrder: previousOrder + 1,
                enqueuedAt:
                    IsoTimestamp(DateTime.now().toUtc().toIso8601String()),
              ),
            ],
          );
        },
      );
      if (!_isActiveScope(scope)) throw StateError('Inactive draft scope.');
      final persisted = committed?.intents.singleWhere(
        (candidate) =>
            candidate.request.conversationId == request.conversationId,
      );
      if (persisted == null ||
          !_sameStoredDraftRequest(persisted.request, request)) {
        throw const FormatException(
          'Persisted draft intent could not be correlated.',
        );
      }
      return persisted;
    });
  }

  Future<void> _cancelBeforeDispatch(
    _DraftConversationLane lane,
    _DraftMutationIntent intent,
  ) async {
    if (intent.dispatched || identical(lane.active, intent)) return;
    final wasPending = _pendingPersistence.contains(intent);
    final wasQueued = lane.queued.remove(intent);
    if (!wasPending && !wasQueued && intent.durable == null) return;
    if (wasQueued && lane.queued.isEmpty) {
      _cancelSchedule(lane);
    }
    final durable = intent.durable;
    if (durable == null) {
      if (wasPending) return;
    } else {
      await _settleDurableMutation(intent);
    }
    if (intent.generation != _generation || _closed) return;
    await intent.cancellationSubscription?.cancel();
    if (!intent.completer.isCompleted) {
      intent.completer.complete(
        const ChatCommandAborted<SynchronizeDraftResult>(),
      );
    }
    _project(intent.request.conversationId, lane);
    if (lane.active == null && lane.queued.isNotEmpty) {
      _schedule(lane, reset: true);
    }
  }

  bool reconcileEvent(ConversationDraftUpdatedEvent event) {
    if (_closed) return false;
    final identity = _identity;
    if (identity != null &&
        (event.tenantId != identity.tenantId ||
            event.payload.actorUserId != identity.userId)) {
      return false;
    }
    final result = event.payload.result;
    final lane = _lanes.putIfAbsent(
      result.conversationId,
      _DraftConversationLane.new,
    );
    var settled = false;
    final active = lane.active;
    if (active != null && _draftIntentMatchesResult(active, result)) {
      active.settledByEvent = true;
      active.recoveryCancellation?.cancel();
      unawaited(_settleFromEvent(active));
      settled = true;
      if (!active.completer.isCompleted) {
        active.completer.complete(ChatCommandSuccess(result));
      }
    }
    final queued = lane.queued
        .where((intent) => _draftIntentMatchesResult(intent, result))
        .toList(growable: false);
    for (final intent in queued) {
      lane.queued.remove(intent);
      intent.settledByEvent = true;
      unawaited(intent.cancellationSubscription?.cancel());
      unawaited(_settleFromEvent(intent));
      if (!intent.completer.isCompleted) {
        intent.completer.complete(ChatCommandSuccess(result));
      }
      settled = true;
    }
    final retained = lane.retained;
    if (retained != null && _draftIntentMatchesResult(retained, result)) {
      lane.retained = null;
      lane.conflict = null;
      retained.settledByEvent = true;
      unawaited(_settleFromEvent(retained));
      settled = true;
    }
    final pending = _pendingPersistence
        .where((intent) => _draftIntentMatchesResult(intent, result))
        .toList(growable: false);
    for (final intent in pending) {
      intent.settledByEvent = true;
      // Remote settlement does not finish a pending local write. Keep its
      // cancellation listener until persistence completes (or is invalidated).
      if (!intent.completer.isCompleted) {
        intent.completer.complete(ChatCommandSuccess(result));
      }
      settled = true;
    }
    if (settled) lane.conflict = null;
    final accepted =
        _acceptCanonical(lane, _DraftCanonicalState.fromResult(result));
    if (!accepted && !settled) return false;
    if (lane.queued.isEmpty) _cancelSchedule(lane);
    _project(result.conversationId, lane);
    return accepted || settled;
  }

  /// Explicitly discards a conflicted retained local draft and its exact
  /// durable intent, restoring the authoritative canonical projection.
  Future<bool> discardConflict(ConversationId conversationId) async {
    if (_closed) return false;
    final lane = _lanes[conversationId];
    final retained = lane?.retained;
    if (lane == null || lane.conflict == null || retained == null) return false;
    final removed = await _settleDurableMutation(retained);
    if (!removed || _closed || retained.generation != _generation) return false;
    lane.retained = null;
    lane.conflict = null;
    retained.settledByEvent = true;
    _project(conversationId, lane);
    return true;
  }

  void _schedule(_DraftConversationLane lane, {required bool reset}) {
    if (_closed ||
        !_isDispatchReady ||
        lane.conflict != null ||
        lane.draining ||
        lane.active != null ||
        lane.queued.isEmpty ||
        !_canDispatch(lane, lane.queued.first)) {
      return;
    }
    if (lane.timer != null) {
      if (!reset) return;
      _cancelSchedule(lane);
    }
    final generation = ++lane.scheduleGeneration;
    lane.timer = scheduler.schedule(debounce, () {
      if (_closed || generation != lane.scheduleGeneration) return;
      lane.timer = null;
      _startDrain(lane);
    });
  }

  bool _canDispatch(
    _DraftConversationLane lane,
    _DraftMutationIntent intent,
  ) {
    if (!intent.retained) return true;
    final canonical = lane.canonical;
    return canonical != null &&
        canonical.revision == intent.request.baseRevision;
  }

  void _cancelSchedule(_DraftConversationLane lane) {
    lane.scheduleGeneration += 1;
    lane.timer?.cancel();
    lane.timer = null;
  }

  void _startDrain(_DraftConversationLane lane) {
    if (_closed || lane.draining || lane.queued.isEmpty) return;
    lane.draining = true;
    late final Future<void> drain;
    drain = _drain(lane).whenComplete(() {
      lane.draining = false;
      _drains.remove(drain);
      if (!_closed && lane.queued.isNotEmpty) {
        _schedule(lane, reset: false);
      }
    });
    _drains.add(drain);
  }

  Future<void> _drain(_DraftConversationLane lane) async {
    while (_isDispatchReady &&
        lane.conflict == null &&
        lane.queued.isNotEmpty &&
        _canDispatch(lane, lane.queued.first)) {
      final intent = lane.queued.removeAt(0);
      if (intent.completer.isCompleted) continue;
      if (intent.cancellationSignal?.isCancelled == true) {
        intent.cancellationRequested = true;
        await _cancelBeforeDispatch(lane, intent);
        continue;
      }
      lane.active = intent;
      intent.dispatched = true;
      if (intent.retained) {
        intent.recoveryCancellation = ChatCommandCancellationController();
      }
      final request = intent.request;
      final result = await dispatcher.dispatch(
        _synchronizeDraftDescriptor(request),
        request,
        options: ChatCommandDispatchOptions(
          idempotencyKey: request.idempotencyKey,
          cancellationSignal:
              intent.recoveryCancellation?.signal ?? intent.cancellationSignal,
        ),
      );
      await intent.cancellationSubscription?.cancel();
      if (_closed ||
          intent.generation != _generation ||
          !identical(lane.active, intent)) {
        continue;
      }

      final success = result is ChatCommandSuccess<SynchronizeDraftResult> &&
          result.value.reconciliationStatus !=
              DraftMutationReconciliationStatus.staleBase;
      final staleBase = result is ChatCommandConflict<SynchronizeDraftResult> ||
          (result is ChatCommandSuccess<SynchronizeDraftResult> &&
              result.value.reconciliationStatus ==
                  DraftMutationReconciliationStatus.staleBase);
      final terminal = _isTerminalDraftResult(result);
      if (success || (terminal && !staleBase)) {
        await _settleDurableMutation(intent);
        if (_closed ||
            intent.generation != _generation ||
            !identical(lane.active, intent)) {
          continue;
        }
      }
      if (result case ChatCommandSuccess<SynchronizeDraftResult>(:final value)
          when success) {
        _acceptCanonical(lane, _DraftCanonicalState.fromResult(value));
        lane.conflict = null;
      } else if (staleBase) {
        final canonical = result is ChatCommandSuccess<SynchronizeDraftResult>
            ? _DraftCanonicalState.fromResult(result.value)
            : lane.canonical;
        if (canonical != null) {
          _acceptCanonical(lane, canonical);
          lane.conflict = ChatDraftConflict(
            baseRevision: request.baseRevision,
            canonicalRevision: canonical.revision,
            canonicalDraft: canonical.draft,
          );
        }
        lane.retained = intent;
      } else if (!terminal &&
          !intent.settledByEvent &&
          intent.durable != null) {
        if (intent.retained) {
          if (!_isDispatchReady ||
              intent.recoveryCancellation?.signal.isCancelled == true) {
            lane.queued.insert(0, intent);
          } else {
            intent.retryNumber += 1;
            await _waitForRetainedRetry(lane, intent);
          }
        } else if (lane.queued.isEmpty) {
          lane.retained = intent;
        }
      }
      intent.recoveryCancellation = null;
      lane.active = null;
      _project(request.conversationId, lane);
      if (!intent.retained && !intent.completer.isCompleted) {
        intent.completer.complete(result);
      }
    }
  }

  Future<void> _waitForRetainedRetry(
    _DraftConversationLane lane,
    _DraftMutationIntent intent,
  ) async {
    final cancellation = ChatCommandCancellationController();
    intent.recoveryCancellation = cancellation;
    try {
      await _retainedRetryWait(
        _boundedRetainedDelay(intent.retryNumber),
        cancellation.signal,
      );
    } catch (_) {
      // Cancellation is an expected lifecycle transition.
    }
    if (_closed || intent.generation != _generation || intent.settledByEvent) {
      return;
    }
    lane.queued.insert(0, intent);
  }

  Duration _boundedRetainedDelay(int retryNumber) {
    final proposed = _retainedRetryBackoff(retryNumber);
    if (proposed.isNegative) return Duration.zero;
    const maximum = Duration(seconds: 30);
    return proposed > maximum ? maximum : proposed;
  }

  Future<void> _settleFromEvent(_DraftMutationIntent intent) async {
    await _settleDurableMutation(intent);
  }

  Future<bool> _settleDurableMutation(_DraftMutationIntent mutation) async {
    final configuredStorage = storage;
    final durable = mutation.durable;
    if (configuredStorage == null || durable == null) return true;
    final pending = mutation.settlement;
    if (pending != null) return pending;

    final operation = _serializedStorage(() async {
      if (!_isActiveScope(durable.scope)) return false;
      var settled = false;
      await ApplicationChatStorageMutator(configuredStorage)
          .mutate<ApplicationChatQueuedDraftIntentsRecord>(
        durable.scope.identity,
        ApplicationChatStorageRecordKind.queuedDraftIntents,
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
          if (!_sameStoredDraftIntent(
            record.intents[index],
            durable.intent,
          )) {
            return record;
          }
          settled = true;
          final remaining = record.intents.toList()..removeAt(index);
          return remaining.isEmpty
              ? null
              : ApplicationChatQueuedDraftIntentsRecord(
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

  bool _isActiveScope(_DraftPersistenceScope scope) =>
      !_closed &&
      _generation == scope.generation &&
      _identity == scope.identity;

  bool _acceptCanonical(
    _DraftConversationLane lane,
    _DraftCanonicalState candidate,
  ) {
    final current = lane.canonical;
    if (current != null) {
      if (candidate.revision < current.revision) return false;
      if (candidate.revision == current.revision) {
        final timestampComparison = DateTime.parse(
          candidate.updatedAt?.value ?? '1970-01-01T00:00:00Z',
        ).compareTo(DateTime.parse(
          current.updatedAt?.value ?? '1970-01-01T00:00:00Z',
        ));
        if (timestampComparison < 0) return false;
        if (timestampComparison == 0 &&
            !_sameCanonicalDraft(candidate.draft, current.draft)) {
          return false;
        }
      }
    }
    lane.canonical = candidate;
    return true;
  }

  void _project(
    ConversationId conversationId,
    _DraftConversationLane lane,
  ) {
    if (_closed) return;
    final pending = <_DraftMutationIntent>[
      if (lane.retained case final retained?)
        if (!retained.settledByEvent) retained,
      if (lane.active case final active?)
        if (!active.settledByEvent) active,
      ...lane.queued.where((intent) => !intent.settledByEvent),
    ];
    ChatDraftProjection? next;
    if (pending.isNotEmpty) {
      final request = pending.last.request;
      next = ChatDraftProjection(
        conversationId: conversationId,
        revision: request.baseRevision + 1,
        draft: _requestedDraft(request),
        isPending: true,
        conflict: lane.conflict,
      );
    } else if (lane.canonical case final canonical?) {
      next = ChatDraftProjection(
        conversationId: conversationId,
        revision: canonical.revision,
        updatedAt: canonical.updatedAt,
        draft: canonical.draft,
        isPending: false,
        conflict: lane.conflict,
      );
    }
    final previous = _projections[conversationId];
    if (_sameProjection(previous, next)) return;
    if (next == null) {
      _projections.remove(conversationId);
    } else {
      _projections[conversationId] = next;
    }
    _controllers[conversationId]?.add(next);
  }

  void _invalidateActiveState({bool emitClearedProjections = true}) {
    final intents = <_DraftMutationIntent>{
      ..._pendingPersistence,
      for (final lane in _lanes.values) ...<_DraftMutationIntent>[
        if (lane.retained case final retained?) retained,
        if (lane.active case final active?) active,
        ...lane.queued,
      ],
    };
    for (final lane in _lanes.values) {
      _cancelSchedule(lane);
      lane.active?.recoveryCancellation?.cancel();
      for (final intent in lane.queued) {
        intent.recoveryCancellation?.cancel();
      }
      lane.retained?.recoveryCancellation?.cancel();
      lane.retained = null;
      lane.active = null;
      lane.queued.clear();
    }
    for (final intent in intents) {
      unawaited(intent.cancellationSubscription?.cancel());
      intent.completeLocalPersistence(ChatDraftNotPersisted(
        _closed
            ? ChatDraftNotPersistedReason.closed
            : ChatDraftNotPersistedReason.identityChanged,
      ));
      if (!intent.completer.isCompleted) {
        intent.completer.complete(
          const ChatCommandClosed<SynchronizeDraftResult>(),
        );
      }
    }
    final projectedConversations = _projections.keys.toList(growable: false);
    _lanes.clear();
    _retainedLoad = null;
    _retainedLoaded = storage == null;
    _projections.clear();
    if (emitClearedProjections) {
      for (final conversationId in projectedConversations) {
        _controllers[conversationId]?.add(null);
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation += 1;
    _identity = null;
    _invalidateActiveState(emitClearedProjections: false);
    await _snapshotSubscription.cancel();
    final controllers = _controllers.values.toList(growable: false);
    _controllers.clear();
    await Future.wait(controllers.map((controller) => controller.close()));
    if (_drains.isNotEmpty) {
      await Future.wait(_drains.toList(growable: false));
    }
    await _storageTail.catchError((Object _) {});
  }
}

bool _draftIntentMatchesResult(
  _DraftMutationIntent intent,
  SynchronizeDraftResult result,
) =>
    intent.request.conversationId == result.conversationId &&
    intent.request.deviceMutationId == result.deviceMutationId &&
    intent.request.idempotencyKey == result.idempotencyKey;

bool _sameStoredDraftRequest(
  SynchronizeDraftInput left,
  SynchronizeDraftInput right,
) =>
    jsonEncode(left.toJson()) == jsonEncode(right.toJson());

bool _sameStoredDraftIntent(
  ApplicationChatQueuedDraftIntent left,
  ApplicationChatQueuedDraftIntent right,
) =>
    jsonEncode(left.toJson()) == jsonEncode(right.toJson());

bool _isTerminalDraftResult(
  ChatCommandResult<SynchronizeDraftResult> result,
) =>
    result is ChatCommandValidationFailure<SynchronizeDraftResult> ||
    result is ChatCommandAuthenticationFailure<SynchronizeDraftResult> ||
    result is ChatCommandConflict<SynchronizeDraftResult> ||
    result is ChatCommandFeatureDisabled<SynchronizeDraftResult> ||
    result is ChatCommandUnsupported<SynchronizeDraftResult> ||
    result is ChatCommandRejected<SynchronizeDraftResult>;

ChatCommandDescriptor<SynchronizeDraftInput, SynchronizeDraftInput,
    SynchronizeDraftResult> _synchronizeDraftDescriptor(
  SynchronizeDraftInput expected,
) =>
    ChatCommandDescriptor.withPathBuilder(
      name: 'conversation.draft.synchronize',
      method: ChatCommandMethod.patch,
      pathBuilder: (request) =>
          '/conversations/${Uri.encodeComponent(request.conversationId.value)}/draft',
      retrySafety: ChatCommandRetrySafety.safe,
      validateInput: (request) =>
          SynchronizeDraftInput.fromJson(request.toJson()),
      parseResult: (value) => SynchronizeDraftResult.fromJson(
        value,
        expectedInput: expected,
      ),
      parseErrorResult: (value, status) {
        if (status != 409) return null;
        try {
          final result = SynchronizeDraftResult.fromJson(
            value,
            expectedInput: expected,
          );
          return result.reconciliationStatus ==
                  DraftMutationReconciliationStatus.staleBase
              ? result
              : null;
        } catch (_) {
          return null;
        }
      },
    );

CanonicalDraftState _requestedDraft(SynchronizeDraftInput request) =>
    switch (request) {
      ReplaceDraftInput(:final content) => CanonicalReplacedDraft(
          content: content,
        ),
      ClearDraftInput() => const CanonicalClearDraftTombstone(),
    };

bool _sameCanonicalDraft(
  CanonicalDraftState left,
  CanonicalDraftState right,
) =>
    jsonEncode(left.toJson()) == jsonEncode(right.toJson());

bool _sameProjection(
  ChatDraftProjection? left,
  ChatDraftProjection? right,
) {
  if (identical(left, right)) return true;
  if (left == null || right == null) return false;
  return left.conversationId == right.conversationId &&
      left.revision == right.revision &&
      left.updatedAt == right.updatedAt &&
      left.isPending == right.isPending &&
      _sameDraftConflict(left.conflict, right.conflict) &&
      _sameCanonicalDraft(left.draft, right.draft);
}

bool _sameDraftConflict(ChatDraftConflict? left, ChatDraftConflict? right) {
  if (identical(left, right)) return true;
  if (left == null || right == null) return false;
  return left.baseRevision == right.baseRevision &&
      left.canonicalRevision == right.canonicalRevision &&
      _sameCanonicalDraft(left.canonicalDraft, right.canonicalDraft);
}

Duration _defaultRetainedDraftRetryBackoff(int retryNumber) {
  final exponent = retryNumber <= 1 ? 0 : (retryNumber - 1).clamp(0, 5);
  return Duration(milliseconds: 250 * (1 << exponent));
}

Future<void> _defaultRetainedDraftRetryWait(
  Duration delay,
  ChatCommandCancellationSignal _,
) =>
    Future<void>.delayed(delay);

final class _DartDraftMutationScheduler implements ChatDraftMutationScheduler {
  const _DartDraftMutationScheduler();

  @override
  ChatDraftMutationTimer schedule(
    Duration delay,
    void Function() callback,
  ) =>
      _DartDraftMutationTimer(Timer(delay, callback));
}

final class _DartDraftMutationTimer implements ChatDraftMutationTimer {
  _DartDraftMutationTimer(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}
